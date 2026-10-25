package dev.jx6A78.usb_host_proxy;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import android.content.Context;
import android.content.ContextWrapper;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.hardware.usb.UsbRequest;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.MockedConstruction;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

/** Native boundary tests, not a simulation of Android USB scheduling or hardware. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = {28, 31, 33, 35}, manifest = Config.NONE)
public class UsbTransportTest {
    /** Framework connection double; each test specifies its native result or blocking gate. */
    private UsbDeviceConnection nativeConnection;
    /** Published backend owner; teardown awaits its queued close before ending the session. */
    private UsbHostProxy.Connection connection;
    /** Original descriptor references accepted by endpoint-ownership validation. */
    private UsbEndpoint input;
    private UsbEndpoint output;
    private UsbHostProxy.Session session;
    /** Live discovery snapshot; removing an entry alone does not deliver an event. */
    private HashMap<String, UsbDevice> devices;
    /** Intercepts only native request construction, not the backend wrapper's lifecycle. */
    private MockedConstruction<UsbRequest> construction;
    /** Native initialize result read by the request constructor fixture. */
    private boolean initializes;

    /** Records native callbacks including duplicate attempts, with only a test timeout. */
    private static final class Result implements UsbHostProxy.Completion {
        final CountDownLatch done = new CountDownLatch(1);
        volatile Object value;
        volatile Throwable error;
        volatile int deliveries;
        @Override public void success(Object value) {
            this.value = value;
            deliveries++;
            done.countDown();
        }
        @Override public void failure(Throwable error) {
            this.error = error;
            deliveries++;
            done.countDown();
        }
        /** Bounds a test failure, never a production USB operation. */
        Result await() throws InterruptedException {
            assertTrue("Completion not delivered", done.await(10, TimeUnit.SECONDS));
            return this;
        }
    }

    /** Opens a real backend session around mocked framework objects, without USB/JNI. */
    @Before public void setUp() throws Exception {
        UsbManager manager = mock(UsbManager.class);
        Context context = new ContextWrapper(RuntimeEnvironment.getApplication()) {
            @Override public Context getApplicationContext() { return this; }
            @Override public Object getSystemService(String name) {
                return Context.USB_SERVICE.equals(name) ? manager : super.getSystemService(name);
            }
        };
        UsbDevice device = mock(UsbDevice.class);
        when(device.getDeviceName()).thenReturn("transport-device");
        devices = new HashMap<>();
        devices.put(device.getDeviceName(), device);
        when(manager.getDeviceList()).thenReturn(devices);
        UsbInterface intf = mock(UsbInterface.class);
        when(device.getInterfaceCount()).thenReturn(1);
        when(device.getInterface(0)).thenReturn(intf);
        input = mock(UsbEndpoint.class);
        output = mock(UsbEndpoint.class);
        when(input.getDirection()).thenReturn(UsbConstants.USB_DIR_IN);
        when(output.getDirection()).thenReturn(UsbConstants.USB_DIR_OUT);
        when(intf.getEndpointCount()).thenReturn(2);
        when(intf.getEndpoint(0)).thenReturn(input);
        when(intf.getEndpoint(1)).thenReturn(output);
        nativeConnection = mock(UsbDeviceConnection.class);
        when(manager.openDevice(device)).thenReturn(nativeConnection);
        initializes = true;
        construction = mockConstruction(UsbRequest.class, (request, ignored) -> {
            AtomicReference<Object> data = new AtomicReference<>();
            AtomicReference<UsbEndpoint> endpoint = new AtomicReference<>();
            when(request.initialize(any(), any())).thenAnswer(call -> {
                endpoint.set(call.getArgument(1));
                return initializes;
            });
            doAnswer(call -> { data.set(call.getArgument(0)); return null; }).when(request).setClientData(any());
            when(request.getClientData()).thenAnswer(call -> data.get());
            when(request.getEndpoint()).thenAnswer(call -> endpoint.get());
            doAnswer(call -> { endpoint.set(null); return null; }).when(request).close();
        });
        UsbHostProxy.attach(context, 73);
        session = UsbHostProxy.session(73);
        Result opened = new Result();
        session.open(session.deviceList()[0], opened);
        assertNull(opened.await().error);
        connection = (UsbHostProxy.Connection) opened.value;
    }

    /** Releases the connection before disposing its session and construction fixture. */
    @After public void tearDown() throws Exception {
        Result closed = new Result();
        if (connection != null) { connection.close(closed); closed.await(); }
        UsbHostProxy.detach(73);
        construction.close();
    }

    /** Last framework request created synchronously by initializeRequest on the test thread. */
    private UsbRequest lastNative() {
        return construction.constructed().get(construction.constructed().size() - 1);
    }

    @Test public void bulkForwardsOriginalArgumentsResultAndInputBytes() throws Exception {
        byte[] bytes = new byte[] {9, 9, 9, 9};
        when(nativeConnection.bulkTransfer(input, bytes, 1, 2, 0)).thenAnswer(call -> {
            bytes[1] = (byte) 0xff;
            return 1;
        });
        Result result = new Result();
        connection.bulk(input, bytes, 1, 2, 0, result);
        assertNull(result.await().error);
        assertEquals(1, result.value);
        assertArrayEquals(new byte[] {9, -1, 9, 9}, bytes);
        verify(nativeConnection).bulkTransfer(input, bytes, 1, 2, 0);
    }

    @Test public void nativeNegativeResultsAndExceptionsAreNotReplaced() throws Exception {
        when(nativeConnection.bulkTransfer(output, null, 0, 0, 41)).thenReturn(-1);
        Result negative = new Result();
        connection.bulk(output, null, 0, 0, 41, negative);
        assertEquals(-1, negative.await().value);
        SecurityException failure = new SecurityException("native failure");
        when(nativeConnection.bulkTransfer(output, null, 0, 0, 41)).thenThrow(failure);
        Result failed = new Result();
        connection.bulk(output, null, 0, 0, 41, failed);
        assertSame(failure, failed.await().error);
    }

    @Test public void controlForwardsSetupDirectionSliceAndTimeout() throws Exception {
        byte[] data = new byte[] {10, 11, 12, 13};
        when(nativeConnection.controlTransfer(0xa1, 2, 3, 4, data, 1, 2, 79)).thenReturn(2);
        Result result = new Result();
        connection.control(0xa1, 2, 3, 4, data, 1, 2, 79, result);
        assertEquals(2, result.await().value);
        verify(nativeConnection).controlTransfer(0xa1, 2, 3, 4, data, 1, 2, 79);
        when(nativeConnection.controlTransfer(0, 5, 0, 0, null, 0, 0, 0)).thenReturn(-1);
        Result empty = new Result();
        connection.control(0, 5, 0, 0, null, 0, 0, 0, empty);
        assertEquals(-1, empty.await().value);
    }

    @Test public void foreignEndpointsNeverReachNativeTransportOrInitialization() throws Exception {
        UsbEndpoint foreign = mock(UsbEndpoint.class);
        Result result = new Result();
        connection.bulk(foreign, null, 0, 0, 0, result);
        assertTrue(result.await().error instanceof IllegalArgumentException);
        assertThrows(IllegalArgumentException.class, () -> connection.initializeRequest(foreign));
        verify(nativeConnection, never()).bulkTransfer(any(), any(), anyInt(), anyInt(), anyInt());
        assertTrue(construction.constructed().isEmpty());
    }

    @Test public void initializationPreservesFalseAndCleansItsFailedNativeRequest() {
        initializes = false;
        assertNull(connection.initializeRequest(input));
        verify(lastNative()).initialize(nativeConnection, input);
        verify(lastNative()).close();
    }

    @Test public void requestRetainsEndpointAndNativeQueueResult() {
        UsbHostProxy.Request request = connection.initializeRequest(output);
        assertSame(output, request.endpoint());
        ByteBuffer bytes = ByteBuffer.allocateDirect(3);
        bytes.put(new byte[] {1, 2, 3}).flip();
        assertFalse(request.queue(bytes));
        when(lastNative().queue(bytes)).thenReturn(true);
        assertTrue(request.queue(bytes));
        assertThrows(IllegalStateException.class, () -> request.queue(ByteBuffer.allocateDirect(1)));
        verify(lastNative(), times(2)).queue(bytes);
    }

    @Test public void nullBufferQueuesARealZeroLengthRequest() throws Exception {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        when(lastNative().queue((ByteBuffer) null)).thenReturn(true);
        when(nativeConnection.requestWait()).thenReturn(lastNative());
        assertTrue(request.queue(null));
        Result wait = new Result();
        connection.waitRequest(false, 0, wait);
        UsbHostProxy.RequestResult result = (UsbHostProxy.RequestResult) wait.await().value;
        assertSame(request, result.request);
        assertNull(result.buffer);
        assertEquals(0, result.length);
    }

    @Test public void completionSnapshotsBufferAndCountBeforeRequeue() throws Exception {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        ByteBuffer first = ByteBuffer.allocateDirect(5);
        when(lastNative().queue(any(ByteBuffer.class))).thenReturn(true);
        when(nativeConnection.requestWait()).thenAnswer(call -> {
            first.put(new byte[] {(byte) 0x80, (byte) 0xff});
            return lastNative();
        });
        assertTrue(request.queue(first));
        Result wait = new Result();
        connection.waitRequest(false, 0, wait);
        UsbHostProxy.RequestResult result = (UsbHostProxy.RequestResult) wait.await().value;
        assertSame(request, result.request);
        assertSame(first, result.buffer);
        assertEquals(2, result.length);
        assertTrue(request.queue(ByteBuffer.allocateDirect(9)));
        assertSame(first, result.buffer);
        assertEquals(2, result.length);
        assertEquals((byte) 0xff, result.buffer.get(1));
    }

    @Test public void cancelPreservesResultAndDoesNotReleaseBufferBeforeWait() throws Exception {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        when(lastNative().queue(any(ByteBuffer.class))).thenReturn(true);
        ByteBuffer buffer = ByteBuffer.allocateDirect(2);
        assertTrue(request.queue(buffer));
        when(lastNative().cancel()).thenReturn(false, true);
        assertFalse(request.cancel());
        assertTrue(request.cancel());
        assertThrows(IllegalStateException.class, () -> request.queue(buffer));
        when(nativeConnection.requestWait()).thenReturn(lastNative());
        Result wait = new Result();
        connection.waitRequest(false, 0, wait);
        assertSame(buffer, ((UsbHostProxy.RequestResult) wait.await().value).buffer);
        assertTrue(request.queue(buffer));
    }

    @Test public void nativeQueueAndCancelExceptionsRemainExceptions() {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        IllegalStateException failure = new IllegalStateException("Android queue");
        when(lastNative().queue((ByteBuffer) null)).thenThrow(failure);
        assertSame(failure, assertThrows(IllegalStateException.class, () -> request.queue(null)));
        when(lastNative().cancel()).thenThrow(failure);
        assertSame(failure, assertThrows(IllegalStateException.class, request::cancel));
    }

    @Test public void timedWaitUsesNativeOverloadAndPreservesTimeoutAndNull() throws Exception {
        TimeoutException failure = new TimeoutException("native timeout");
        when(nativeConnection.requestWait(0)).thenThrow(failure);
        Result timeout = new Result();
        connection.waitRequest(true, 0, timeout);
        assertSame(failure, timeout.await().error);
        when(nativeConnection.requestWait(21)).thenReturn(null);
        Result empty = new Result();
        connection.waitRequest(true, 21, empty);
        assertNull(empty.await().error);
        assertNull(empty.value);
        verify(nativeConnection, never()).requestWait();
    }

    @Test public void nativeWaitAndControlExceptionsKeepTheirOriginalObjects() throws Exception {
        IllegalArgumentException invalid = new IllegalArgumentException("native negative timeout");
        when(nativeConnection.requestWait(-2)).thenThrow(invalid);
        Result wait = new Result();
        connection.waitRequest(true, -2, wait);
        assertSame(invalid, wait.await().error);
        SecurityException denied = new SecurityException("native control permission");
        when(nativeConnection.controlTransfer(0, 0, 0, 0, null, 0, 0, 0)).thenThrow(denied);
        Result control = new Result();
        connection.control(0, 0, 0, 0, null, 0, 0, 0, control);
        assertSame(denied, control.await().error);
    }

    @Test public void closingRequestDuringWaitDoesNotDeliverItsAbandonedBuffer() throws Exception {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        UsbRequest nativeRequest = lastNative();
        when(nativeRequest.queue(any(ByteBuffer.class))).thenReturn(true);
        assertTrue(request.queue(ByteBuffer.allocateDirect(3)));
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.requestWait()).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return nativeRequest;
        });
        Result wait = new Result();
        connection.waitRequest(false, 0, wait);
        try {
            assertTrue(entered.await(10, TimeUnit.SECONDS));
            request.close();
            request.close();
            assertNull(request.endpoint());
        } finally { unblock.countDown(); }
        assertTrue(wait.await().error instanceof IllegalStateException);
        assertNull(wait.value);
        verify(nativeRequest).close();
    }

    @Test public void nativeCloseFailureStillCleansRequestsWithoutSeparateRelease() throws Exception {
        connection.initializeRequest(input);
        IllegalStateException failure = new IllegalStateException("native close failure");
        doThrow(failure).when(nativeConnection).close();
        // Reusing the same Throwable must not cause self-suppression to abort cleanup.
        doThrow(failure).when(lastNative()).close();
        Result closed = new Result();
        connection.close(closed);
        assertSame(failure, closed.await().error);
        verify(lastNative()).close();
        verify(nativeConnection, never()).releaseInterface(any());
        assertThrows(IllegalStateException.class, () -> connection.initializeRequest(input));
    }

    @Test public void requestsFromAnyEndpointAreReturnedByIdentity() throws Exception {
        UsbHostProxy.Request first = connection.initializeRequest(input);
        UsbRequest nativeFirst = lastNative();
        UsbHostProxy.Request second = connection.initializeRequest(output);
        UsbRequest nativeSecond = lastNative();
        when(nativeConnection.requestWait()).thenReturn(nativeSecond, nativeFirst);
        Result a = new Result();
        connection.waitRequest(false, 0, a);
        assertSame(second, ((UsbHostProxy.RequestResult) a.await().value).request);
        Result b = new Result();
        connection.waitRequest(false, 0, b);
        assertSame(first, ((UsbHostProxy.RequestResult) b.await().value).request);
    }

    @Test public void blockingTransfersRunInParallelWithManagementAndClose() throws Exception {
        CountDownLatch entered = new CountDownLatch(2);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.bulkTransfer(input, null, 0, 0, 0)).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return -1;
        });
        Result first = new Result();
        Result second = new Result();
        connection.bulk(input, null, 0, 0, 0, first);
        connection.bulk(input, null, 0, 0, 0, second);
        try {
            assertTrue("Transfers serialized", entered.await(10, TimeUnit.SECONDS));
            Result serial = new Result();
            connection.serial(serial);
            assertNull(serial.await().error);
            Result closed = new Result();
            connection.close(closed);
            assertNull(closed.await().error);
            verify(nativeConnection).close();
        } finally { unblock.countDown(); }
        assertEquals(-1, first.await().value);
        assertEquals(-1, second.await().value);
    }

    @Test public void blockedWaitDoesNotBlockCancelCloseOrOtherWaits() throws Exception {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.requestWait()).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return null;
        });
        Result waiting = new Result();
        connection.waitRequest(false, 0, waiting);
        try {
            assertTrue(entered.await(10, TimeUnit.SECONDS));
            when(lastNative().cancel()).thenReturn(true);
            assertTrue(request.cancel());
            Result poll = new Result();
            connection.waitRequest(true, 0, poll);
            assertNull(poll.await().error);
            Result closed = new Result();
            connection.close(closed);
            assertNull(closed.await().error);
            verify(lastNative()).close();
        } finally { unblock.countDown(); }
        assertNull(waiting.await().error);
    }

    @Test public void closeIsIdempotentAndRejectsNewTransportWithoutReleasingInterfaces() throws Exception {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        request.close();
        assertFalse(request.cancel());
        assertThrows(IllegalStateException.class, () -> request.queue(null));
        Result bulk = new Result();
        connection.bulk(input, null, 0, 0, 0, bulk);
        assertTrue(bulk.await().error instanceof IllegalStateException);
        Result control = new Result();
        connection.control(0, 0, 0, 0, null, 0, 0, 0, control);
        assertTrue(control.await().error instanceof IllegalStateException);
        Result wait = new Result();
        connection.waitRequest(false, 0, wait);
        assertTrue(wait.await().error instanceof IllegalStateException);
        verify(nativeConnection, never()).releaseInterface(any());
        verify(nativeConnection, never()).bulkTransfer(any(), any(), anyInt(), anyInt(), anyInt());
        verify(nativeConnection, never()).requestWait();
        verify(lastNative()).close();
    }

    @Test public void detachClosesRequestsAndRejectsFurtherWork() throws Exception {
        UsbHostProxy.Request request = connection.initializeRequest(input);
        Result observed = new Result();
        connection.whenClosed(observed);
        assertEquals(1, observed.done.getCount());
        verify(nativeConnection, never()).close();
        devices.clear();
        session.deviceList();
        assertNull(observed.await().error);
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        verify(lastNative()).close();
        assertFalse(request.cancel());
        assertThrows(IllegalStateException.class, () -> request.queue(null));
        assertEquals(1, observed.deliveries);
    }

    @Test public void closeObserversAreSettledOnSessionShutdownAndLateRegistration() throws Exception {
        Result observed = new Result();
        connection.whenClosed(observed);
        UsbHostProxy.detach(73);
        observed.await();
        assertEquals(1, observed.deliveries);
        Result late = new Result();
        connection.whenClosed(late);
        assertTrue(late.await().error instanceof IllegalStateException);
    }

    @Test public void sessionShutdownSettlesBlockedTransportExactlyOnce() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        CountDownLatch returned = new CountDownLatch(1);
        when(nativeConnection.bulkTransfer(input, null, 0, 0, 0)).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            returned.countDown();
            return -1;
        });
        Result transfer = new Result();
        connection.bulk(input, null, 0, 0, 0, transfer);
        try {
            assertTrue(entered.await(10, TimeUnit.SECONDS));
            UsbHostProxy.detach(73);
            assertTrue(transfer.await().error instanceof IllegalStateException);
        } finally { unblock.countDown(); }
        assertTrue(returned.await(10, TimeUnit.SECONDS));
        Result closed = new Result();
        connection.close(closed);
        closed.await();
        assertEquals(1, transfer.deliveries);
    }
}
