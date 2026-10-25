package dev.jx6A78.usb_host_proxy;

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
import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

/**
 * Backend contract tests using mocked USB objects, not physical USB or Dart-JNI calls.
 * Test names identify the scenario and expected invariant. The SDK matrix covers
 * the pre/post-31 PendingIntent and pre/post-33 receiver/Parcelable branches.
 */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = {28, 31, 33, 35}, manifest = Config.NONE)
public class UsbHostProxyTest {
    /** Framework service double; its responses are controlled independently of events. */
    private UsbManager manager;
    /** Real Robolectric application context with only the USB service overridden. */
    private Context context;
    /** Initial native descriptor double at the reusable Android name. */
    private UsbDevice usb;
    /** Native connection returned when the initial device is opened. */
    private UsbDeviceConnection nativeConnection;
    /** Engine 42's backend session, replaced only in lifecycle-specific tests. */
    private UsbHostProxy.Session session;
    /** Initial canonical wrapper; retained to test stale attachment rejection. */
    private UsbHostProxy.Device device;
    /** Simulated live discovery list; broadcasting alone does not change presence. */
    private HashMap<String, UsbDevice> attachedDevices;

    /** Records callbacks without suppressing duplicates, so assertions can detect them. */
    private static final class Result implements UsbHostProxy.Completion {
        /** Publishes the first result from a worker to the awaiting test thread. */
        final CountDownLatch done = new CountDownLatch(1);
        /** Last successful payload, including false or null native results. */
        Object value;
        /** Last failure, if any; kept separate from a successful null value. */
        Throwable error;
        /** Number of deliveries, used to detect a late second completion. */
        int completions;

        /** Records success before releasing the waiter. */
        @Override public void success(Object value) {
            this.value = value;
            completions++;
            done.countDown();
        }

        /** Records failure before releasing the waiter. */
        @Override public void failure(Throwable error) {
            this.error = error;
            completions++;
            done.countDown();
        }

        /** Bounds test waiting; this is not a production USB permission timeout. */
        Result await() throws InterruptedException {
            assertTrue("USB operation timed out", done.await(10, TimeUnit.SECONDS));
            return this;
        }
    }

    /** Starts a session with one present device; no USB hardware is accessed. */
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
        attachedDevices = new HashMap<>();
        attachedDevices.put(usb.getDeviceName(), usb);
        when(manager.getDeviceList()).thenReturn(attachedDevices);
        nativeConnection = mock(UsbDeviceConnection.class);
        when(manager.openDevice(usb)).thenReturn(nativeConnection);
        UsbHostProxy.attach(context, 42);
        session = UsbHostProxy.session(42);
        device = session.deviceList()[0];
    }

    /** Disposes pending work and schedules any remaining connection cleanup. */
    @After public void tearDown() {
        UsbHostProxy.detach(42);
    }

    /** Opens the initial attachment and waits for its Java completion callback. */
    private UsbHostProxy.Connection open() throws Exception {
        Result result = new Result();
        session.open(device, result);
        assertNull(result.await().error);
        return (UsbHostProxy.Connection) result.value;
    }

    /** Removes live presence before delivering detach, then drains receiver callbacks. */
    private void detachDevice() {
        attachedDevices.remove(usb.getDeviceName());
        context.sendBroadcast(new Intent(UsbManager.ACTION_USB_DEVICE_DETACHED)
            .putExtra(UsbManager.EXTRA_DEVICE, usb));
        shadowOf(Looper.getMainLooper()).idle();
    }

    /** Inspects private identity without adding a test-only public JNI accessor. */
    private static String internalId(UsbHostProxy.Device device) throws Exception {
        Field field = UsbHostProxy.Device.class.getDeclaredField("internalId");
        field.setAccessible(true);
        return (String) field.get(device);
    }

    /** Replaces the discovery object only; this alone is not proof of reattachment. */
    private UsbDevice sameNameDevice() {
        UsbDevice replacement = mock(UsbDevice.class);
        String name = usb.getDeviceName();
        when(replacement.getDeviceName()).thenReturn(name);
        attachedDevices.put(replacement.getDeviceName(), replacement);
        return replacement;
    }

    /** Delivers a queued event independently of the separately controlled live list. */
    private void broadcast(String action, UsbDevice payload) {
        context.sendBroadcast(new Intent(action).putExtra(UsbManager.EXTRA_DEVICE, payload));
        shadowOf(Looper.getMainLooper()).idle();
    }

    @Test public void enumerationKeepsNativeObjectsAndDoesNotSynthesizeStartupAttach() throws Exception {
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        assertSame(device, session.deviceList()[0]);
        assertSame(usb, device.usbDevice);
        String id = internalId(device);
        String prefix = usb.getDeviceName() + "-";
        assertTrue(id.startsWith(prefix));
        UUID.fromString(id.substring(prefix.length()));
        verifyNoInteractions(events);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        assertEquals(id, internalId(session.deviceList()[0]));
        verify(events).attached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void newFrameworkObjectWithSameNameDoesNotProveReattachment() throws Exception {
        String id = internalId(device);
        UsbDevice snapshot = sameNameDevice();
        assertNotSame(usb, snapshot);
        assertSame(device, session.deviceList()[0]);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, snapshot);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        assertSame(device, session.deviceList()[0]);
        assertSame(usb, device.usbDevice);
        assertEquals(id, internalId(device));
    }

    @Test public void secondListenerIsRejectedWithoutReplacingTheOriginal() {
        UsbHostProxy.Events first = mock(UsbHostProxy.Events.class);
        UsbHostProxy.Events second = mock(UsbHostProxy.Events.class);
        session.listen(first);
        assertThrows(IllegalStateException.class, () -> session.listen(second));
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        verify(first).attached(device);
        verifyNoInteractions(second);
    }

    @Test public void observedAbsenceAndDuplicateEventsRetireOnlyOnce() throws Exception {
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        UsbHostProxy.Connection connection = open();
        attachedDevices.clear();
        assertEquals(0, session.deviceList().length);
        assertEquals(0, session.deviceList().length);
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        assertEquals(0, session.deviceList().length);
        assertThrows(IllegalStateException.class, connection::fileDescriptor);
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        verify(nativeConnection).close();
        verify(events).detached(device);
        attachedDevices.put(usb.getDeviceName(), usb);
        UsbHostProxy.Device replacement = session.deviceList()[0];
        assertNotSame(device, replacement);
        assertNotEquals(internalId(device), internalId(replacement));
        verifyNoMoreInteractions(events);
    }

    @Test public void obsoleteAttachUsesObservedAbsenceInsteadOfCreatingAnAttachment() {
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        attachedDevices.clear();
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        assertEquals(0, session.deviceList().length);
        assertFalse(session.hasPermission(device));
        verify(events).detached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void delayedDetachCannotInvalidatePresentReplacementOrItsConnection() throws Exception {
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        detachDevice();
        UsbDevice replacementUsb = sameNameDevice();
        // Even a delayed old attach must use the live framework reference.
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        UsbHostProxy.Device replacement = session.deviceList()[0];
        assertSame(replacementUsb, replacement.usbDevice);
        assertNotEquals(internalId(device), internalId(replacement));
        UsbDeviceConnection replacementNative = mock(UsbDeviceConnection.class);
        when(manager.openDevice(replacementUsb)).thenReturn(replacementNative);
        when(replacementNative.getFileDescriptor()).thenReturn(23);
        Result opened = new Result();
        session.open(replacement, opened);
        assertNull(opened.await().error);
        UsbHostProxy.Connection connection = (UsbHostProxy.Connection) opened.value;
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, replacementUsb);
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, usb);
        assertSame(replacement, session.deviceList()[0]);
        assertEquals(23, connection.fileDescriptor());
        verify(replacementNative, never()).close();
        verify(events).detached(device);
        verify(events).attached(replacement);
        verifyNoMoreInteractions(events);
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
    }

    @Test public void queuesAreIndependentAndCloseWaitsForInflightOperation() throws Exception {
        UsbHostProxy.Connection first = open();
        UsbDeviceConnection otherNativeConnection = mock(UsbDeviceConnection.class);
        when(manager.openDevice(usb)).thenReturn(otherNativeConnection);
        UsbHostProxy.Connection second = open();
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
        UsbHostProxy.Connection connection = open();
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
        UsbHostProxy.Connection connection = open();
        detachDevice();
        assertFalse(session.hasPermission(device));
        assertThrows(IllegalStateException.class, connection::rawDescriptors);
        sameNameDevice();
        UsbHostProxy.Device replacement = session.deviceList()[0];
        assertNotSame(device, replacement);
        assertNotEquals(internalId(device), internalId(replacement));
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

    @Test public void permissionRepliesMustMatchTheCurrentAttachment() throws Exception {
        LinkedBlockingQueue<PendingIntent> requests = new LinkedBlockingQueue<>();
        doAnswer(call -> { requests.add(call.getArgument(1)); return null; })
            .when(manager).requestPermission(any(UsbDevice.class), any(PendingIntent.class));
        Result oldPermission = new Result();
        session.requestPermission(device, oldPermission);
        PendingIntent oldIntent = requests.poll(10, TimeUnit.SECONDS);
        assertNotNull(oldIntent);
        Intent oldReply = new Intent(shadowOf(oldIntent).getSavedIntent())
            .putExtra(UsbManager.EXTRA_DEVICE, usb)
            .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true);
        assertEquals(internalId(device), oldReply.getStringExtra("deviceInstance"));
        detachDevice();
        assertEquals(false, oldPermission.await().value);

        UsbDevice replacementUsb = sameNameDevice();
        UsbHostProxy.Device replacement = session.deviceList()[0];
        Result permission = new Result();
        session.requestPermission(replacement, permission);
        PendingIntent intent = requests.poll(10, TimeUnit.SECONDS);
        assertNotNull(intent);
        Intent reply = new Intent(shadowOf(intent).getSavedIntent())
            .putExtra(UsbManager.EXTRA_DEVICE, replacementUsb)
            .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true);
        assertEquals(internalId(replacement), reply.getStringExtra("deviceInstance"));
        assertNotEquals(oldReply.getStringExtra("deviceInstance"), reply.getStringExtra("deviceInstance"));
        when(manager.hasPermission(replacementUsb)).thenReturn(true);

        context.sendBroadcast(oldReply);
        context.sendBroadcast(new Intent(reply).putExtra("deviceInstance", internalId(device)));
        shadowOf(Looper.getMainLooper()).idle();
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, usb);
        assertEquals(1, permission.done.getCount());
        assertSame(replacement, session.deviceList()[0]);

        intent.send(context, 0, new Intent()
            .putExtra(UsbManager.EXTRA_DEVICE, replacementUsb)
            .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true));
        shadowOf(Looper.getMainLooper()).idle();
        assertEquals(true, permission.await().value);
        assertEquals(1, oldPermission.completions);
        assertEquals(1, permission.completions);
    }

    @Test public void detachResolvesPermissionFalseAndRejectsLateReply() throws Exception {
        AtomicReference<PendingIntent> intent = new AtomicReference<>();
        CountDownLatch requested = new CountDownLatch(1);
        doAnswer(call -> { intent.set(call.getArgument(1)); requested.countDown(); return null; })
            .when(manager).requestPermission(eq(usb), any(PendingIntent.class));
        Result permission = new Result();
        session.requestPermission(device, permission);
        assertTrue(requested.await(10, TimeUnit.SECONDS));
        // Model a reply already dispatched before cancellation of its PendingIntent.
        Intent lateReply = new Intent(shadowOf(intent.get()).getSavedIntent())
            .putExtra(UsbManager.EXTRA_DEVICE, usb)
            .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true);
        detachDevice();
        assertEquals(false, permission.await().value);
        when(manager.hasPermission(usb)).thenReturn(true);
        context.sendBroadcast(lateReply);
        shadowOf(Looper.getMainLooper()).idle();
        assertEquals(false, permission.value);
        assertNull(permission.error);
        assertEquals(1, permission.completions);
    }

    @Test public void deniedPermissionCompletesFalseWithoutAnError() throws Exception {
        AtomicReference<PendingIntent> intent = new AtomicReference<>();
        CountDownLatch requested = new CountDownLatch(1);
        doAnswer(call -> { intent.set(call.getArgument(1)); requested.countDown(); return null; })
            .when(manager).requestPermission(eq(usb), any(PendingIntent.class));
        Result permission = new Result();
        session.requestPermission(device, permission);
        assertTrue(requested.await(10, TimeUnit.SECONDS));
        intent.get().send(context, 0, new Intent()
            .putExtra(UsbManager.EXTRA_DEVICE, usb)
            .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false));
        shadowOf(Looper.getMainLooper()).idle();
        assertEquals(false, permission.await().value);
        assertNull(permission.error);
        assertEquals(1, permission.completions);
    }

    @Test public void devicesFromAnotherSessionAreRejectedBeforeNativeAccess() throws Exception {
        UsbHostProxy.attach(context, 43);
        try {
            UsbHostProxy.Device foreign = UsbHostProxy.session(43).deviceList()[0];
            assertThrows(IllegalArgumentException.class, () -> session.hasPermission(foreign));
            Result permission = new Result();
            session.requestPermission(foreign, permission);
            assertTrue(permission.await().error instanceof IllegalArgumentException);
            Result opened = new Result();
            session.open(foreign, opened);
            assertTrue(opened.await().error instanceof IllegalArgumentException);
            verify(manager, never()).hasPermission(any(UsbDevice.class));
            verify(manager, never()).requestPermission(any(UsbDevice.class), any(PendingIntent.class));
            verify(manager, never()).openDevice(any(UsbDevice.class));
        } finally { UsbHostProxy.detach(43); }
    }

    @Test public void detachingOneDeviceKeepsTheOtherAttachmentAndConnection() throws Exception {
        UsbHostProxy.Connection first = open();
        UsbDevice otherUsb = mock(UsbDevice.class);
        when(otherUsb.getDeviceName()).thenReturn("/dev/bus/usb/001/003");
        attachedDevices.put(otherUsb.getDeviceName(), otherUsb);
        UsbHostProxy.Device other = null;
        for (UsbHostProxy.Device candidate : session.deviceList()) {
            if (candidate.usbDevice == otherUsb) other = candidate;
        }
        assertNotNull(other);
        assertNotEquals(internalId(device), internalId(other));
        UsbDeviceConnection otherNative = mock(UsbDeviceConnection.class);
        when(manager.openDevice(otherUsb)).thenReturn(otherNative);
        when(otherNative.getFileDescriptor()).thenReturn(23);
        when(manager.hasPermission(otherUsb)).thenReturn(true);
        Result opened = new Result();
        session.open(other, opened);
        assertNull(opened.await().error);
        UsbHostProxy.Connection second = (UsbHostProxy.Connection) opened.value;
        detachDevice();
        assertThrows(IllegalStateException.class, first::fileDescriptor);
        assertSame(other, session.deviceList()[0]);
        assertTrue(session.hasPermission(other));
        assertEquals(23, second.fileDescriptor());
        verify(otherNative, never()).close();
        Result firstClosed = new Result();
        Result secondClosed = new Result();
        first.close(firstClosed);
        second.close(secondClosed);
        assertNull(firstClosed.await().error);
        assertNull(secondClosed.await().error);
        verify(nativeConnection).close();
        verify(otherNative).close();
    }

    @Test public void sessionEndFailsPendingPermissionsAndInvalidatesOldSession() throws Exception {
        Result permission = new Result();
        session.requestPermission(device, permission);
        UsbHostProxy.detach(42);
        assertTrue(permission.await().error instanceof IllegalStateException);
        assertThrows(IllegalStateException.class, session::deviceList);
        UsbHostProxy.attach(context, 42);
        assertNotSame(session, UsbHostProxy.session(42));
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

    @Test public void deviceSerialPreservesValuesErrorsAndRejectsRetiredAttachments() throws Exception {
        SecurityException denial = new SecurityException("serial denied");
        when(usb.getSerialNumber()).thenReturn("device serial").thenReturn(null).thenThrow(denial);
        Result serial = new Result();
        device.serial(serial);
        assertEquals("device serial", serial.await().value);
        assertNull(serial.error);
        Result absent = new Result();
        device.serial(absent);
        assertNull(absent.await().value);
        assertNull(absent.error);
        Result failed = new Result();
        device.serial(failed);
        assertSame(denial, failed.await().error);
        detachDevice();
        Result retired = new Result();
        device.serial(retired);
        assertTrue(retired.await().error instanceof IllegalStateException);
        verify(usb, times(3)).getSerialNumber();
    }

    @Test public void connectionSerialPreservesNativeValuesAndFailures() throws Exception {
        SecurityException denial = new SecurityException("connection serial denied");
        when(nativeConnection.getSerial()).thenReturn("connection serial").thenReturn(null).thenThrow(denial);
        UsbHostProxy.Connection connection = open();
        Result serial = new Result();
        connection.serial(serial);
        assertEquals("connection serial", serial.await().value);
        assertNull(serial.error);
        Result absent = new Result();
        connection.serial(absent);
        assertNull(absent.await().value);
        assertNull(absent.error);
        Result failed = new Result();
        connection.serial(failed);
        assertSame(denial, failed.await().error);
    }

    @Test public void directConnectionInformationPreservesNativeResultsAndRejectsClosedReads() throws Exception {
        byte[] descriptors = new byte[] {0, (byte) 128, (byte) 255};
        IllegalStateException failure = new IllegalStateException("native read failed");
        when(nativeConnection.getFileDescriptor()).thenReturn(23, -1).thenThrow(failure);
        when(nativeConnection.getRawDescriptors()).thenReturn(descriptors).thenReturn(null).thenThrow(failure);
        UsbHostProxy.Connection connection = open();
        assertEquals(23, connection.fileDescriptor());
        assertEquals(-1, connection.fileDescriptor());
        assertSame(failure, assertThrows(IllegalStateException.class, connection::fileDescriptor));
        assertSame(descriptors, connection.rawDescriptors());
        assertNull(connection.rawDescriptors());
        assertSame(failure, assertThrows(IllegalStateException.class, connection::rawDescriptors));
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        assertThrows(IllegalStateException.class, connection::fileDescriptor);
        assertThrows(IllegalStateException.class, connection::rawDescriptors);
        verify(nativeConnection, times(3)).getFileDescriptor();
        verify(nativeConnection, times(3)).getRawDescriptors();
    }

    @Test public void authorizedAndRetiredPermissionRequestsDoNotShowADialog() throws Exception {
        when(manager.hasPermission(usb)).thenReturn(true);
        Result authorized = new Result();
        session.requestPermission(device, authorized);
        assertEquals(true, authorized.await().value);
        assertNull(authorized.error);
        detachDevice();
        Result retired = new Result();
        session.requestPermission(device, retired);
        assertEquals(false, retired.await().value);
        assertNull(retired.error);
        verify(manager, never()).requestPermission(any(UsbDevice.class), any(PendingIntent.class));
    }

    @Test public void permissionSubmissionFailureRemainsAnErrorInsteadOfDenial() throws Exception {
        SecurityException denial = new SecurityException("permission submission failed");
        doThrow(denial).when(manager).requestPermission(eq(usb), any(PendingIntent.class));
        Result permission = new Result();
        session.requestPermission(device, permission);
        assertSame(denial, permission.await().error);
        assertEquals(1, permission.completions);
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
        UsbHostProxy.Connection connection = open();
        Result claim = new Result();
        Result select = new Result();
        Result configuration = new Result();
        Result release = new Result();
        connection.claim(intf, true, claim);
        connection.selectInterface(intf, select);
        connection.release(intf, release);
        connection.selectConfiguration(config, configuration);
        assertEquals(true, claim.await().value);
        assertEquals(true, select.await().value);
        assertEquals(true, configuration.await().value);
        assertEquals(true, release.await().value);
        org.mockito.InOrder order = inOrder(nativeConnection);
        order.verify(nativeConnection).claimInterface(intf, true);
        order.verify(nativeConnection).setInterface(intf);
        order.verify(nativeConnection).releaseInterface(intf);
        order.verify(nativeConnection).setConfiguration(config);
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
        try {
            detachDevice();
            sameNameDevice();
            assertNotEquals(internalId(device), internalId(session.deviceList()[0]));
        }
        finally { unblock.countDown(); }
        assertTrue(opened.await().error instanceof IllegalStateException);
        verify(nativeConnection).close();
    }

    @Test public void failingEventListenerCannotInterruptSessionCleanup() throws Exception {
        UsbHostProxy.Connection connection = open();
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        doThrow(new IllegalStateException("dead isolate")).when(events).disposed();
        session.listen(events);
        UsbHostProxy.detach(42);
        assertThrows(IllegalStateException.class, session::deviceList);
        Result closed = new Result();
        connection.close(closed);
        closed.await();
        verify(nativeConnection).close();
    }

    @Test public void explicitCloseDrainsAlreadyAcceptedOperationsInOrder() throws Exception {
        UsbHostProxy.Connection connection = open();
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

    /** Adds an original descriptor; alternate settings can deliberately share a number. */
    private UsbInterface interfaceAt(int index, int number) {
        UsbInterface intf = mock(UsbInterface.class);
        when(intf.getId()).thenReturn(number);
        when(usb.getInterfaceCount()).thenReturn(index + 1);
        when(usb.getInterface(index)).thenReturn(intf);
        return intf;
    }

    /** Awaits the real backend queue without simulating Android's claim policy. */
    private Result claim(UsbHostProxy.Connection connection, UsbInterface intf) throws Exception {
        Result result = new Result();
        connection.claim(intf, false, result);
        return result.await();
    }

    /** Keeps a native false distinct from an exception delivered by the backend. */
    private Result release(UsbHostProxy.Connection connection, UsbInterface intf) throws Exception {
        Result result = new Result();
        connection.release(intf, result);
        return result.await();
    }

    @Test public void repeatedClaimAndReleaseWithoutClaimPreserveEachNativeResult() throws Exception {
        UsbInterface intf = interfaceAt(0, 7);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(false, true, false, true);
        when(nativeConnection.releaseInterface(intf)).thenReturn(true, false, true, false);
        UsbHostProxy.Connection connection = open();
        // Values are deliberately scripted, not predictions about Android/kernel policy.
        assertEquals(true, release(connection, intf).value);
        assertEquals(false, release(connection, intf).value);
        assertEquals(false, claim(connection, intf).value);
        assertEquals(true, claim(connection, intf).value);
        assertEquals(false, claim(connection, intf).value);
        assertEquals(true, claim(connection, intf).value);
        assertEquals(true, release(connection, intf).value);
        assertEquals(false, release(connection, intf).value);
        verify(nativeConnection, times(4)).claimInterface(intf, false);
        verify(nativeConnection, times(4)).releaseInterface(intf);
    }

    @Test public void setInterfaceWithoutClaimPreservesNativeResults() throws Exception {
        UsbInterface intf = interfaceAt(0, 7);
        when(nativeConnection.setInterface(intf)).thenReturn(false, true);
        UsbHostProxy.Connection connection = open();
        Result select = new Result();
        connection.selectInterface(intf, select);
        assertEquals(false, select.await().value);
        Result again = new Result();
        connection.selectInterface(intf, again);
        assertEquals(true, again.await().value);
        verify(nativeConnection, times(2)).setInterface(intf);
        verify(nativeConnection, never()).claimInterface(any(), anyBoolean());
    }

    @Test public void originalAlternateDescriptorsReachTheirOwnConnectionAndLifecycleStillApplies() throws Exception {
        UsbInterface one = interfaceAt(0, 0);
        UsbInterface alternate = interfaceAt(1, 0);
        UsbInterface two = interfaceAt(2, 1);
        when(nativeConnection.claimInterface(any(), eq(false))).thenReturn(true);
        when(nativeConnection.releaseInterface(any())).thenReturn(true);
        UsbHostProxy.Connection first = open();
        assertEquals(true, claim(first, one).value);
        assertEquals(true, claim(first, alternate).value);
        assertEquals(true, claim(first, two).value);
        // Each wrapper delegates to its own native connection, without shared policy.
        UsbDeviceConnection otherNative = mock(UsbDeviceConnection.class);
        when(otherNative.claimInterface(one, false)).thenReturn(true);
        when(manager.openDevice(usb)).thenReturn(otherNative);
        UsbHostProxy.Connection second = open();
        assertEquals(false, release(second, one).value);
        assertEquals(true, claim(second, one).value);
        assertEquals(true, release(first, alternate).value);
        assertEquals(true, release(first, one).value);
        assertEquals(true, claim(first, two).value);
        verify(nativeConnection).claimInterface(alternate, false);
        verify(nativeConnection).releaseInterface(alternate);
        Result closed = new Result();
        first.close(closed);
        assertNull(closed.await().error);
        verify(nativeConnection).close();
        verify(nativeConnection, never()).releaseInterface(two); // close owns cleanup
        assertTrue(claim(first, one).error instanceof IllegalStateException);
        assertEquals(true, claim(second, one).value);
        detachDevice();
        assertTrue(release(second, one).error instanceof IllegalStateException);
        Result detachedClose = new Result();
        second.close(detachedClose);
        assertNull(detachedClose.await().error);
        verify(otherNative).close();
        verify(otherNative, times(1)).releaseInterface(one);
    }

    @Test public void queuedReleaseDoesNotRejectFollowingOperationsAndFifoOrderingRemains() throws Exception {
        UsbInterface intf = interfaceAt(0, 0);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(true);
        when(nativeConnection.releaseInterface(intf)).thenReturn(true);
        when(nativeConnection.setInterface(intf)).thenReturn(true);
        UsbHostProxy.Connection connection = open();
        assertEquals(true, claim(connection, intf).value);
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.getSerial()).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return "serial";
        });
        Result serial = new Result();
        connection.serial(serial);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        Result before = new Result();
        Result releasing = new Result();
        Result after = new Result();
        Result laterClaim = new Result();
        try {
            connection.selectInterface(intf, before);
            connection.release(intf, releasing);
            connection.selectInterface(intf, after);
            connection.claim(intf, false, laterClaim);
            assertEquals(1, after.done.getCount());
            assertEquals(1, laterClaim.done.getCount());
        } finally { unblock.countDown(); }
        assertNull(serial.await().error);
        assertEquals(true, before.await().value);
        assertEquals(true, releasing.await().value);
        assertEquals(true, after.await().value);
        assertEquals(true, laterClaim.await().value);
        org.mockito.InOrder order = inOrder(nativeConnection);
        order.verify(nativeConnection).claimInterface(intf, false);
        order.verify(nativeConnection).getSerial();
        order.verify(nativeConnection).setInterface(intf);
        order.verify(nativeConnection).releaseInterface(intf);
        order.verify(nativeConnection).setInterface(intf);
        order.verify(nativeConnection).claimInterface(intf, false);
    }

    @Test public void foreignDescriptorsAreRejectedAndAllFourNativeExceptionsArePreserved() throws Exception {
        UsbInterface intf = interfaceAt(0, 0);
        UsbConfiguration config = mock(UsbConfiguration.class);
        when(usb.getConfigurationCount()).thenReturn(1);
        when(usb.getConfiguration(0)).thenReturn(config);
        UsbHostProxy.Connection connection = open();
        UsbInterface foreign = mock(UsbInterface.class);
        assertTrue(claim(connection, foreign).error instanceof IllegalArgumentException);
        assertTrue(release(connection, foreign).error instanceof IllegalArgumentException);
        Result foreignSetting = new Result();
        connection.selectInterface(foreign, foreignSetting);
        assertTrue(foreignSetting.await().error instanceof IllegalArgumentException);
        Result foreignConfiguration = new Result();
        connection.selectConfiguration(mock(UsbConfiguration.class), foreignConfiguration);
        assertTrue(foreignConfiguration.await().error instanceof IllegalArgumentException);
        verifyNoInteractions(nativeConnection);

        SecurityException claimError = new SecurityException("native claim failed");
        SecurityException releaseError = new SecurityException("native release failed");
        IllegalStateException settingError = new IllegalStateException("native setting failed");
        IllegalArgumentException configError = new IllegalArgumentException("native configuration failed");
        when(nativeConnection.claimInterface(intf, false)).thenThrow(claimError);
        when(nativeConnection.releaseInterface(intf)).thenThrow(releaseError);
        when(nativeConnection.setInterface(intf)).thenThrow(settingError);
        when(nativeConnection.setConfiguration(config)).thenThrow(configError);
        assertSame(claimError, claim(connection, intf).error);
        assertSame(releaseError, release(connection, intf).error);
        Result setting = new Result();
        connection.selectInterface(intf, setting);
        assertSame(settingError, setting.await().error);
        Result configuration = new Result();
        connection.selectConfiguration(config, configuration);
        assertSame(configError, configuration.await().error);
        verify(nativeConnection).claimInterface(intf, false);
        verify(nativeConnection).releaseInterface(intf);
        verify(nativeConnection).setInterface(intf);
        verify(nativeConnection).setConfiguration(config);
        // A failed call does not install any policy preventing a later native retry.
        doReturn(true).when(nativeConnection).releaseInterface(intf);
        assertEquals(true, release(connection, intf).value);
    }

    @Test public void configurationIsForwardedRegardlessOfPriorClaimReleaseResults() throws Exception {
        UsbInterface intf = interfaceAt(0, 0);
        UsbConfiguration config = mock(UsbConfiguration.class);
        when(usb.getConfigurationCount()).thenReturn(1);
        when(usb.getConfiguration(0)).thenReturn(config);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(false, true);
        when(nativeConnection.setConfiguration(config)).thenReturn(false, true, false, true);
        UsbHostProxy.Connection connection = open();
        Result invalid = new Result();
        connection.selectConfiguration(mock(UsbConfiguration.class), invalid);
        assertTrue(invalid.await().error instanceof IllegalArgumentException);
        Result failed = new Result();
        connection.selectConfiguration(config, failed);
        assertEquals(false, failed.await().value);
        assertEquals(false, claim(connection, intf).value);
        Result success = new Result();
        connection.selectConfiguration(config, success);
        assertEquals(true, success.await().value);
        assertEquals(false, release(connection, intf).value);
        Result afterRelease = new Result();
        connection.selectConfiguration(config, afterRelease);
        assertEquals(false, afterRelease.await().value);
        assertEquals(true, claim(connection, intf).value);
        Result afterClaim = new Result();
        connection.selectConfiguration(config, afterClaim);
        assertEquals(true, afterClaim.await().value);
        verify(nativeConnection, times(4)).setConfiguration(config);
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        assertTrue(release(connection, intf).error instanceof IllegalStateException);
        verify(nativeConnection, times(1)).releaseInterface(intf);
    }

    @Test public void closeWithClaimsRejectsNewInterfaceWorkAndNeverCallsReleaseEvenOnCloseError() throws Exception {
        UsbInterface intf = interfaceAt(0, 0);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(true);
        UsbHostProxy.Connection connection = open();
        assertEquals(true, claim(connection, intf).value);
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.getSerial()).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return "serial";
        });
        Result serial = new Result();
        connection.serial(serial);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        RuntimeException error = new RuntimeException("native close failure");
        doThrow(error).when(nativeConnection).close();
        Result closing = new Result();
        try {
            connection.close(closing);
            assertTrue(claim(connection, intf).error instanceof IllegalStateException);
            assertTrue(release(connection, intf).error instanceof IllegalStateException);
            Result selected = new Result();
            connection.selectInterface(intf, selected);
            assertTrue(selected.await().error instanceof IllegalStateException);
        } finally { unblock.countDown(); }
        assertNull(serial.await().error);
        assertSame(error, closing.await().error);
        Result again = new Result();
        connection.close(again);
        assertNull(again.await().error);
        assertTrue(release(connection, intf).error instanceof IllegalStateException);
        verify(nativeConnection, times(1)).close();
        verify(nativeConnection, never()).releaseInterface(any());
    }

    @Test public void detachDiscardsQueuedReleaseWithoutCallingNativeRelease() throws Exception {
        UsbInterface intf = interfaceAt(0, 0);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(true);
        UsbHostProxy.Connection connection = open();
        assertEquals(true, claim(connection, intf).value);
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(nativeConnection.getSerial()).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return "serial";
        });
        Result serial = new Result();
        connection.serial(serial);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        Result queuedRelease = new Result();
        try {
            connection.release(intf, queuedRelease);
            detachDevice();
            assertTrue(claim(connection, intf).error instanceof IllegalStateException);
        } finally { unblock.countDown(); }
        assertNull(serial.await().error);
        assertTrue(queuedRelease.await().error instanceof IllegalStateException);
        assertNull(queuedRelease.value); // Not a native false result.
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        verify(nativeConnection).close();
        verify(nativeConnection, never()).releaseInterface(any());
    }
}
