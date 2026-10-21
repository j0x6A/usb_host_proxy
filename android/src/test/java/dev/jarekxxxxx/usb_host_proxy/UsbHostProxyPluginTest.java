package dev.jarekxxxxx.usb_host_proxy;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import android.content.Context;
import android.content.ContextWrapper;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding;
import java.util.HashMap;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = {24, 31, 33, 35}, manifest = Config.NONE)
public class UsbHostProxyPluginTest {
    private static final long ENGINE_ID = 42;
    private FlutterEngine engine;
    private FlutterPluginBinding binding;
    private UsbHostProxyPlugin plugin;

    @Before public void setUp() {
        UsbManager manager = mock(UsbManager.class);
        UsbDevice usb = mock(UsbDevice.class);
        when(usb.getDeviceName()).thenReturn("/dev/bus/usb/001/002");
        HashMap<String, UsbDevice> devices = new HashMap<>();
        devices.put(usb.getDeviceName(), usb);
        when(manager.getDeviceList()).thenReturn(devices);
        Context context = new ContextWrapper(RuntimeEnvironment.getApplication()) {
            @Override public Context getApplicationContext() { return this; }
            @Override public Object getSystemService(String name) {
                return Context.USB_SERVICE.equals(name) ? manager : super.getSystemService(name);
            }
        };
        engine = mock(FlutterEngine.class);
        when(engine.getEngineId()).thenReturn(ENGINE_ID);
        binding = mock(FlutterPluginBinding.class);
        when(binding.getApplicationContext()).thenReturn(context);
        when(binding.getFlutterEngine()).thenReturn(engine);
        plugin = new UsbHostProxyPlugin();
        plugin.onAttachedToEngine(binding);
    }

    @After public void tearDown() { plugin.onDetachedFromEngine(binding); }

    @Test public void attachingRegistersTheSessionAndEngineListener() {
        verify(engine).addEngineLifecycleListener(plugin);
        assertEquals(1, UsbHostProxy.session(ENGINE_ID).deviceList().length);
    }

    @Test public void restartDisposesTheOldSessionAndCreatesAFreshOne() {
        UsbHostProxy.Session old = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Device device = old.deviceList()[0];
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        old.listen(events);
        UsbHostProxy.Completion permission = mock(UsbHostProxy.Completion.class);
        old.requestPermission(device, permission);
        plugin.onPreEngineRestart();
        verify(permission).failure(isA(IllegalStateException.class));
        verify(permission, never()).success(any());
        verify(events).disposed();
        verify(events, never()).detached(any());
        assertThrows(IllegalStateException.class, old::deviceList);
        UsbHostProxy.Session replacement = UsbHostProxy.session(ENGINE_ID);
        assertNotSame(old, replacement);
        assertNotSame(device, replacement.deviceList()[0]);
        verify(engine, times(1)).addEngineLifecycleListener(plugin);
    }

    @Test public void engineDestructionDisposesTheSessionIdempotently() {
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        plugin.onEngineWillDestroy();
        plugin.onEngineWillDestroy();
        verify(events, times(1)).disposed();
        assertThrows(IllegalStateException.class, session::deviceList);
        assertThrows(IllegalStateException.class, () -> UsbHostProxy.session(ENGINE_ID));
    }

    @Test public void pluginDetachUnregistersTheListenerAndPreventsSessionRecreation() {
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        plugin.onDetachedFromEngine(binding);
        verify(engine).removeEngineLifecycleListener(plugin);
        plugin.onPreEngineRestart();
        plugin.onEngineWillDestroy();
        assertThrows(IllegalStateException.class, session::deviceList);
        assertThrows(IllegalStateException.class, () -> UsbHostProxy.session(ENGINE_ID));
    }
}
