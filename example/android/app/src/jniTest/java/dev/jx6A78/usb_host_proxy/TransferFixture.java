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
import android.hardware.usb.UsbRequest;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Substitutes the Android framework objects below the real plugin and JNI bindings. */
public final class TransferFixture {
    private static final String NAME = "/dev/bus/usb/001/002";
    private static volatile boolean present;
    private static volatile boolean entered;
    private static CountDownLatch resume;
    private static final AtomicBoolean waitError = new AtomicBoolean();
    private static final AtomicInteger untimedWaits = new AtomicInteger();
    private static final Map<UsbDeviceConnection, LinkedBlockingDeque<Queued>> requests = new ConcurrentHashMap<>();

    private record Queued(UsbRequest request, boolean input, ByteBuffer buffer) {}

    public static void install(long engineId) throws ReflectiveOperationException {
        Field field = UsbHostProxy.Session.class.getDeclaredField("context");
        field.setAccessible(true);
        Context context = (Context) field.get(UsbHostProxy.session(engineId));
        UsbManager manager = mock(UsbManager.class);
        UsbDevice device = mock(UsbDevice.class);
        UsbInterface intf = mock(UsbInterface.class);
        UsbEndpoint in = mock(UsbEndpoint.class);
        UsbEndpoint out = mock(UsbEndpoint.class);
        UsbEndpoint unsupported = mock(UsbEndpoint.class);
        when(device.getDeviceName()).thenReturn(NAME);
        when(device.getInterface(0)).thenReturn(intf);
        when(intf.getEndpoint(0)).thenReturn(in);
        when(intf.getEndpoint(1)).thenReturn(out);
        when(intf.getEndpoint(2)).thenReturn(unsupported);
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
        }, engineId, () -> request(in, out));
    }

    public static void prepare() {
        present = true;
        entered = false;
        resume = new CountDownLatch(1);
        waitError.set(false);
        untimedWaits.set(0);
    }

    public static void removeDevice() { present = false; }
    public static boolean transferEntered() { return entered; }
    public static void resumeTransfer() { resume.countDown(); }
    public static void failNextWait() { waitError.set(true); }
    public static int untimedWaitCount() { return untimedWaits.get(); }
    public static void dispose(long engineId) { UsbHostProxy.detach(engineId); }

    private static UsbDeviceConnection connection(UsbEndpoint in, UsbEndpoint out) throws TimeoutException {
        UsbDeviceConnection connection = mock(UsbDeviceConnection.class);
        LinkedBlockingDeque<Queued> queue = new LinkedBlockingDeque<>();
        requests.put(connection, queue);
        when(connection.requestWait()).thenAnswer(call -> {
            untimedWaits.incrementAndGet();
            return receiveRequest(queue, null);
        });
        when(connection.requestWait(anyLong())).thenAnswer(call -> receiveRequest(queue, call.getArgument(0)));
        doAnswer(call -> { requests.remove(connection); return null; }).when(connection).close();
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

    private static UsbRequest receiveRequest(LinkedBlockingDeque<Queued> queue, Long timeout)
            throws InterruptedException, TimeoutException {
        if (waitError.getAndSet(false)) return null;
        // Bound the untimed framework double so a regression cannot strand the fixture.
        Queued completed = timeout == null ? queue.pollFirst(10, TimeUnit.SECONDS)
                : queue.pollFirst(timeout, TimeUnit.MILLISECONDS);
        if (completed == null) throw new TimeoutException();
        ByteBuffer buffer = completed.buffer();
        if (buffer != null && buffer.hasRemaining()) {
            if (completed.input()) {
                buffer.put((byte) 0x80);
                if (buffer.hasRemaining()) buffer.put((byte) 0xff);
                if (buffer.hasRemaining()) buffer.put(buffer.position(), (byte) 0x7f);
            } else {
                buffer.position(1);
            }
        }
        return completed.request();
    }

    private static UsbRequest request(UsbEndpoint in, UsbEndpoint out) {
        UsbRequest request = mock(UsbRequest.class);
        AtomicReference<LinkedBlockingDeque<Queued>> queue = new AtomicReference<>();
        AtomicBoolean input = new AtomicBoolean();
        when(request.initialize(any(), any())).thenAnswer(call -> {
            UsbEndpoint endpoint = call.getArgument(1);
            if (endpoint != in && endpoint != out) return false;
            input.set(endpoint == in);
            queue.set(requests.get(call.getArgument(0)));
            check(queue.get() != null);
            return true;
        });
        when(request.queue(nullable(ByteBuffer.class))).thenAnswer(call -> {
            ByteBuffer buffer = call.getArgument(0);
            if (!input.get() && buffer != null && buffer.hasRemaining()) {
                byte[] data = new byte[buffer.remaining()];
                buffer.duplicate().get(data);
                check(Arrays.equals(data, new byte[] {(byte) 0xfe, 0x51, 0x42}));
            }
            // Return later submissions first to exercise identity matching across endpoints.
            queue.get().addFirst(new Queued(request, input.get(), buffer));
            return true;
        });
        when(request.cancel()).thenAnswer(call ->
            queue.get().stream().anyMatch(pending -> pending.request() == request));
        return request;
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
