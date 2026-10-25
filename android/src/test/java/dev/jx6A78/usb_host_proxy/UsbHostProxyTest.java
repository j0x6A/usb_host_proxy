package dev.jx6A78.usb_host_proxy;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.robolectric.Shadows.shadowOf;
import static org.robolectric.util.ReflectionHelpers.getField;

import android.app.PendingIntent;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbConfiguration;
import android.hardware.usb.UsbManager;
import android.os.Looper;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLog;

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
    /** Initial framework view; retained to check that detach permanently invalidates it. */
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

    /** Replaces the discovery object only; this alone is not proof of reattachment. */
    private UsbDevice sameNameDevice() {
        UsbDevice replacement = mock(UsbDevice.class);
        String name = usb.getDeviceName();
        when(replacement.getDeviceName()).thenReturn(name);
        attachedDevices.put(replacement.getDeviceName(), replacement);
        return replacement;
    }

    /** Checks that an inert view retains no framework object, independently of getter errors. */
    private static Object storedDescriptor(Object view) {
        try {
            Field reference = view.getClass().getDeclaredField("nativeDescriptor");
            reference.setAccessible(true);
            Object holder = reference.get(view);
            Field value = holder.getClass().getDeclaredField("value");
            value.setAccessible(true);
            return value.get(holder);
        } catch (ReflectiveOperationException error) { throw new AssertionError(error); }
    }

    /** Creates JNI argument fixtures without adding descriptors to the discovery tree.
     * Reflection is test-only; production creates these views in descriptor getters.
     */
    private <T> T view(Class<T> type, Class<?> descriptorType, Object descriptor) {
        try {
            Constructor<T> constructor = type.getDeclaredConstructor(
                UsbHostProxy.Session.class, UsbHostProxy.Lifetime.class, descriptorType);
            constructor.setAccessible(true);
            return constructor.newInstance(session, device.lifetime, descriptor);
        } catch (ReflectiveOperationException error) { throw new AssertionError(error); }
    }

    private UsbHostProxy.Interface interfaceView(UsbInterface descriptor) {
        return view(UsbHostProxy.Interface.class, UsbInterface.class, descriptor);
    }

    private UsbHostProxy.Configuration configurationView(UsbConfiguration descriptor) {
        return view(UsbHostProxy.Configuration.class, UsbConfiguration.class, descriptor);
    }

    /** One original framework tree, exposed through both flattened and nested paths. */
    private UsbConfiguration descriptorTree() {
        UsbConfiguration configuration = mock(UsbConfiguration.class);
        UsbInterface intf = mock(UsbInterface.class);
        UsbEndpoint endpoint = mock(UsbEndpoint.class);
        when(usb.getConfigurationCount()).thenReturn(1);
        when(usb.getConfiguration(0)).thenReturn(configuration);
        when(usb.getInterfaceCount()).thenReturn(1);
        when(usb.getInterface(0)).thenReturn(intf);
        when(configuration.getInterfaceCount()).thenReturn(1);
        when(configuration.getInterface(0)).thenReturn(intf);
        when(intf.getEndpointCount()).thenReturn(1);
        when(intf.getEndpoint(0)).thenReturn(endpoint);
        return configuration;
    }

    @Test public void javaViewsForwardDescriptorValuesAndOriginalFailures() {
        UsbConfiguration configuration = descriptorTree();
        UsbInterface intf = configuration.getInterface(0);
        UsbEndpoint endpoint = intf.getEndpoint(0);
        when(usb.getDeviceId()).thenReturn(21);
        when(usb.getVendorId()).thenReturn(22);
        when(usb.getProductId()).thenReturn(23);
        when(usb.getDeviceClass()).thenReturn(24);
        when(usb.getDeviceSubclass()).thenReturn(25);
        when(usb.getDeviceProtocol()).thenReturn(26);
        when(usb.getManufacturerName()).thenReturn("manufacturer");
        when(usb.getProductName()).thenReturn("product");
        when(usb.getVersion()).thenReturn("1.2");
        when(configuration.getId()).thenReturn(31);
        when(configuration.getName()).thenReturn("configuration");
        when(configuration.getMaxPower()).thenReturn(100);
        when(configuration.isRemoteWakeup()).thenReturn(true);
        when(configuration.isSelfPowered()).thenReturn(true);
        when(intf.getId()).thenReturn(41);
        when(intf.getAlternateSetting()).thenReturn(42);
        when(intf.getName()).thenReturn("interface");
        when(intf.getInterfaceClass()).thenReturn(43);
        when(intf.getInterfaceSubclass()).thenReturn(44);
        when(intf.getInterfaceProtocol()).thenReturn(45);
        when(endpoint.getAddress()).thenReturn(51);
        when(endpoint.getAttributes()).thenReturn(52);
        when(endpoint.getDirection()).thenReturn(53);
        when(endpoint.getEndpointNumber()).thenReturn(54);
        when(endpoint.getInterval()).thenReturn(55);
        when(endpoint.getMaxPacketSize()).thenReturn(56);
        when(endpoint.getType()).thenReturn(57);
        UsbHostProxy.Configuration c = device.getConfiguration(0);
        UsbHostProxy.Interface i = c.getInterface(0);
        UsbHostProxy.Endpoint e = i.getEndpoint(0);
        assertSame(configuration, storedDescriptor(c));
        assertSame(intf, storedDescriptor(i));
        assertSame(endpoint, storedDescriptor(e));
        assertEquals(21, device.getDeviceId());
        assertEquals(22, device.getVendorId());
        assertEquals(23, device.getProductId());
        assertEquals(24, device.getDeviceClass());
        assertEquals(25, device.getDeviceSubclass());
        assertEquals(26, device.getDeviceProtocol());
        assertEquals("manufacturer", device.getManufacturerName());
        assertEquals("product", device.getProductName());
        assertEquals("1.2", device.getVersion());
        assertEquals(1, device.getConfigurationCount());
        assertEquals(1, device.getInterfaceCount());
        assertEquals(31, c.getId());
        assertEquals("configuration", c.getName());
        assertEquals(100, c.getMaxPower());
        assertTrue(c.isRemoteWakeup());
        assertTrue(c.isSelfPowered());
        assertEquals(1, c.getInterfaceCount());
        assertEquals(41, i.getId());
        assertEquals(42, i.getAlternateSetting());
        assertEquals("interface", i.getName());
        assertEquals(43, i.getInterfaceClass());
        assertEquals(44, i.getInterfaceSubclass());
        assertEquals(45, i.getInterfaceProtocol());
        assertEquals(1, i.getEndpointCount());
        assertEquals(51, e.getAddress());
        assertEquals(52, e.getAttributes());
        assertEquals(53, e.getDirection());
        assertEquals(54, e.getEndpointNumber());
        assertEquals(55, e.getInterval());
        assertEquals(56, e.getMaxPacketSize());
        assertEquals(57, e.getType());
        SecurityException denied = new SecurityException("descriptor denied");
        when(configuration.getName()).thenThrow(denied);
        assertSame(denied, assertThrows(SecurityException.class, c::getName));
    }

    @Test public void detachInvalidatesEveryGetterAndClearsNestedAndFlattenedDescriptors() {
        UsbConfiguration configuration = descriptorTree();
        UsbInterface intf = configuration.getInterface(0);
        UsbEndpoint endpoint = intf.getEndpoint(0);
        UsbHostProxy.Configuration c = device.getConfiguration(0);
        UsbHostProxy.Interface i = c.getInterface(0);
        UsbHostProxy.Interface flattened = device.getInterface(0);
        UsbHostProxy.Endpoint e = i.getEndpoint(0);
        UsbHostProxy.Endpoint flattenedEndpoint = flattened.getEndpoint(0);
        String name = device.getDeviceName();
        int hash = device.hashCode();
        detachDevice(); // No Dart or Java event subscriber is required for cleanup.
        for (Object view : new Object[] {device, c, i, flattened, e, flattenedEndpoint}) {
            assertNull(storedDescriptor(view));
        }
        clearInvocations(usb, configuration, intf, endpoint);
        Runnable[] reads = {
            device::getDeviceId, device::getDeviceClass, device::getDeviceSubclass,
            device::getDeviceProtocol, device::getVendorId, device::getProductId,
            device::getManufacturerName, device::getProductName, device::getVersion,
            device::getConfigurationCount, device::getInterfaceCount,
            () -> device.getConfiguration(0), () -> device.getInterface(0),
            c::getId, c::getName, c::getMaxPower, c::isRemoteWakeup, c::isSelfPowered,
            c::getInterfaceCount, () -> c.getInterface(0),
            i::getId, i::getAlternateSetting, i::getName, i::getInterfaceClass,
            i::getInterfaceSubclass, i::getInterfaceProtocol, i::getEndpointCount,
            () -> i.getEndpoint(0), flattened::getId, flattenedEndpoint::getAddress,
            e::getAddress, e::getAttributes, e::getDirection, e::getEndpointNumber,
            e::getInterval, e::getMaxPacketSize, e::getType
        };
        for (Runnable read : reads) assertThrows(IllegalStateException.class, read::run);
        assertEquals(name, device.getDeviceName());
        assertEquals(hash, device.hashCode());
        verifyNoInteractions(usb, configuration, intf, endpoint);
        sameNameDevice();
        UsbHostProxy.Device current = session.deviceList()[0];
        assertEquals(device, current);
        assertEquals(hash, current.hashCode());
        for (Runnable read : reads) assertThrows(IllegalStateException.class, read::run);
    }

    @Test public void absenceAndSessionEndClearAllChildViews() {
        descriptorTree();
        UsbHostProxy.Configuration c = device.getConfiguration(0);
        UsbHostProxy.Interface i = c.getInterface(0);
        UsbHostProxy.Endpoint e = i.getEndpoint(0);
        attachedDevices.clear();
        assertEquals(0, session.deviceList().length);
        for (Object view : new Object[] {device, c, i, e}) assertNull(storedDescriptor(view));
        attachedDevices.put(usb.getDeviceName(), usb);
        UsbHostProxy.Device current = session.deviceList()[0];
        UsbHostProxy.Interface currentInterface = current.getInterface(0);
        UsbHostProxy.Endpoint currentEndpoint = currentInterface.getEndpoint(0);
        UsbHostProxy.detach(42);
        for (Object view : new Object[] {current, currentInterface, currentEndpoint}) {
            assertNull(storedDescriptor(view));
        }
        assertThrows(IllegalStateException.class, currentInterface::getId);
        assertThrows(IllegalStateException.class, currentEndpoint::getAddress);
    }

    @Test public void childReturningFromAnAdmittedGetterAfterDetachRetainsNoFrameworkDescriptor() {
        UsbConfiguration configuration = mock(UsbConfiguration.class);
        when(usb.getConfiguration(0)).thenAnswer(call -> {
            detachDevice();
            return configuration;
        });
        UsbHostProxy.Configuration late = device.getConfiguration(0);
        assertNull(storedDescriptor(late));
        assertThrows(IllegalStateException.class, late::getId);
        verifyNoInteractions(configuration);
    }

    @Test public void proxyCallsCanBeSequencedByAwaitingResultsAndKeepNativeArguments() throws Exception {
        UsbConfiguration configuration = descriptorTree();
        UsbInterface intf = configuration.getInterface(0);
        UsbHostProxy.Interface i = device.getInterface(0);
        UsbHostProxy.Configuration c = device.getConfiguration(0);
        UsbHostProxy.Connection connection = open();
        when(nativeConnection.claimInterface(intf, true)).thenReturn(false, true);
        when(nativeConnection.releaseInterface(intf)).thenReturn(false, true);
        when(nativeConnection.setInterface(intf)).thenReturn(true);
        when(nativeConnection.setConfiguration(configuration)).thenReturn(false);
        Result first = new Result();
        connection.claimInterface(i, true, first);
        assertEquals(false, first.await().value);
        Result second = new Result();
        connection.claimInterface(i, true, second);
        assertEquals(true, second.await().value);
        Result setting = new Result();
        connection.setInterface(i, setting);
        assertEquals(true, setting.await().value);
        Result release = new Result();
        connection.releaseInterface(i, release);
        assertEquals(false, release.await().value);
        Result retry = new Result();
        connection.releaseInterface(i, retry);
        assertEquals(true, retry.await().value);
        Result config = new Result();
        connection.setConfiguration(c, config);
        assertEquals(false, config.await().value);
        org.mockito.InOrder order = inOrder(nativeConnection);
        order.verify(nativeConnection, times(2)).claimInterface(intf, true);
        order.verify(nativeConnection).setInterface(intf);
        order.verify(nativeConnection, times(2)).releaseInterface(intf);
        order.verify(nativeConnection).setConfiguration(configuration);
        detachDevice();
        assertThrows(IllegalStateException.class, () -> connection.claimInterface(i, true, new Result()));
        assertThrows(IllegalStateException.class, () -> connection.releaseInterface(i, new Result()));
        assertThrows(IllegalStateException.class, () -> connection.setInterface(i, new Result()));
        assertThrows(IllegalStateException.class, () -> connection.setConfiguration(c, new Result()));
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        verify(nativeConnection).close();
    }

    @Test public void javaAdmitsDelayedEventsWithoutLettingOldDetachAffectAnExposedReplacement() throws Exception {
        detachDevice();
        assertSame(device, session.eventDevice(device, true));
        assertNull(session.eventDevice(device, false));
        UsbDevice replacement = sameNameDevice();
        AtomicReference<UsbHostProxy.Device> delivered = new AtomicReference<>();
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        doAnswer(call -> { delivered.set(call.getArgument(0)); return null; }).when(events).attached(any());
        session.listen(events);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, replacement);
        UsbHostProxy.Device current = delivered.get();
        assertNotNull(current);
        assertSame(device, session.eventDevice(device, true)); // The replacement has not reached Dart.
        assertSame(current, session.eventDevice(current, false));
        assertNull(session.eventDevice(device, true));
        UsbDeviceConnection replacementNative = mock(UsbDeviceConnection.class);
        when(manager.openDevice(replacement)).thenReturn(replacementNative);
        Result opened = new Result();
        session.open(current, opened);
        assertNull(opened.await().error);
        UsbHostProxy.Connection connection = (UsbHostProxy.Connection) opened.value;
        assertNull(session.eventDevice(device, true));
        connection.checkResult();
        connection.fileDescriptor();
        verify(replacementNative, never()).close();
        attachedDevices.clear();
        session.deviceList();
        assertThrows(IllegalStateException.class, connection::checkResult);
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        assertNull(storedDescriptor(current));
        assertNull(session.eventDevice(current, false));
    }

    @Test public void enumerationExposureAlsoSuppressesAnOldQueuedDetachInJava() {
        detachDevice();
        sameNameDevice();
        UsbHostProxy.Device current = session.deviceList()[0];
        assertNull(session.eventDevice(device, true));
        assertSame(current, session.eventDevice(current, false));
        UsbHostProxy.detach(42);
        assertNull(session.eventDevice(current, true));
    }

    @Test public void completedResultsKeepTheirMeaningWhenCallbackDeliveryIsDelayed() throws Exception {
        UsbHostProxy.Connection connection = open();
        UsbInterface intf = mock(UsbInterface.class);
        LinkedBlockingQueue<Runnable> delivery = new LinkedBlockingQueue<>();
        Result result = new Result();
        UsbHostProxy.Completion delayed = new UsbHostProxy.Completion() {
            @Override public void success(Object value) { delivery.add(() -> result.success(value)); }
            @Override public void failure(Throwable error) { delivery.add(() -> result.failure(error)); }
        };
        connection.claimInterface(interfaceView(intf), false, delayed); // Default mock result is false, not an exception.
        Runnable callback = delivery.poll(10, TimeUnit.SECONDS);
        assertNotNull(callback);
        detachDevice();
        callback.run();
        assertEquals(false, result.await().value);
        assertNull(result.error);
        assertThrows(IllegalStateException.class, connection::checkResult);
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        verify(nativeConnection, times(1)).close();
    }

    @Test public void proxyViewsValidateTheirOwnLifetimeWithoutAddingDeviceIdentityRules() throws Exception {
        UsbDevice otherUsb = mock(UsbDevice.class);
        when(otherUsb.getDeviceName()).thenReturn("/dev/bus/usb/001/003");
        UsbInterface otherInterface = mock(UsbInterface.class);
        when(otherUsb.getInterface(0)).thenReturn(otherInterface);
        attachedDevices.put(otherUsb.getDeviceName(), otherUsb);
        UsbHostProxy.Device other = null;
        for (UsbHostProxy.Device candidate : session.deviceList()) {
            if (candidate.descriptor() == otherUsb) other = candidate;
        }
        assertNotNull(other);
        UsbHostProxy.Interface argument = other.getInterface(0);
        UsbHostProxy.Connection connection = open();
        when(nativeConnection.claimInterface(otherInterface, false)).thenReturn(true);
        Result claimed = new Result();
        connection.claimInterface(argument, false, claimed);
        assertEquals(true, claimed.await().value);
        attachedDevices.remove(otherUsb.getDeviceName());
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, otherUsb);
        assertNull(storedDescriptor(argument));
        assertThrows(IllegalStateException.class, () -> connection.releaseInterface(argument, new Result()));
        connection.fileDescriptor(); // The connection's own device remains present.
        verify(nativeConnection, never()).releaseInterface(any());
        verify(nativeConnection, never()).close();
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
    }

    @Test public void descriptorResolutionRemainsBeforeWorkerDispatch() throws Exception {
        UsbDevice otherUsb = mock(UsbDevice.class);
        when(otherUsb.getDeviceName()).thenReturn("/dev/bus/usb/001/003");
        UsbInterface rawInterface = mock(UsbInterface.class);
        when(otherUsb.getInterface(0)).thenReturn(rawInterface);
        attachedDevices.put(otherUsb.getDeviceName(), otherUsb);
        UsbHostProxy.Interface argument = null;
        for (UsbHostProxy.Device candidate : session.deviceList()) {
            if (candidate.descriptor() == otherUsb) argument = candidate.getInterface(0);
        }
        assertNotNull(argument);
        UsbHostProxy.Connection connection = open();
        LinkedBlockingQueue<Runnable> workers = holdWorkers();
        when(nativeConnection.claimInterface(rawInterface, false)).thenReturn(true);
        Result claimed = new Result();
        connection.claimInterface(argument, false, claimed);
        attachedDevices.remove(otherUsb.getDeviceName());
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, otherUsb);
        assertThrows(IllegalStateException.class, argument::getId);
        workers.remove().run();
        // The argument was already resolved; the connection's own device is live.
        assertEquals(true, claimed.await().value);
        verify(nativeConnection).claimInterface(rawInterface, false);
        Result closed = new Result();
        connection.close(closed);
        workers.remove().run();
        assertNull(closed.await().error);
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
        assertSame(usb, device.descriptor());
        verifyNoInteractions(events);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        assertSame(usb, session.deviceList()[0].descriptor());
        verify(events).attached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void enumerationRefreshesNativeViewsWithoutInventingAnAttachment() throws Exception {
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        UsbHostProxy.Connection connection = open();
        when(nativeConnection.getFileDescriptor()).thenReturn(23);
        UsbDevice snapshot = sameNameDevice();
        assertNotSame(usb, snapshot);
        UsbHostProxy.Device refreshed = session.deviceList()[0];
        assertSame(snapshot, refreshed.descriptor());
        assertSame(usb, device.descriptor()); // Older views are not mutated behind the caller.
        verifyNoInteractions(events);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, snapshot);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        assertSame(snapshot, session.deviceList()[0].descriptor());
        assertEquals(23, connection.fileDescriptor());
        verify(nativeConnection, never()).close();
        verify(events).attached(refreshed);
        verifyNoMoreInteractions(events);
    }

    @Test public void detachClearsEverySnapshotBeforeNotifyingAndKeepsOnlyNameAndHash() {
        UsbDevice snapshot = sameNameDevice();
        UsbHostProxy.Device refreshed = session.deviceList()[0];
        assertSame(device.lifetime, refreshed.lifetime);
        assertSame(usb, device.descriptor());
        assertSame(snapshot, refreshed.descriptor());
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        doAnswer(call -> {
            assertFalse(device.lifetime.isAlive());
            assertNull(storedDescriptor(device));
            assertNull(storedDescriptor(refreshed));
            assertThrows(IllegalStateException.class, device::descriptor);
            assertThrows(IllegalStateException.class, refreshed::descriptor);
            return null;
        }).when(events).detached(refreshed);
        session.listen(events);
        detachDevice();
        verify(events).detached(refreshed);
        assertEquals(usb.getDeviceName(), device.lifetime.name);
        assertEquals(usb.getDeviceName().hashCode(), device.lifetime.deviceHash);
        assertEquals(0, session.deviceList().length);
        attachedDevices.put(usb.getDeviceName(), usb);
        UsbHostProxy.Device replacement = session.deviceList()[0];
        assertNotSame(device.lifetime, replacement.lifetime);
        assertTrue(replacement.lifetime.isAlive());
        assertEquals(device.lifetime.name, replacement.lifetime.name);
        assertEquals(device.lifetime.deviceHash, replacement.lifetime.deviceHash);
        assertThrows(IllegalStateException.class, device::descriptor);
    }

    @Test public void absenceAndSessionShutdownInvalidateViewsWithoutAnEventListener() {
        sameNameDevice();
        UsbHostProxy.Device refreshed = session.deviceList()[0];
        attachedDevices.clear();
        assertEquals(0, session.deviceList().length);
        assertFalse(device.lifetime.isAlive());
        assertNull(storedDescriptor(device));
        assertNull(storedDescriptor(refreshed));
        sameNameDevice();
        UsbHostProxy.Device replacement = session.deviceList()[0];
        UsbHostProxy.detach(42);
        assertFalse(replacement.lifetime.isAlive());
        assertNull(storedDescriptor(replacement));
        assertThrows(IllegalStateException.class, replacement::descriptor);
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
        assertEquals(device.lifetime.name, replacement.lifetime.name);
        assertNotSame(device.lifetime, replacement.lifetime);
        verifyNoMoreInteractions(events);
    }

    @Test public void obsoleteAttachUsesObservedAbsenceInsteadOfCreatingAnAttachment() {
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        attachedDevices.clear();
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, usb);
        assertEquals(0, session.deviceList().length);
        assertThrows(IllegalStateException.class, () -> session.hasPermission(device));
        verify(events).detached(device);
        verifyNoMoreInteractions(events);
    }

    @Test public void detachClosesTheNameEvenWhenTheLiveListAlreadyContainsItsReplacement() throws Exception {
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        UsbHostProxy.Connection previous = open();
        UsbDevice replacementUsb = sameNameDevice();
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, usb);
        broadcast(UsbManager.ACTION_USB_DEVICE_DETACHED, usb);
        assertThrows(IllegalStateException.class, previous::fileDescriptor);
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, replacementUsb);
        UsbHostProxy.Device replacement = session.deviceList()[0];
        assertSame(replacementUsb, replacement.descriptor());
        UsbDeviceConnection replacementNative = mock(UsbDeviceConnection.class);
        when(manager.openDevice(replacementUsb)).thenReturn(replacementNative);
        when(replacementNative.getFileDescriptor()).thenReturn(23);
        Result opened = new Result();
        session.open(replacement, opened);
        assertNull(opened.await().error);
        UsbHostProxy.Connection connection = (UsbHostProxy.Connection) opened.value;
        broadcast(UsbManager.ACTION_USB_DEVICE_ATTACHED, replacementUsb);
        assertSame(replacement, session.deviceList()[0]);
        assertEquals(23, connection.fileDescriptor());
        verify(replacementNative, never()).close();
        verify(events).detached(device);
        verify(events).attached(replacement);
        verifyNoMoreInteractions(events);
        Result previousClosed = new Result();
        previous.close(previousClosed);
        assertNull(previousClosed.await().error);
        verify(nativeConnection).close();
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
    }

    @Test public void sharedWorkersKeepConnectionsIndependentAndCloseWaitsForNativeUse() throws Exception {
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

    @Test public void olderDeviceViewAndConnectionStayInvalidAfterReattach() throws Exception {
        UsbHostProxy.Connection connection = open();
        detachDevice();
        assertThrows(IllegalStateException.class, () -> session.hasPermission(device));
        assertThrows(IllegalStateException.class, connection::rawDescriptors);
        sameNameDevice();
        UsbHostProxy.Device replacement = session.deviceList()[0];
        assertNotSame(device, replacement);
        UsbDeviceConnection reopened = mock(UsbDeviceConnection.class);
        when(manager.openDevice(replacement.descriptor())).thenReturn(reopened);
        when(manager.hasPermission(replacement.descriptor())).thenReturn(true);
        when(reopened.getFileDescriptor()).thenReturn(24);
        assertThrows(IllegalStateException.class, () -> session.hasPermission(device));
        Result stale = new Result();
        session.open(device, stale);
        assertTrue(stale.await().error instanceof IllegalStateException);
        assertTrue(session.hasPermission(replacement));
        Result opened = new Result();
        session.open(replacement, opened);
        assertNull(opened.await().error);
        UsbHostProxy.Connection current = (UsbHostProxy.Connection) opened.value;
        assertEquals(24, current.fileDescriptor());
        assertThrows(IllegalStateException.class, connection::fileDescriptor);
        verify(manager, times(1)).openDevice(usb);
        verify(manager).openDevice(replacement.descriptor());
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
        sameNameDevice();
        UsbHostProxy.Device refreshed = session.deviceList()[0];
        assertNotSame(device, refreshed);
        session.requestPermission(refreshed, two);
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

    @Test public void permissionRepliesUseDistinctRequestsWithoutDeviceInstanceTokens() throws Exception {
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
        assertFalse(oldReply.hasExtra("deviceInstance"));
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
        assertFalse(reply.hasExtra("deviceInstance"));
        assertNotEquals(oldReply.getIntExtra("request", -1), reply.getIntExtra("request", -1));
        when(manager.hasPermission(replacementUsb)).thenReturn(true);

        context.sendBroadcast(oldReply);
        shadowOf(Looper.getMainLooper()).idle();
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
            if (candidate.descriptor() == otherUsb) other = candidate;
        }
        assertNotNull(other);
        assertNotEquals(device.descriptor().getDeviceName(), other.descriptor().getDeviceName());
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

    @Test public void deviceSerialPreservesNativeResultsButRejectsDetachAndEndedSessions() throws Exception {
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
        doReturn("native after detach").when(usb).getSerialNumber();
        Result detached = new Result();
        device.serial(detached);
        assertTrue(detached.await().error instanceof IllegalStateException);
        verify(usb, times(3)).getSerialNumber();
        UsbHostProxy.detach(42);
        Result ended = new Result();
        device.serial(ended);
        assertTrue(ended.await().error instanceof IllegalStateException);
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

    @Test public void closeWaitsForDirectFileDescriptorReadAndRejectsLaterReads() throws Exception {
        assertCloseWaitsForDirectRead(false);
    }

    @Test public void closeWaitsForDirectRawDescriptorReadAndRejectsLaterReads() throws Exception {
        assertCloseWaitsForDirectRead(true);
    }

    /** Exercises both direct JNI entry points with the native read held across close. */
    private void assertCloseWaitsForDirectRead(boolean raw) throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        AtomicBoolean nativeInUse = new AtomicBoolean();
        Object expected = raw ? new byte[] {0, (byte) 255} : Integer.valueOf(23);
        org.mockito.stubbing.Answer<Object> read = call -> {
            nativeInUse.set(true);
            entered.countDown();
            try {
                assertTrue(unblock.await(10, TimeUnit.SECONDS));
                return expected;
            } finally { nativeInUse.set(false); }
        };
        if (raw) when(nativeConnection.getRawDescriptors()).thenAnswer(read);
        else when(nativeConnection.getFileDescriptor()).thenAnswer(read);
        doAnswer(call -> { assertFalse(nativeInUse.get()); return null; })
            .when(nativeConnection).close();
        UsbHostProxy.Connection connection = open();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread reader = new Thread(() -> {
            try {
                if (raw) assertSame(expected, connection.rawDescriptors());
                else assertEquals(23, connection.fileDescriptor());
            } catch (Throwable error) { failure.set(error); }
        });
        Result closed = new Result();
        reader.start();
        try {
            assertTrue(entered.await(10, TimeUnit.SECONDS));
            connection.close(closed);
            assertEquals(1, closed.done.getCount());
            verify(nativeConnection, never()).close();
            assertThrows(IllegalStateException.class, connection::fileDescriptor);
            assertThrows(IllegalStateException.class, connection::rawDescriptors);
        } finally {
            unblock.countDown();
            reader.join(10_000);
        }
        assertFalse(reader.isAlive());
        assertNull(failure.get());
        assertNull(closed.await().error);
        verify(nativeConnection, times(1)).close();
    }

    @Test public void authorizedDeviceViewsAreRejectedAfterDetachWithoutAnExtraDialog() throws Exception {
        when(manager.hasPermission(usb)).thenReturn(true);
        Result authorized = new Result();
        session.requestPermission(device, authorized);
        assertEquals(true, authorized.await().value);
        assertNull(authorized.error);
        detachDevice();
        Result detached = new Result();
        session.requestPermission(device, detached);
        assertTrue(detached.await().error instanceof IllegalStateException);
        verify(manager, times(1)).hasPermission(usb);
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

    @Test public void interfacesAndConfigurationForwardOriginalObjectsWithoutDescriptorScanning() throws Exception {
        UsbInterface intf = mock(UsbInterface.class);
        UsbConfiguration config = mock(UsbConfiguration.class);
        when(nativeConnection.claimInterface(intf, true)).thenReturn(true);
        when(nativeConnection.releaseInterface(intf)).thenReturn(true);
        when(nativeConnection.setInterface(intf)).thenReturn(true);
        when(nativeConnection.setConfiguration(config)).thenReturn(true);
        UsbHostProxy.Connection connection = open();
        Result claim = new Result();
        Result select = new Result();
        Result configuration = new Result();
        Result release = new Result();
        connection.claimInterface(interfaceView(intf), true, claim);
        connection.setInterface(interfaceView(intf), select);
        connection.releaseInterface(interfaceView(intf), release);
        connection.setConfiguration(configurationView(config), configuration);
        assertEquals(true, claim.await().value);
        assertEquals(true, select.await().value);
        assertEquals(true, configuration.await().value);
        assertEquals(true, release.await().value);
        verify(nativeConnection).claimInterface(intf, true);
        verify(nativeConnection).setInterface(intf);
        verify(nativeConnection).releaseInterface(intf);
        verify(nativeConnection).setConfiguration(config);
        verify(usb, never()).getInterfaceCount();
        verify(usb, never()).getInterface(anyInt());
        verify(usb, never()).getConfigurationCount();
        verify(usb, never()).getConfiguration(anyInt());
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
            assertNotSame(device.lifetime, session.deviceList()[0].lifetime);
        }
        finally { unblock.countDown(); }
        assertTrue(opened.await().error instanceof IllegalStateException);
        verify(nativeConnection).close();
    }

    @Test public void invalidatedOpenReportsNativeCleanupFailureWithoutPublishingAConnection() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        when(manager.openDevice(usb)).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return nativeConnection;
        });
        RuntimeException failure = new RuntimeException("late open close failed");
        doThrow(failure).when(nativeConnection).close();
        Result opened = new Result();
        session.open(device, opened);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        try { detachDevice(); }
        finally { unblock.countDown(); }
        assertSame(failure, opened.await().error);
        assertNull(opened.value);
        assertEquals(1, opened.completions);
        verify(nativeConnection, times(1)).close();
    }

    @Test public void detachCancelsUnstartedOpenAndPermanentlyInvalidatesItsDeviceView() throws Exception {
        LinkedBlockingQueue<Runnable> workers = holdWorkers();
        Result cancelled = new Result();
        session.open(device, cancelled);
        detachDevice();
        sameNameDevice();
        Result stale = new Result();
        session.open(device, stale);
        assertTrue(stale.await().error instanceof IllegalStateException);
        workers.remove().run();
        assertTrue(cancelled.await().error instanceof IllegalStateException);
        verify(manager, never()).openDevice(any(UsbDevice.class));

        UsbHostProxy.Device replacement = session.deviceList()[0];
        UsbDeviceConnection replacementNative = mock(UsbDeviceConnection.class);
        when(manager.openDevice(replacement.descriptor())).thenReturn(replacementNative);
        Result opened = new Result();
        session.open(replacement, opened);
        workers.remove().run();
        assertNull(opened.await().error);
        verify(manager).openDevice(replacement.descriptor());
        Result closed = new Result();
        ((UsbHostProxy.Connection) opened.value).close(closed);
        workers.remove().run();
        assertNull(closed.await().error);
        verify(replacementNative).close();

        // Enumeration invalidates a pending open even without a detach broadcast.
        Result unseen = new Result();
        session.open(replacement, unseen);
        attachedDevices.clear();
        assertEquals(0, session.deviceList().length);
        workers.remove().run();
        assertTrue(unseen.await().error instanceof IllegalStateException);
        verify(manager, times(1)).openDevice(any(UsbDevice.class));
    }

    @Test public void emptySessionRemainsUsableButSavedViewsCannotOpenAReconnectedDevice() throws Exception {
        detachDevice();
        assertEquals(0, session.deviceList().length);
        UsbDevice replacementUsb = sameNameDevice();
        Result stale = new Result();
        session.open(device, stale);
        assertTrue(stale.await().error instanceof IllegalStateException);
        verify(manager, never()).openDevice(any(UsbDevice.class));

        device = session.deviceList()[0];
        when(manager.openDevice(replacementUsb)).thenReturn(nativeConnection);
        UsbHostProxy.Connection first = open();
        attachedDevices.clear();
        assertEquals(0, session.deviceList().length);
        assertThrows(IllegalStateException.class, first::fileDescriptor);
        Result firstClosed = new Result();
        first.close(firstClosed);
        assertNull(firstClosed.await().error);
        verify(nativeConnection).close();

        replacementUsb = sameNameDevice();
        device = session.deviceList()[0];
        UsbDeviceConnection otherNative = mock(UsbDeviceConnection.class);
        when(manager.openDevice(replacementUsb)).thenReturn(otherNative);
        UsbHostProxy.Connection second = open();
        UsbHostProxy.detach(42);
        Result secondClosed = new Result();
        second.close(secondClosed);
        assertNull(secondClosed.await().error);
        verify(otherNative).close();
    }

    @Test public void sessionRestartClosesLateOpenAndSettlesItsCallbackOnlyOnce() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        CountDownLatch cleaned = new CountDownLatch(1);
        when(manager.openDevice(usb)).thenAnswer(call -> {
            entered.countDown();
            assertTrue(unblock.await(10, TimeUnit.SECONDS));
            return nativeConnection;
        });
        doAnswer(call -> { cleaned.countDown(); return null; }).when(nativeConnection).close();
        Result opened = new Result();
        session.open(device, opened);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        try {
            UsbHostProxy.detach(42);
            assertTrue(opened.await().error instanceof IllegalStateException);
            UsbHostProxy.attach(context, 42);
            assertNotSame(session, UsbHostProxy.session(42));
        } finally { unblock.countDown(); }
        assertTrue(cleaned.await(10, TimeUnit.SECONDS));
        assertEquals(1, opened.completions);
        verify(nativeConnection, times(1)).close();
    }

    @Test public void permissionCallbacksAreIsolatedBetweenSessionsWithTheSameRequestCode() throws Exception {
        LinkedBlockingQueue<PendingIntent> intents = new LinkedBlockingQueue<>();
        doAnswer(call -> { intents.add(call.getArgument(1)); return null; })
            .when(manager).requestPermission(eq(usb), any(PendingIntent.class));
        UsbHostProxy.attach(context, 43);
        try {
            Result first = new Result();
            session.requestPermission(device, first);
            PendingIntent one = intents.poll(10, TimeUnit.SECONDS);
            assertNotNull(one);
            UsbHostProxy.Session other = UsbHostProxy.session(43);
            Result second = new Result();
            other.requestPermission(other.deviceList()[0], second);
            PendingIntent two = intents.poll(10, TimeUnit.SECONDS);
            assertNotNull(two);
            Intent firstIntent = shadowOf(one).getSavedIntent();
            Intent secondIntent = shadowOf(two).getSavedIntent();
            assertEquals(firstIntent.getIntExtra("request", -1), secondIntent.getIntExtra("request", -1));
            assertNotEquals(firstIntent.getAction(), secondIntent.getAction());
            when(manager.hasPermission(usb)).thenReturn(true);
            one.send(context, 0, new Intent().putExtra(UsbManager.EXTRA_DEVICE, usb)
                .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true));
            shadowOf(Looper.getMainLooper()).idle();
            assertEquals(true, first.await().value);
            assertEquals(1, second.done.getCount());
            two.send(context, 0, new Intent().putExtra(UsbManager.EXTRA_DEVICE, usb)
                .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true));
            shadowOf(Looper.getMainLooper()).idle();
            assertEquals(true, second.await().value);
        } finally { UsbHostProxy.detach(43); }
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

    @Test public void closeInvalidatesPendingManagementWithoutWaitingForWorkerOrder() throws Exception {
        UsbHostProxy.Connection connection = open();
        LinkedBlockingQueue<Runnable> workers = holdWorkers();
        UsbInterface intf = mock(UsbInterface.class);
        UsbConfiguration config = mock(UsbConfiguration.class);
        Result serial = new Result();
        Result claim = new Result();
        Result release = new Result();
        Result setting = new Result();
        Result configuration = new Result();
        connection.serial(serial);
        connection.claimInterface(interfaceView(intf), false, claim);
        connection.releaseInterface(interfaceView(intf), release);
        connection.setInterface(interfaceView(intf), setting);
        connection.setConfiguration(configurationView(config), configuration);
        Result closed = new Result();
        Result alsoClosed = new Result();
        connection.close(closed);
        connection.close(alsoClosed);
        assertEquals(6, workers.size()); // Five operations and exactly one native close.
        Runnable[] tasks = workers.toArray(new Runnable[0]);
        tasks[0].run(); // Close has been requested but has not yet reached Android.
        assertTrue(serial.await().error instanceof IllegalStateException);
        assertThrows(IllegalStateException.class, connection::fileDescriptor);
        assertThrows(IllegalStateException.class, connection::rawDescriptors);
        assertTrue(claim(connection, intf).error instanceof IllegalStateException);
        assertEquals(6, workers.size()); // Rejected admission schedules nothing.
        verifyNoInteractions(nativeConnection);
        tasks[5].run(); // Native close can run ahead of older, unstarted work.
        assertNull(closed.await().error);
        assertNull(alsoClosed.await().error);
        for (int i = 1; i < 5; i++) tasks[i].run();
        for (Result result : new Result[] {claim, release, setting, configuration}) {
            assertTrue(result.await().error instanceof IllegalStateException);
            assertEquals(1, result.completions);
        }
        verify(nativeConnection, times(1)).close();
        verifyNoMoreInteractions(nativeConnection);
    }

    /** Holds pool tasks only in tests, allowing deterministic worker start/close races. */
    private LinkedBlockingQueue<Runnable> holdWorkers() throws Exception {
        Field field = UsbHostProxy.Session.class.getDeclaredField("workers");
        field.setAccessible(true);
        ExecutorService original = (ExecutorService) field.get(session);
        ExecutorService controlled = mock(ExecutorService.class);
        LinkedBlockingQueue<Runnable> tasks = new LinkedBlockingQueue<>();
        doAnswer(call -> { tasks.add(call.getArgument(0)); return null; })
            .when(controlled).execute(any(Runnable.class));
        doAnswer(call -> { original.shutdown(); return null; }).when(controlled).shutdown();
        field.set(session, controlled);
        return tasks;
    }

    /** Rejects only the next dispatch; subsequent tasks remain under test control. */
    private ExecutorService rejectNextWorker(LinkedBlockingQueue<Runnable> tasks, Throwable error) {
        ExecutorService workers = getField(session, "workers");
        doThrow(error).doAnswer(call -> { tasks.add(call.getArgument(0)); return null; })
            .when(workers).execute(any(Runnable.class));
        return workers;
    }

    @Test public void rejectedOpenSettlesItsCallWithoutCallingAndroid() throws Exception {
        LinkedBlockingQueue<Runnable> tasks = holdWorkers();
        RejectedExecutionException error = new RejectedExecutionException("open rejected");
        rejectNextWorker(tasks, error);
        Result failed = new Result();
        session.open(device, failed);
        assertSame(error, failed.await().error);
        assertEquals(1, failed.completions);
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        assertTrue(tasks.isEmpty());
        verify(manager, never()).openDevice(any(UsbDevice.class));

        Result retry = new Result();
        session.open(device, retry);
        tasks.remove().run();
        assertNull(retry.await().error);
        UsbHostProxy.Connection connection = (UsbHostProxy.Connection) retry.value;
        assertNotNull(connection);
        Result closed = new Result();
        connection.close(closed);
        tasks.remove().run();
        assertNull(closed.await().error);
        assertEquals(1, failed.completions);
    }

    @Test public void rejectedPermissionCancelsItsIntentAndAllowsAFreshDecision() throws Exception {
        LinkedBlockingQueue<Runnable> tasks = holdWorkers();
        ExecutorService workers = getField(session, "workers");
        RejectedExecutionException error = new RejectedExecutionException("permission rejected");
        AtomicReference<PendingIntent> cancelled = new AtomicReference<>();
        doAnswer(call -> {
            Map<?, ?> permissions = getField(session, "permissions");
            cancelled.set(getField(permissions.values().iterator().next(), "intent"));
            throw error;
        }).doAnswer(call -> { tasks.add(call.getArgument(0)); return null; })
            .when(workers).execute(any(Runnable.class));
        Result failed = new Result();
        session.requestPermission(device, failed);
        assertSame(error, failed.await().error);
        assertEquals(1, failed.completions);
        assertTrue(((Map<?, ?>) getField(session, "permissions")).isEmpty());
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        assertTrue(tasks.isEmpty());
        assertNotNull(cancelled.get());
        assertThrows(PendingIntent.CanceledException.class, () -> cancelled.get().send());
        verify(manager, never()).requestPermission(any(UsbDevice.class), any(PendingIntent.class));

        AtomicReference<PendingIntent> accepted = new AtomicReference<>();
        doAnswer(call -> { accepted.set(call.getArgument(1)); return null; })
            .when(manager).requestPermission(eq(usb), any(PendingIntent.class));
        Result retry = new Result();
        Result shared = new Result();
        session.requestPermission(device, retry);
        session.requestPermission(device, shared);
        assertEquals(1, tasks.size());
        tasks.remove().run();
        when(manager.hasPermission(usb)).thenReturn(true);
        accepted.get().send(context, 0, new Intent()
            .putExtra(UsbManager.EXTRA_DEVICE, usb)
            .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, true));
        shadowOf(Looper.getMainLooper()).idle();
        assertEquals(true, retry.await().value);
        assertEquals(true, shared.await().value);
        assertEquals(1, failed.completions);
        assertTrue(((Map<?, ?>) getField(session, "permissions")).isEmpty());
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
    }

    @Test public void rejectedSessionWorkSettlesItsCallWithoutReadingTheDevice() throws Exception {
        LinkedBlockingQueue<Runnable> tasks = holdWorkers();
        RejectedExecutionException error = new RejectedExecutionException("serial rejected");
        rejectNextWorker(tasks, error);
        Result failed = new Result();
        device.serial(failed);
        assertSame(error, failed.await().error);
        assertEquals(1, failed.completions);
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        assertTrue(tasks.isEmpty());
        verify(usb, never()).getSerialNumber();

        when(usb.getSerialNumber()).thenReturn("serial");
        Result retry = new Result();
        device.serial(retry);
        tasks.remove().run();
        assertEquals("serial", retry.await().value);
        assertNull(retry.error);
        assertEquals(1, failed.completions);
    }

    @Test public void rejectedConnectionWorkSettlesItsCallWithoutCallingAndroid() throws Exception {
        UsbHostProxy.Connection connection = open();
        UsbInterface intf = mock(UsbInterface.class);
        UsbHostProxy.Interface argument = interfaceView(intf);
        LinkedBlockingQueue<Runnable> tasks = holdWorkers();
        RejectedExecutionException error = new RejectedExecutionException("claim rejected");
        rejectNextWorker(tasks, error);
        Result failed = new Result();
        connection.claimInterface(argument, true, failed);
        assertSame(error, failed.await().error);
        assertEquals(1, failed.completions);
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        assertTrue(tasks.isEmpty());
        verifyNoInteractions(nativeConnection);

        when(nativeConnection.claimInterface(intf, true)).thenReturn(true);
        Result retry = new Result();
        connection.claimInterface(argument, true, retry);
        tasks.remove().run();
        assertEquals(true, retry.await().value);
        assertNull(retry.error);
        verify(nativeConnection).claimInterface(intf, true);
        Result closed = new Result();
        connection.close(closed);
        tasks.remove().run();
        assertNull(closed.await().error);
        assertEquals(1, failed.completions);
    }

    @Test public void rejectedCloseRetainsTheHandleAndAllowsAnotherSubmission() throws Exception {
        UsbHostProxy.Connection connection = open();
        LinkedBlockingQueue<Runnable> tasks = holdWorkers();
        RejectedExecutionException error = new RejectedExecutionException("close rejected");
        rejectNextWorker(tasks, error);
        Result failed = new Result();
        connection.close(failed);
        assertSame(error, failed.await().error);
        assertEquals(1, failed.completions);
        assertFalse((Boolean) getField(connection, "closing"));
        assertFalse((Boolean) getField(connection, "closed"));
        assertSame(nativeConnection, getField(connection, "connection"));
        assertTrue(((Set<?>) getField(session, "connections")).contains(connection));
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        assertTrue(((java.util.List<?>) getField(connection, "closeWaiters")).isEmpty());
        assertTrue(tasks.isEmpty());
        verify(nativeConnection, never()).close();
        when(nativeConnection.getFileDescriptor()).thenReturn(23);
        assertEquals(23, connection.fileDescriptor());

        Result retry = new Result();
        Result shared = new Result();
        connection.close(retry);
        connection.close(shared);
        assertEquals(1, tasks.size());
        assertThrows(IllegalStateException.class, connection::fileDescriptor);
        tasks.remove().run();
        assertNull(retry.await().error);
        assertNull(shared.await().error);
        assertEquals(1, failed.completions);
        verify(nativeConnection, times(1)).close();
        assertNull(getField(connection, "connection"));
        assertFalse(((Set<?>) getField(session, "connections")).contains(connection));
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
    }

    @Test public void rejectedDetachCloseDoesNotStopOtherClosesOrTheEvent() throws Exception {
        assertRejectedLifecycleCloseDoesNotStopCleanup(false);
    }

    @Test public void rejectedDisposeCloseDoesNotStopOtherClosesOrSessionCleanup() throws Exception {
        assertRejectedLifecycleCloseDoesNotStopCleanup(true);
    }

    /** Checks cleanup continuity without assuming HashSet connection iteration order. */
    private void assertRejectedLifecycleCloseDoesNotStopCleanup(boolean dispose) throws Exception {
        UsbHostProxy.Connection first = open();
        UsbDeviceConnection otherNative = mock(UsbDeviceConnection.class);
        when(manager.openDevice(usb)).thenReturn(otherNative);
        UsbHostProxy.Connection second = open();
        UsbHostProxy.Events events = mock(UsbHostProxy.Events.class);
        session.listen(events);
        LinkedBlockingQueue<Runnable> tasks = holdWorkers();
        Result pending = new Result();
        device.serial(pending);
        Result permission = new Result();
        session.requestPermission(device, permission);
        RejectedExecutionException error = new RejectedExecutionException("cleanup close rejected");
        ExecutorService workers = rejectNextWorker(tasks, error);
        if (dispose) {
            UsbHostProxy.detach(42);
            verify(events).disposed();
            verify(workers).shutdown();
            assertNull(getField(session, "events"));
            assertThrows(IllegalStateException.class, () -> UsbHostProxy.session(42));
            assertTrue(permission.await().error instanceof IllegalStateException);
        } else {
            detachDevice();
            verify(events).detached(device);
            verify(workers, never()).shutdown();
            assertTrue(((Map<?, ?>) getField(session, "devices")).isEmpty());
            assertEquals(false, permission.await().value);
            assertNull(permission.error);
        }
        assertFalse(device.lifetime.isAlive());
        assertNull(storedDescriptor(device));
        verify(nativeConnection, never()).close();
        verify(otherNative, never()).close(); // Rejection must never run close inline.
        assertEquals(3, tasks.size()); // Serial, permission submission and one accepted close.
        assertTrue(ShadowLog.getLogsForTag("UsbHostProxy").stream()
            .anyMatch(item -> item.throwable == error));
        while (!tasks.isEmpty()) tasks.remove().run();
        assertTrue(pending.await().error instanceof IllegalStateException);
        assertEquals(1, pending.completions);
        assertEquals(1, permission.completions);
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        assertTrue(((Map<?, ?>) getField(session, "permissions")).isEmpty());

        UsbHostProxy.Connection rejected = (Boolean) getField(first, "closed") ? second : first;
        UsbHostProxy.Connection closed = rejected == first ? second : first;
        UsbDeviceConnection rejectedNative = rejected == first ? nativeConnection : otherNative;
        UsbDeviceConnection closedNative = rejected == first ? otherNative : nativeConnection;
        assertFalse((Boolean) getField(rejected, "closing"));
        assertFalse((Boolean) getField(rejected, "closed"));
        assertSame(rejectedNative, getField(rejected, "connection"));
        assertNull(getField(closed, "connection"));
        verify(closedNative, times(1)).close();
        verify(rejectedNative, never()).close();
        assertThrows(IllegalStateException.class, rejected::fileDescriptor);

        Result retry = new Result();
        if (dispose) {
            // A terminated pool cannot accept a retry; it must still report the error.
            RejectedExecutionException ended = new RejectedExecutionException("pool shut down");
            doThrow(ended).when(workers).execute(any(Runnable.class));
            rejected.close(retry);
            assertSame(ended, retry.await().error);
            verify(rejectedNative, never()).close();
        } else {
            // Existing absence reconciliation can retry a close that was not submitted.
            assertEquals(0, session.deviceList().length);
            rejected.close(retry);
            assertEquals(1, tasks.size());
            tasks.remove().run();
            assertNull(retry.await().error);
            verify(rejectedNative, times(1)).close();
        }
        assertEquals(1, retry.completions);
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        verifyNoMoreInteractions(events);
    }

    @Test public void workerStartupErrorsAlsoSettleAllFiveSubmissionPaths() throws Exception {
        UsbHostProxy.Connection connection = open();
        LinkedBlockingQueue<Runnable> tasks = holdWorkers();
        ExecutorService workers = getField(session, "workers");
        OutOfMemoryError error = new OutOfMemoryError("simulated worker startup failure");
        doThrow(error).when(workers).execute(any(Runnable.class));
        Result opened = new Result();
        Result permission = new Result();
        Result deviceSerial = new Result();
        Result connectionSerial = new Result();
        Result closed = new Result();
        session.open(device, opened);
        session.requestPermission(device, permission);
        device.serial(deviceSerial);
        connection.serial(connectionSerial);
        connection.close(closed);
        for (Result result : new Result[] {opened, permission, deviceSerial, connectionSerial, closed}) {
            assertSame(error, result.await().error);
            assertEquals(1, result.completions);
        }
        assertTrue(((Set<?>) getField(session, "calls")).isEmpty());
        assertTrue(((Map<?, ?>) getField(session, "permissions")).isEmpty());
        assertTrue(tasks.isEmpty());
        verify(usb, never()).getSerialNumber();
        verify(manager, times(1)).openDevice(usb); // Only the setup open reached Android.
        verify(manager, never()).requestPermission(any(UsbDevice.class), any(PendingIntent.class));
        verifyNoInteractions(nativeConnection);
        doAnswer(call -> { tasks.add(call.getArgument(0)); return null; })
            .when(workers).execute(any(Runnable.class));
        Result retry = new Result();
        connection.close(retry);
        tasks.remove().run();
        assertNull(retry.await().error);
    }

    /** Adds an original descriptor; alternate settings can deliberately share a number. */
    private UsbInterface interfaceAt(int index, int number) {
        UsbInterface intf = mock(UsbInterface.class);
        when(intf.getId()).thenReturn(number);
        when(usb.getInterfaceCount()).thenReturn(index + 1);
        when(usb.getInterface(index)).thenReturn(intf);
        return intf;
    }

    /** Uses the JNI entry point; validation throws become failures as in Dart's _call. */
    private Result claim(UsbHostProxy.Connection connection, UsbInterface intf) throws Exception {
        Result result = new Result();
        try { connection.claimInterface(interfaceView(intf), false, result); }
        catch (IllegalStateException error) { result.failure(error); }
        return result.await();
    }

    /** Keeps native false distinct from synchronous validation and worker failures. */
    private Result release(UsbHostProxy.Connection connection, UsbInterface intf) throws Exception {
        Result result = new Result();
        try { connection.releaseInterface(interfaceView(intf), result); }
        catch (IllegalStateException error) { result.failure(error); }
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
        connection.setInterface(interfaceView(intf), select);
        assertEquals(false, select.await().value);
        Result again = new Result();
        connection.setInterface(interfaceView(intf), again);
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

    @Test public void managementCallsOnOneConnectionCanFinishWhileSerialIsStillRunning() throws Exception {
        UsbInterface intf = interfaceAt(0, 0);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(true);
        when(nativeConnection.releaseInterface(intf)).thenReturn(true);
        when(nativeConnection.setInterface(intf)).thenReturn(true);
        UsbConfiguration config = mock(UsbConfiguration.class);
        when(nativeConnection.setConfiguration(config)).thenReturn(true);
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
        Result configuration = new Result();
        try {
            connection.setInterface(interfaceView(intf), before);
            connection.releaseInterface(interfaceView(intf), releasing);
            connection.setInterface(interfaceView(intf), after);
            connection.claimInterface(interfaceView(intf), false, laterClaim);
            connection.setConfiguration(configurationView(config), configuration);
            assertEquals(true, before.await().value);
            assertEquals(true, releasing.await().value);
            assertEquals(true, after.await().value);
            assertEquals(true, laterClaim.await().value);
            assertEquals(true, configuration.await().value);
            assertEquals(1, serial.done.getCount());
        } finally { unblock.countDown(); }
        assertNull(serial.await().error);
        verify(nativeConnection, times(2)).claimInterface(intf, false);
        verify(nativeConnection).getSerial();
        verify(nativeConnection, times(2)).setInterface(intf);
        verify(nativeConnection).releaseInterface(intf);
        verify(nativeConnection).setConfiguration(config);
    }

    @Test public void descriptorsOutsideDeviceRegistryReachAndroidAndPreserveNativeResults() throws Exception {
        UsbInterface intf = mock(UsbInterface.class);
        UsbConfiguration config = mock(UsbConfiguration.class);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(true, false);
        when(nativeConnection.releaseInterface(intf)).thenReturn(false, true);
        when(nativeConnection.setInterface(intf)).thenReturn(true, false);
        when(nativeConnection.setConfiguration(config)).thenReturn(false, true);
        UsbHostProxy.Connection connection = open();
        for (int attempt = 0; attempt < 2; attempt++) {
            assertEquals(attempt == 0, claim(connection, intf).value);
            assertEquals(attempt != 0, release(connection, intf).value);
            Result setting = new Result();
            connection.setInterface(interfaceView(intf), setting);
            assertEquals(attempt == 0, setting.await().value);
            assertNull(setting.error);
            Result configuration = new Result();
            connection.setConfiguration(configurationView(config), configuration);
            assertEquals(attempt != 0, configuration.await().value);
            assertNull(configuration.error);
        }
        verify(nativeConnection, times(2)).claimInterface(intf, false);
        verify(nativeConnection, times(2)).releaseInterface(intf);
        verify(nativeConnection, times(2)).setInterface(intf);
        verify(nativeConnection, times(2)).setConfiguration(config);
        verify(usb, never()).getInterfaceCount();
        verify(usb, never()).getInterface(anyInt());
        verify(usb, never()).getConfigurationCount();
        verify(usb, never()).getConfiguration(anyInt());
    }

    @Test public void allFourNativeExceptionsArePreservedWithoutDescriptorValidation() throws Exception {
        UsbInterface intf = mock(UsbInterface.class);
        UsbConfiguration config = mock(UsbConfiguration.class);
        UsbHostProxy.Connection connection = open();

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
        connection.setInterface(interfaceView(intf), setting);
        assertSame(settingError, setting.await().error);
        Result configuration = new Result();
        connection.setConfiguration(configurationView(config), configuration);
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
        Result failed = new Result();
        connection.setConfiguration(configurationView(config), failed);
        assertEquals(false, failed.await().value);
        assertEquals(false, claim(connection, intf).value);
        Result success = new Result();
        connection.setConfiguration(configurationView(config), success);
        assertEquals(true, success.await().value);
        assertEquals(false, release(connection, intf).value);
        Result afterRelease = new Result();
        connection.setConfiguration(configurationView(config), afterRelease);
        assertEquals(false, afterRelease.await().value);
        assertEquals(true, claim(connection, intf).value);
        Result afterClaim = new Result();
        connection.setConfiguration(configurationView(config), afterClaim);
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
            connection.setInterface(interfaceView(intf), selected);
            assertTrue(selected.await().error instanceof IllegalStateException);
            Result configuration = new Result();
            connection.setConfiguration(configurationView(mock(UsbConfiguration.class)), configuration);
            assertTrue(configuration.await().error instanceof IllegalStateException);
        } finally { unblock.countDown(); }
        assertNull(serial.await().error);
        assertSame(error, closing.await().error);
        Result again = new Result();
        connection.close(again);
        assertNull(again.await().error);
        assertTrue(release(connection, intf).error instanceof IllegalStateException);
        verify(nativeConnection, times(1)).close();
        verify(nativeConnection, never()).releaseInterface(any());
        verify(nativeConnection, never()).setConfiguration(any());
    }

    @Test public void detachDiscardsUnstartedReleaseWithoutCallingNativeRelease() throws Exception {
        UsbInterface intf = interfaceAt(0, 0);
        when(nativeConnection.claimInterface(intf, false)).thenReturn(true);
        UsbHostProxy.Connection connection = open();
        assertEquals(true, claim(connection, intf).value);
        LinkedBlockingQueue<Runnable> workers = holdWorkers();
        Result pendingRelease = new Result();
        connection.releaseInterface(interfaceView(intf), pendingRelease);
        detachDevice();
        assertTrue(claim(connection, intf).error instanceof IllegalStateException);
        assertEquals(2, workers.size());
        workers.remove().run();
        assertTrue(pendingRelease.await().error instanceof IllegalStateException);
        assertNull(pendingRelease.value); // Not a native false result.
        workers.remove().run();
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        verify(nativeConnection).close();
        verify(nativeConnection, never()).releaseInterface(any());
    }

    @Test public void sessionEndDuringNativeUseSettlesOnceAndClosesAfterNativeReturn() throws Exception {
        UsbHostProxy.Connection connection = open();
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        AtomicBoolean nativeInUse = new AtomicBoolean();
        when(nativeConnection.getSerial()).thenAnswer(call -> {
            nativeInUse.set(true);
            entered.countDown();
            try {
                assertTrue(unblock.await(10, TimeUnit.SECONDS));
                return "serial";
            } finally { nativeInUse.set(false); }
        });
        doAnswer(call -> { assertFalse(nativeInUse.get()); return null; })
            .when(nativeConnection).close();
        Result serial = new Result();
        connection.serial(serial);
        assertTrue(entered.await(10, TimeUnit.SECONDS));
        try {
            detachDevice();
            UsbHostProxy.detach(42); // Shuts down the shared pool without blocking this thread.
            assertTrue(serial.await().error instanceof IllegalStateException);
            assertEquals(1, serial.completions);
            verify(nativeConnection, never()).close();
        } finally { unblock.countDown(); }
        Result closed = new Result();
        connection.close(closed);
        assertNull(closed.await().error);
        assertEquals(1, serial.completions);
        verify(nativeConnection, times(1)).close();
    }
}
