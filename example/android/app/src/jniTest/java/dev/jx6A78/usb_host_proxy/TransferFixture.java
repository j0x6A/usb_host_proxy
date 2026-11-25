package dev.jx6A78.usb_host_proxy;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import android.content.Context;
import android.content.ContextWrapper;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import java.lang.reflect.Field;
import java.util.Arrays;
import java.util.HashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Substitutes the Android framework objects below the real plugin and JNI bindings. */
public final class TransferFixture {
    private static final String NAME = "/dev/bus/usb/001/002";
    private static volatile boolean present;
    private static volatile boolean entered;
    private static CountDownLatch resume;

    public static void install(long engineId) throws ReflectiveOperationException {
        Field field = UsbHostProxy.Session.class.getDeclaredField("context");
        field.setAccessible(true);
        Context context = (Context) field.get(UsbHostProxy.session(engineId));
        UsbManager manager = mock(UsbManager.class);
        UsbDevice device = mock(UsbDevice.class);
        UsbInterface intf = mock(UsbInterface.class);
        UsbEndpoint in = mock(UsbEndpoint.class);
        UsbEndpoint out = mock(UsbEndpoint.class);
        when(device.getDeviceName()).thenReturn(NAME);
        when(device.getInterface(0)).thenReturn(intf);
        when(intf.getEndpoint(0)).thenReturn(in);
        when(intf.getEndpoint(1)).thenReturn(out);
        when(in.getDirection()).thenReturn(0x80);
        when(manager.getDeviceList()).thenAnswer(call -> {
            HashMap<String, UsbDevice> devices = new HashMap<>();
            if (present) devices.put(NAME, device);
            return devices;
        });
        when(manager.openDevice(device)).thenAnswer(call -> connection(in, out));
        UsbHostProxy.attach(new ContextWrapper(context) {
            @Override public Context getApplicationContext() { return this; }
            @Override public Object getSystemService(String name) {
                return Context.USB_SERVICE.equals(name) ? manager : super.getSystemService(name);
            }
        }, engineId);
    }

    public static void prepare() {
        present = true;
        entered = false;
        resume = new CountDownLatch(1);
    }

    public static void removeDevice() { present = false; }
    public static boolean transferEntered() { return entered; }
    public static void resumeTransfer() { resume.countDown(); }
    public static void dispose(long engineId) { UsbHostProxy.detach(engineId); }

    private static UsbDeviceConnection connection(UsbEndpoint in, UsbEndpoint out) {
        UsbDeviceConnection connection = mock(UsbDeviceConnection.class);
        when(connection.bulkTransfer(any(), any(), anyInt(), anyInt(), anyInt())).thenAnswer(call -> {
            UsbEndpoint endpoint = call.getArgument(0);
            byte[] bytes = call.getArgument(1);
            int size = call.getArgument(3);
            int timeout = call.getArgument(4);
            check(call.getArgument(2).equals(0) && size == (bytes == null ? 0 : bytes.length));
            if (timeout == 0 && endpoint == in && bytes == null) {
                CountDownLatch gate = resume;
                entered = true;
                check(gate.await(10, TimeUnit.SECONDS));
                return 0;
            }
            check(size == 3);
            if (endpoint == in) {
                check(timeout == 91);
                return receive(bytes);
            }
            check(endpoint == out && timeout == 92);
            check(Arrays.equals(bytes, new byte[] {(byte) 0xfe, 0x51, 0x42}));
            return 1;
        });
        when(connection.controlTransfer(anyInt(), anyInt(), anyInt(), anyInt(), any(),
                anyInt(), anyInt(), anyInt())).thenAnswer(call -> {
            int type = call.getArgument(0);
            int request = call.getArgument(1);
            byte[] bytes = call.getArgument(4);
            int size = call.getArgument(6);
            int timeout = call.getArgument(7);
            check(call.getArgument(2).equals(0x1234) && call.getArgument(3).equals(0x4321));
            check(call.getArgument(5).equals(0) && size == (bytes == null ? 0 : bytes.length));
            return switch (request) {
                case 1 -> {
                    check(type == 0xc0 && timeout == 93 && size == 3);
                    yield receive(bytes);
                }
                case 2 -> {
                    check(type == 0x40 && timeout == 94);
                    check(Arrays.equals(bytes, new byte[] {(byte) 0xfe, 0x51, 0x42}));
                    yield 1;
                }
                case 3 -> {
                    check(type == 0x40 && timeout == 0 && bytes == null);
                    yield 0;
                }
                case 4 -> throw new IllegalArgumentException("invalid setup");
                case 5 -> throw new SecurityException("USB access denied");
                case 6 -> {
                    check(type == 0xc0 && timeout == 95 && size == 3);
                    receive(bytes);
                    yield -7;
                }
                case 7 -> {
                    check(type == 0xc0 && timeout == 0 && bytes != null && size == 0);
                    yield 0;
                }
                default -> throw new AssertionError("unexpected request " + request);
            };
        });
        return connection;
    }

    private static int receive(byte[] buffer) {
        buffer[0] = (byte) 0x80;
        buffer[1] = (byte) 0xff;
        buffer[2] = 0x7f;
        return 2;
    }

    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("unexpected transfer arguments or gate timeout");
    }
}
