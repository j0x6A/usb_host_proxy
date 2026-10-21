package dev.jarekxxxxx.usb_host_proxy;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.robolectric.Shadows.shadowOf;

import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.os.BadParcelableException;
import android.os.Build;
import android.os.Bundle;
import android.os.Looper;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.PluginRegistry.NewIntentListener;
import java.util.HashMap;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

/**
 * Tests forwarding from Flutter lifecycle callbacks to real backend sessions.
 * The engine/binding are mocks: no Flutter runtime or Dart isolate is started.
 * Activity payloads, broadcasts and the live USB list are controlled separately,
 * so duplicate delivery and stale state do not get hidden by the fixture.
 */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = {24, 31, 33, 35}, manifest = Config.NONE)
public class UsbHostProxyPluginTest {
    /** Stable lookup key used to inspect the session registered by the plugin. */
    private static final long ENGINE_ID = 42;
    /** Engine double used to verify listener registration and removal. */
    private FlutterEngine engine;
    /** Supplies the application context and engine without a native Flutter runtime. */
    private FlutterPluginBinding binding;
    /** Plugin instance whose callbacks drive session lifecycle in each test. */
    private UsbHostProxyPlugin plugin;
    /** Application context used to deliver broadcasts independently of Activity intents. */
    private Context context;
    /** Native USB descriptor carried by test intents. */
    private UsbDevice usb;
    /** Simulated live Android enumeration; stale intent payloads do not alter it. */
    private HashMap<String, UsbDevice> devices;

    /** Attaches a fresh plugin with one descriptor double available for enumeration. */
    @Before public void setUp() {
        UsbManager manager = mock(UsbManager.class);
        usb = mock(UsbDevice.class);
        when(usb.getDeviceName()).thenReturn("/dev/bus/usb/001/002");
        devices = new HashMap<>();
        devices.put(usb.getDeviceName(), usb);
        when(manager.getDeviceList()).thenReturn(devices);
        context = new ContextWrapper(RuntimeEnvironment.getApplication()) {
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

    /** Also safe after a test has already destroyed or detached the session. */
    @After public void tearDown() {
        plugin.onDetachedFromEngine(binding);
    }

    /** Supplies an Activity with a controlled initial intent, without starting Flutter. */
    private ActivityPluginBinding activityBinding(Intent initial) {
        Activity activity = mock(Activity.class);
        when(activity.getIntent()).thenReturn(initial);
        ActivityPluginBinding activityBinding = mock(ActivityPluginBinding.class);
        when(activityBinding.getActivity()).thenReturn(activity);
        return activityBinding;
    }

    /** Captures a single registration; reattachment tests explicitly capture both listeners. */
    private NewIntentListener listener(ActivityPluginBinding activity) {
        ArgumentCaptor<NewIntentListener> captured = ArgumentCaptor.forClass(NewIntentListener.class);
        verify(activity).addOnNewIntentListener(captured.capture());
        return captured.getValue();
    }

    /** Valid attach payload; current device presence is controlled separately. */
    private Intent usbIntent() {
        return new Intent(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                .putExtra(UsbManager.EXTRA_DEVICE, usb);
    }

    /** Drains the platform receiver independently of the Activity listener. */
    private void broadcast(String action) {
        context.sendBroadcast(new Intent(action).putExtra(UsbManager.EXTRA_DEVICE, usb));
        shadowOf(Looper.getMainLooper()).idle();
    }

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
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        NewIntentListener listener = listener(activity);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        plugin.onEngineWillDestroy();
        plugin.onEngineWillDestroy();
        verify(events, times(1)).disposed();
        verify(activity, times(1)).removeOnNewIntentListener(listener);
        assertFalse(listener.onNewIntent(usbIntent()));
        assertThrows(IllegalStateException.class, session::deviceList);
        assertThrows(IllegalStateException.class, () -> UsbHostProxy.session(ENGINE_ID));
    }

    @Test public void pluginDetachUnregistersTheListenerAndPreventsSessionRecreation() {
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        NewIntentListener listener = listener(activity);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        plugin.onDetachedFromEngine(binding);
        verify(engine).removeEngineLifecycleListener(plugin);
        verify(activity).removeOnNewIntentListener(listener);
        assertFalse(listener.onNewIntent(usbIntent()));
        plugin.onPreEngineRestart();
        plugin.onEngineWillDestroy();
        assertThrows(IllegalStateException.class, session::deviceList);
        assertThrows(IllegalStateException.class, () -> UsbHostProxy.session(ENGINE_ID));
    }

    @Test public void initialUsbIntentIsSilentAndSharesIdentityWithEnumerationAndBroadcast() {
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        ActivityPluginBinding activity = activityBinding(usbIntent());
        plugin.onAttachedToActivity(activity);
        UsbHostProxy.Device device = session.deviceList()[0];
        assertSame(usb, device.usbDevice);
        verifyNoInteractions(events);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        assertTrue(listener(activity).onNewIntent(usbIntent()));
        assertSame(device, session.deviceList()[0]);
        verifyNoInteractions(events);
    }

    @Test public void newUsbIntentThenBroadcastReportsOnlyOneAttach() {
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        NewIntentListener listener = listener(activity);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Device device = session.deviceList()[0];
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        assertTrue(listener.onNewIntent(usbIntent()));
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        assertTrue(listener.onNewIntent(usbIntent()));
        assertSame(device, session.deviceList()[0]);
        verify(events).attached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void broadcastThenNewUsbIntentReportsOnlyOneAttach() {
        ActivityPluginBinding activity = activityBinding(null);
        plugin.onAttachedToActivity(activity);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        UsbHostProxy.Device device = session.deviceList()[0];
        assertTrue(listener(activity).onNewIntent(usbIntent()));
        assertSame(device, session.deviceList()[0]);
        verify(events).attached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void unrelatedMissingAndWrongDevicePayloadsAreNotHandled() {
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        NewIntentListener listener = listener(activity);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        assertFalse(listener.onNewIntent(new Intent(Intent.ACTION_VIEW)
                .putExtra(UsbManager.EXTRA_DEVICE, usb)));
        assertFalse(listener.onNewIntent(new Intent(UsbManager.ACTION_USB_DEVICE_DETACHED)
                .putExtra(UsbManager.EXTRA_DEVICE, usb)));
        assertFalse(listener.onNewIntent(new Intent(UsbManager.ACTION_USB_DEVICE_ATTACHED)));
        assertFalse(listener.onNewIntent(new Intent(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                .putExtra(UsbManager.EXTRA_DEVICE, new Bundle())));
        assertFalse(listener.onNewIntent(null));
        UsbHostProxy.Device device = session.deviceList()[0];
        verifyNoInteractions(events);
        // Invalid payloads must not consume the later valid attach notification.
        assertTrue(listener.onNewIntent(usbIntent()));
        verify(events).attached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void staleActivityIntentsDoNotRestoreAnAbsentDevice() {
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Device device = session.deviceList()[0];
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        devices.clear();
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED);
        // Recognized payload, but no current device: handled does not mean attached.
        assertTrue(listener(activity).onNewIntent(usbIntent()));
        plugin.onDetachedFromActivityForConfigChanges();
        plugin.onReattachedToActivityForConfigChanges(activityBinding(usbIntent()));
        assertEquals(0, session.deviceList().length);
        assertFalse(session.hasPermission(device));
        verify(events).detached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void unreadableParcelableIsIgnoredForInitialAndNewIntents() {
        Intent malformed = mock(Intent.class);
        when(malformed.getAction()).thenReturn(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        if (Build.VERSION.SDK_INT >= 33) {
            when(malformed.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice.class))
                    .thenThrow(new BadParcelableException("unreadable USB payload"));
        } else {
            when(malformed.<UsbDevice>getParcelableExtra(UsbManager.EXTRA_DEVICE))
                    .thenThrow(new BadParcelableException("unreadable USB payload"));
        }
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        ActivityPluginBinding activity = activityBinding(malformed);
        plugin.onAttachedToActivity(activity);
        NewIntentListener listener = listener(activity);
        assertFalse(listener.onNewIntent(malformed));
        verifyNoInteractions(events);
        assertTrue(listener.onNewIntent(usbIntent()));
        verify(events).attached(session.deviceList()[0]);
        verifyNoMoreInteractions(events);
    }

    @Test public void configurationChangeKeepsSessionAndRejectsOldActivityListener() {
        ActivityPluginBinding first = activityBinding(usbIntent());
        plugin.onAttachedToActivity(first);
        NewIntentListener oldListener = listener(first);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Device device = session.deviceList()[0];
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        plugin.onDetachedFromActivityForConfigChanges();
        verify(first).removeOnNewIntentListener(oldListener);
        assertFalse(oldListener.onNewIntent(usbIntent()));
        ActivityPluginBinding second = activityBinding(usbIntent());
        plugin.onReattachedToActivityForConfigChanges(second);
        assertSame(session, UsbHostProxy.session(ENGINE_ID));
        assertSame(device, session.deviceList()[0]);
        assertFalse(oldListener.onNewIntent(usbIntent()));
        assertTrue(listener(second).onNewIntent(usbIntent()));
        verifyNoInteractions(events);
        plugin.onDetachedFromActivity();
        verify(second).removeOnNewIntentListener(any(NewIntentListener.class));
    }

    @Test public void activityDetachLeavesBroadcastsWorkingInTheHeadlessSession() {
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        NewIntentListener listener = listener(activity);
        UsbHostProxy.Session session = UsbHostProxy.session(ENGINE_ID);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        plugin.onDetachedFromActivity();
        plugin.onDetachedFromActivity();
        verify(activity, times(1)).removeOnNewIntentListener(listener);
        assertFalse(listener.onNewIntent(usbIntent()));
        assertSame(session, UsbHostProxy.session(ENGINE_ID));
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        verify(events).attached(session.deviceList()[0]);
        verifyNoMoreInteractions(events);
    }

    @Test public void pluginReattachmentRejectsAnOldListenerEvenWhenBindingIsReused() {
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        NewIntentListener oldListener = listener(activity);
        UsbHostProxy.Session old = UsbHostProxy.session(ENGINE_ID);
        plugin.onDetachedFromEngine(binding);
        plugin.onAttachedToEngine(binding);
        plugin.onAttachedToActivity(activity);
        ArgumentCaptor<NewIntentListener> captured = ArgumentCaptor.forClass(NewIntentListener.class);
        verify(activity, times(2)).addOnNewIntentListener(captured.capture());
        NewIntentListener currentListener = captured.getAllValues().get(1);
        assertNotSame(oldListener, currentListener);
        assertFalse(oldListener.onNewIntent(usbIntent()));
        UsbHostProxy.Session current = UsbHostProxy.session(ENGINE_ID);
        assertNotSame(old, current);
        assertThrows(IllegalStateException.class, old::deviceList);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        current.listen(events);
        assertTrue(currentListener.onNewIntent(usbIntent()));
        verify(events).attached(current.deviceList()[0]);
    }

    @Test public void engineRestartKeepsOneActivityListenerAndRoutesToTheNewSession() {
        ActivityPluginBinding activity = activityBinding(new Intent(Intent.ACTION_MAIN));
        plugin.onAttachedToActivity(activity);
        NewIntentListener listener = listener(activity);
        UsbHostProxy.Session old = UsbHostProxy.session(ENGINE_ID);
        plugin.onPreEngineRestart();
        UsbHostProxy.Session current = UsbHostProxy.session(ENGINE_ID);
        assertNotSame(old, current);
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        current.listen(events);
        assertTrue(listener.onNewIntent(usbIntent()));
        verify(events).attached(current.deviceList()[0]);
        verify(activity, times(1)).addOnNewIntentListener(listener);
        verify(activity, never()).removeOnNewIntentListener(any(NewIntentListener.class));
    }
}
