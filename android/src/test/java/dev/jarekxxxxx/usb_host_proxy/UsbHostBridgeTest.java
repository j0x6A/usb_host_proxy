package dev.jarekxxxxx.usb_host_proxy;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.robolectric.Shadows.shadowOf;

import android.app.PendingIntent;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbConfiguration;
import android.hardware.usb.UsbManager;
import android.os.Looper;
import java.util.HashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35, manifest = Config.NONE)
public class UsbHostBridgeTest {
    private UsbManager manager;
    private Context context;
    private UsbDevice usb;
    private UsbDeviceConnection nativeConnection;
    private UsbHostBridge.Session session;
    private UsbHostBridge.Device device;

    private static final class Result implements UsbHostBridge.Completion {
        final CountDownLatch done = new CountDownLatch(1);
        Object value;
        Throwable error;
        int completions;
        @Override public void success(Object value) { this.value = value; completions++; done.countDown(); }
        @Override public void failure(Throwable error) { this.error = error; completions++; done.countDown(); }
        Result await() throws InterruptedException {
            assertTrue("USB operation timed out", done.await(10, TimeUnit.SECONDS));
            return this;
        }
    }

    @Before public void setUp() {
        manager = mock(UsbManager.class);
        context = new ContextWrapper(RuntimeEnvironment.getApplication()) {
            @Override public Context getApplicationContext() { return this; }
            @Override public Object getSystemService(String name) {
                return Context.USB_SERVICE.equals(name) ? manager : super.getSystemService(name);
            }
        };
        usb = mock(UsbDevice.class);
        when(usb.getDeviceName()).thenReturn("/dev/bus/usb/001/002");
        HashMap<String, UsbDevice> found = new HashMap<>();
        found.put(usb.getDeviceName(), usb);
        when(manager.getDeviceList()).thenReturn(found);
        nativeConnection = mock(UsbDeviceConnection.class);
        when(manager.openDevice(usb)).thenReturn(nativeConnection);
        UsbHostBridge.attach(context, 42);
        session = UsbHostBridge.session(42);
        device = session.deviceList()[0];
    }

    @After public void tearDown() { UsbHostBridge.detach(42); }

    private UsbHostBridge.Connection open() throws Exception {
        Result result = new Result();
        session.open(device, result);
        assertNull(result.await().error);
        return (UsbHostBridge.Connection) result.value;
    }

    private void detachDevice() {
        context.sendBroadcast(new Intent(UsbManager.ACTION_USB_DEVICE_DETACHED)
            .putExtra(UsbManager.EXTRA_DEVICE, usb));
        shadowOf(Looper.getMainLooper()).idle();
    }

    @Test public void enumerationKeepsNativeObjectsAndDoesNotSynthesizeStartupAttach() {
        UsbHostBridge.Events events = mock(UsbHostBridge.Events.class);
        session.listen(events);
        assertSame(device, session.deviceList()[0]);
        assertSame(usb, device.usbDevice);
        verifyNoInteractions(events);
        context.sendBroadcast(new Intent(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            .putExtra(UsbManager.EXTRA_DEVICE, usb));
        shadowOf(Looper.getMainLooper()).idle();
        verify(events).attached(device);
    }

    @Test public void queuesAreIndependentAndCloseWaitsForInflightOperation() throws Exception {
        UsbHostBridge.Connection first = open();
        UsbDeviceConnection otherNativeConnection = mock(UsbDeviceConnection.class);
        when(manager.openDevice(usb)).thenReturn(otherNativeConnection);
        UsbHostBridge.Connection second = open();
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.getSerial()).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return "serial";
        });
        Result reading = new Result();
        first.serial(reading);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        Result closing = new Result();
        try {
            first.close(closing);
            Result other = new Result();
            second.close(other);
            assertNull(other.await().error);
            // Only the second connection can close while the first is busy.
            verify(otherNativeConnection, times(1)).close();
            verify(nativeConnection, never()).close();
            assertEquals(1, closing.done.getCount());
        } finally { unblock.countDown(); }
        assertNull(reading.await().error);
        assertNull(closing.await().error);
    }

    @Test public void repeatedCloseIsIdempotentAndUseAfterCloseFails() throws Exception {
        UsbHostBridge.Connection connection = open();
        Result first = new Result();
        Result second = new Result();
        connection.close(first);
        connection.close(second);
        assertNull(first.await().error);
        assertNull(second.await().error);
        verify(nativeConnection, times(1)).close();
        assertThrows(IllegalStateException.class, connection::fileDescriptor);
        Result serial = new Result();
        connection.serial(serial);
        assertTrue(serial.await().error instanceof IllegalStateException);
    }

    @Test public void detachInvalidatesOldAttachmentEvenWhenNameIsReused() throws Exception {
        UsbHostBridge.Connection connection = open();
        detachDevice();
        assertFalse(session.hasPermission(device));
        assertThrows(IllegalStateException.class, connection::rawDescriptors);
        UsbHostBridge.Device replacement = session.deviceList()[0];
        assertNotSame(device, replacement);
        Result stale = new Result();
        session.open(device, stale);
        assertTrue(stale.await().error instanceof IllegalStateException);
        Result cleanup = new Result();
        connection.close(cleanup);
        cleanup.await();
        verify(nativeConnection).close();
    }

    @Test public void permissionRequestsCoalesceAndReplyCompletesAllWaiters() throws Exception {
        AtomicReference<PendingIntent> intent = new AtomicReference<>();
        CountDownLatch requested = new CountDownLatch(1);
        doAnswer(call -> { intent.set(call.getArgument(1)); requested.countDown(); return null; })
            .when(manager).requestPermission(eq(usb), any(PendingIntent.class));
        Result one = new Result();
        Result two = new Result();
        session.requestPermission(device, one);
        session.requestPermission(device, two);
        assertTrue(requested.await(10, TimeUnit.SECONDS));
        when(manager.hasPermission(usb)).thenReturn(true);
        intent.get().send(context, 0, new Intent()
            .putExtra(UsbManager.EXTRA_DEVICE, usb)
            .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true));
        shadowOf(Looper.getMainLooper()).idle();
        assertEquals(true, one.await().value);
        assertEquals(true, two.await().value);
        verify(manager, times(1)).requestPermission(eq(usb), any(PendingIntent.class));
    }

    @Test public void detachResolvesPermissionFalseAndRejectsLateReply() throws Exception {
        Result permission = new Result();
        session.requestPermission(device, permission);
        detachDevice();
        assertEquals(false, permission.await().value);
        assertEquals(1, permission.completions);
    }

    @Test public void sessionEndFailsPendingPermissionsAndInvalidatesOldSession() throws Exception {
        Result permission = new Result();
        session.requestPermission(device, permission);
        UsbHostBridge.detach(42);
        assertTrue(permission.await().error instanceof IllegalStateException);
        assertThrows(IllegalStateException.class, session::deviceList);
        UsbHostBridge.attach(context, 42);
        assertNotSame(session, UsbHostBridge.session(42));
    }

    @Test public void openFailureIsNotChangedIntoNullAndNativeNullIsPreserved() throws Exception {
        SecurityException denial = new SecurityException("denied");
        when(manager.openDevice(usb)).thenThrow(denial);
        Result failed = new Result();
        session.open(device, failed);
        assertSame(denial, failed.await().error);
        doReturn(null).when(manager).openDevice(usb);
        Result missing = new Result();
        session.open(device, missing);
        assertNull(missing.await().error);
        assertNull(missing.value);
    }

    @Test public void interfacesAndConfigurationUseOriginalObjectsAndRejectOtherDevices() throws Exception {
        UsbInterface intf = mock(UsbInterface.class);
        UsbConfiguration config = mock(UsbConfiguration.class);
        when(usb.getInterfaceCount()).thenReturn(1);
        when(usb.getInterface(0)).thenReturn(intf);
        when(usb.getConfigurationCount()).thenReturn(1);
        when(usb.getConfiguration(0)).thenReturn(config);
        when(nativeConnection.claimInterface(intf, true)).thenReturn(true);
        when(nativeConnection.releaseInterface(intf)).thenReturn(true);
        when(nativeConnection.setInterface(intf)).thenReturn(true);
        when(nativeConnection.setConfiguration(config)).thenReturn(true);
        UsbHostBridge.Connection connection = open();
        Result claim = new Result();
        Result select = new Result();
        Result configuration = new Result();
        Result release = new Result();
        connection.claim(intf, true, claim);
        connection.selectInterface(intf, select);
        connection.selectConfiguration(config, configuration);
        connection.release(intf, release);
        assertEquals(true, claim.await().value);
        assertEquals(true, select.await().value);
        assertEquals(true, configuration.await().value);
        assertEquals(true, release.await().value);
        org.mockito.InOrder order = inOrder(nativeConnection);
        order.verify(nativeConnection).claimInterface(intf, true);
        order.verify(nativeConnection).setInterface(intf);
        order.verify(nativeConnection).setConfiguration(config);
        order.verify(nativeConnection).releaseInterface(intf);
        Result wrong = new Result();
        connection.claim(mock(UsbInterface.class), false, wrong);
        assertTrue(wrong.await().error instanceof IllegalArgumentException);
        Result closed = new Result();
        connection.close(closed);
        closed.await();
    }

    @Test public void detachingDuringOpenClosesUnpublishedNativeConnection() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(manager.openDevice(usb)).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return nativeConnection;
        });
        Result opened = new Result();
        session.open(device, opened);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        try { detachDevice(); }
        finally { unblock.countDown(); }
        assertTrue(opened.await().error instanceof IllegalStateException);
        verify(nativeConnection).close();
    }

    @Test public void failingEventListenerCannotInterruptSessionCleanup() throws Exception {
        UsbHostBridge.Connection connection = open();
        UsbHostBridge.Events events = mock(UsbHostBridge.Events.class);
        doThrow(new IllegalStateException("dead isolate")).when(events).disposed();
        session.listen(events);
        UsbHostBridge.detach(42);
        assertThrows(IllegalStateException.class, session::deviceList);
        Result closed = new Result();
        connection.close(closed);
        closed.await();
        verify(nativeConnection).close();
    }

    @Test public void explicitCloseDrainsAlreadyAcceptedOperationsInOrder() throws Exception {
        UsbHostBridge.Connection connection = open();
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.getSerial()).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return "serial";
        });
        Result first = new Result();
        Result queued = new Result();
        Result closed = new Result();
        connection.serial(first);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        try {
            connection.serial(queued);
            connection.close(closed);
        } finally { unblock.countDown(); }
        assertEquals("serial", first.await().value);
        assertEquals("serial", queued.await().value);
        assertNull(closed.await().error);
        org.mockito.InOrder order = inOrder(nativeConnection);
        order.verify(nativeConnection, times(2)).getSerial();
        order.verify(nativeConnection).close();
    }
}
