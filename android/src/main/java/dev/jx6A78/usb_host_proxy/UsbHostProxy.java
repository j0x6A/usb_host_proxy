package dev.jx6A78.usb_host_proxy;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbConfiguration;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.BadParcelableException;
import android.os.Build;
import android.util.Log;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.WeakHashMap;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.ReentrantReadWriteLock;

/**
 * Android backend exposed to Dart through JNIgen, without USB data transport.
 *
 * <p>Framework USB objects remain the source of descriptor data. This class adds
 * engine ownership, permission callbacks, name-based events and native lifetime protection.
 * The class monitor guards the engine registry; each Session guards its own state.
 */
public final class UsbHostProxy {
    /** Static entry points only; Flutter creates sessions through the plugin. */
    private UsbHostProxy() {}

    /** Engine ID to live session; accessed only under the class monitor. */
    private static final Map<Long, Session> sessions = new HashMap<>();

    /** Replaces an engine's previous session, settling its work before registration. */
    static synchronized void attach(Context context, long engineId) {
        detach(engineId);
        sessions.put(engineId, new Session(context.getApplicationContext()));
    }

    /** Ends the registered session, if any; repeated calls are harmless. */
    static synchronized void detach(long engineId) {
        Session session = sessions.remove(engineId);
        if (session != null) session.dispose();
    }

    /**
     * Routes Activity delivery under the registry lock; never revives a destroyed engine.
     * Package-private Android integration entry point, not part of the JNIgen surface.
     */
    static synchronized boolean handleActivityIntent(long engineId, Intent intent, boolean initial) {
        Session session = sessions.get(engineId);
        return session != null && session.handleActivityIntent(intent, initial);
    }

    /** Returns an existing engine session; never creates one from a JNI call. */
    public static synchronized Session session(long engineId) {
        Session session = sessions.get(engineId);
        if (session == null) throw new IllegalStateException("USB engine is not attached");
        return session;
    }

    /** Rethrow on the calling JNI thread, preserving Android exception details. */
    public static void rethrowError(Throwable error) throws Throwable {
        throw error;
    }

    /** Implemented by Dart as a nonblocking JNIgen listener. */
    public interface Completion {
        /** Delivers an operation-specific boxed value, native object, or null. */
        void success(Object value);
        /** Delivers the original failure for translation on the Dart side. */
        void failure(Throwable error);
    }

    /** Startup USB intents are initial state, not replayed attach events. */
    public interface Events {
        /** Reports the current attachment once for an accepted attach notification. */
        void attached(Device device);
        /** Reports a removed name after cancelling pending access and scheduling close. */
        void detached(Device device);
        /** Ends this session's event stream; does not represent physical detach. */
        void disposed();
    }

    /**
     * Shared validity of views obtained during one observed presence in Android's list.
     * This is resource ownership, not a hardware identifier: Android names still define equality.
     */
    static final class Lifetime {
        /** Android name retained after native references have been cleared. */
        public final String name;
        /** Android UsbDevice hashes its name using Java String.hashCode(). */
        public final int deviceHash;
        private volatile boolean active = true;
        /** True after this lifetime was returned to Dart, not merely discovered. Session-guarded. */
        private boolean exposed = false;
        /** Weak registrations do not retain every framework snapshot until detach. */
        private final Set<Descriptor<?>> views = Collections.newSetFromMap(new WeakHashMap<>());

        private Lifetime(String name) {
            this.name = name;
            this.deviceHash = name.hashCode();
        }

        /** Safe to read from Dart before the asynchronous detach callback arrives. */
        public boolean isAlive() { return active; }

        /** Caller holds the owning session monitor; admitted native calls keep local references. */
        private void end() {
            active = false;
            for (Descriptor<?> view : views) view.value = null;
            views.clear();
        }
    }

    /**
     * Java-owned reference to one original framework descriptor. JNI retains the
     * enclosing view, never this value directly. The session monitor guards admission
     * and registration; an admitted getter keeps a local reference until it returns.
     */
    private static final class Descriptor<T> {
        final Session owner;
        final Lifetime lifetime;
        T value;

        Descriptor(Session owner, Lifetime lifetime, T value) {
            this.owner = owner;
            this.lifetime = lifetime;
            synchronized (owner) {
                if (owner.active && lifetime.isAlive()) {
                    this.value = value;
                    lifetime.views.add(this);
                }
            }
        }

        T get() {
            synchronized (owner) {
                owner.checkActive();
                if (!lifetime.isAlive()) throw new IllegalStateException("USB device is detached");
                return value;
            }
        }
    }

    /** Framework view whose native reference ends with the observed device presence. */
    public static final class Device {
        /** Cleared by Java even if Dart keeps its JNI reference to this view. */
        private final Descriptor<UsbDevice> nativeDescriptor;
        /** Shared invalidation flag and immutable name/hash; contains no USB handles. */
        final Lifetime lifetime;
        /** Session used for dispatch and engine-lifecycle checks. */
        private final Session owner;
        /** Notification delivered, or consumed silently as initial Activity state; session-guarded. */
        private boolean attachNotified = false;

        private Device(Session owner, UsbDevice device, Lifetime lifetime) {
            this.owner = owner;
            this.lifetime = lifetime;
            this.nativeDescriptor = new Descriptor<>(owner, lifetime, device);
        }

        /** Internal framework access; raw descriptors do not escape through JNI. */
        UsbDevice descriptor() { return nativeDescriptor.get(); }

        /** Name and equality/hash remain usable after invalidation. */
        public String getDeviceName() { return lifetime.name; }
        @Override public boolean equals(Object other) {
            return other instanceof Device && lifetime.name.equals(((Device) other).lifetime.name);
        }
        @Override public int hashCode() { return lifetime.deviceHash; }

        public int getDeviceId() { return descriptor().getDeviceId(); }
        public int getDeviceClass() { return descriptor().getDeviceClass(); }
        public int getDeviceSubclass() { return descriptor().getDeviceSubclass(); }
        public int getDeviceProtocol() { return descriptor().getDeviceProtocol(); }
        public int getVendorId() { return descriptor().getVendorId(); }
        public int getProductId() { return descriptor().getProductId(); }
        public String getManufacturerName() { return descriptor().getManufacturerName(); }
        public String getProductName() { return descriptor().getProductName(); }
        public String getVersion() { return descriptor().getVersion(); }
        public int getConfigurationCount() { return descriptor().getConfigurationCount(); }
        public int getInterfaceCount() { return descriptor().getInterfaceCount(); }
        public Configuration getConfiguration(int index) {
            return new Configuration(owner, lifetime, descriptor().getConfiguration(index));
        }
        public Interface getInterface(int index) {
            return new Interface(owner, lifetime, descriptor().getInterface(index));
        }

        /** Reads serial on a worker, retaining a local reference only for the admitted call. */
        public void serial(Completion completion) {
            owner.work(completion, () -> {
                UsbDevice descriptor = descriptor();
                return descriptor.getSerialNumber();
            });
        }
    }

    /** Configuration view; validity and framework ownership remain in Java. */
    public static final class Configuration {
        private final Descriptor<UsbConfiguration> nativeDescriptor;
        private Configuration(Session owner, Lifetime lifetime, UsbConfiguration configuration) {
            nativeDescriptor = new Descriptor<>(owner, lifetime, configuration);
        }
        UsbConfiguration descriptor() { return nativeDescriptor.get(); }
        public int getId() { return descriptor().getId(); }
        public String getName() { return descriptor().getName(); }
        public int getMaxPower() { return descriptor().getMaxPower(); }
        public boolean isRemoteWakeup() { return descriptor().isRemoteWakeup(); }
        public boolean isSelfPowered() { return descriptor().isSelfPowered(); }
        public int getInterfaceCount() { return descriptor().getInterfaceCount(); }
        public Interface getInterface(int index) {
            return new Interface(nativeDescriptor.owner, nativeDescriptor.lifetime, descriptor().getInterface(index));
        }
    }

    /** Interface/alternate-setting view; does not track claims or selected settings. */
    public static final class Interface {
        private final Descriptor<UsbInterface> nativeDescriptor;
        private Interface(Session owner, Lifetime lifetime, UsbInterface intf) {
            nativeDescriptor = new Descriptor<>(owner, lifetime, intf);
        }
        UsbInterface descriptor() { return nativeDescriptor.get(); }
        public int getId() { return descriptor().getId(); }
        public int getAlternateSetting() { return descriptor().getAlternateSetting(); }
        public String getName() { return descriptor().getName(); }
        public int getInterfaceClass() { return descriptor().getInterfaceClass(); }
        public int getInterfaceSubclass() { return descriptor().getInterfaceSubclass(); }
        public int getInterfaceProtocol() { return descriptor().getInterfaceProtocol(); }
        public int getEndpointCount() { return descriptor().getEndpointCount(); }
        public Endpoint getEndpoint(int index) {
            return new Endpoint(nativeDescriptor.owner, nativeDescriptor.lifetime, descriptor().getEndpoint(index));
        }
    }

    /** Endpoint descriptor view; contains no transfer or connection state. */
    public static final class Endpoint {
        private final Descriptor<UsbEndpoint> nativeDescriptor;
        private Endpoint(Session owner, Lifetime lifetime, UsbEndpoint endpoint) {
            nativeDescriptor = new Descriptor<>(owner, lifetime, endpoint);
        }
        UsbEndpoint descriptor() { return nativeDescriptor.get(); }
        public int getAddress() { return descriptor().getAddress(); }
        public int getAttributes() { return descriptor().getAttributes(); }
        public int getDirection() { return descriptor().getDirection(); }
        public int getEndpointNumber() { return descriptor().getEndpointNumber(); }
        public int getInterval() { return descriptor().getInterval(); }
        public int getMaxPacketSize() { return descriptor().getMaxPacketSize(); }
        public int getType() { return descriptor().getType(); }
    }

    /**
     * Engine-scoped registry, receivers and pending work, shared by its Dart managers.
     *
     * <p>The session monitor guards devices, permissions, calls, connections and event
     * delivery. Normal worker operations run outside it; publication and late-open
     * cleanup reacquire it. Connection operations share the worker pool without FIFO.
     */
    public static final class Session {
        /** Application context, so the session does not retain an Activity. */
        private final Context context;
        /** Android service used for discovery, permission decisions and opening. */
        private final UsbManager manager;
        /** Unique permission callback route for this session, not a USB identity. */
        private final String permissionAction;
        /** Session-level work such as opening, device serial reads and permission submission. */
        private final ExecutorService workers = Executors.newCachedThreadPool();
        /** Last observed device views by Android name, used for event bookkeeping only. */
        private final Map<String, Device> devices = new HashMap<>();
        /** Published connections, retained until their worker close finishes. */
        private final Set<Connection> connections = new HashSet<>();
        /** Unsettled callbacks, including operations not yet admitted to native access. */
        private final Set<Call> calls = new HashSet<>();
        /** Request code to a permission decision, coalesced by Android device name. */
        private final Map<Integer, Permission> permissions = new HashMap<>();
        /** Source of request codes used by this session's PendingIntents. */
        private int nextPermission = 0;
        /** Becomes false before disposal invalidates resources and pending calls. */
        private boolean active = true;
        /** Single nonblocking JNIgen listener; notifications have no replay buffer. */
        private Events events;

        /** Routes runtime USB broadcasts to reconciliation against Android's live list. */
        private final BroadcastReceiver usbReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                UsbDevice device = extraDevice(intent);
                if (device == null) return;
                if (UsbManager.ACTION_USB_DEVICE_ATTACHED.equals(intent.getAction())) {
                    onAttached(device, true);
                } else if (UsbManager.ACTION_USB_DEVICE_DETACHED.equals(intent.getAction())) {
                    onDetached(device);
                }
            }
        };

        /** Matches replies by session action and request code, preserving Android's decision. */
        private final BroadcastReceiver permissionReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                if (!permissionAction.equals(intent.getAction())) return;
                synchronized (Session.this) {
                    int request = intent.getIntExtra("request", -1);
                    Permission pending = permissions.get(request);
                    if (pending == null || !active) return;
                    permissions.remove(request);
                    try {
                        UsbDevice reply = extraDevice(intent);
                        boolean granted = reply != null
                            && pending.device.lifetime.isAlive()
                            && reply.getDeviceName().equals(pending.device.lifetime.name)
                            && intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                            && manager.hasPermission(pending.device.descriptor());
                        pending.finish(granted, null);
                    } catch (Throwable error) { pending.finish(null, error); }
                }
            }
        };

        /** Registers both receivers; rolls back USB registration if permission setup fails. */
        private Session(Context context) {
            this.context = context;
            this.manager = (UsbManager) context.getSystemService(Context.USB_SERVICE);
            this.permissionAction = context.getPackageName() + ".USB_PERMISSION." + UUID.randomUUID();
            IntentFilter usbFilter = new IntentFilter(UsbManager.ACTION_USB_DEVICE_ATTACHED);
            usbFilter.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED);
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(usbReceiver, usbFilter, Context.RECEIVER_EXPORTED);
            } else {
                context.registerReceiver(usbReceiver, usbFilter);
            }
            try {
                IntentFilter permissionFilter = new IntentFilter(permissionAction);
                if (Build.VERSION.SDK_INT >= 33) {
                    context.registerReceiver(permissionReceiver, permissionFilter, Context.RECEIVER_NOT_EXPORTED);
                } else {
                    context.registerReceiver(permissionReceiver, permissionFilter);
                }
            } catch (RuntimeException error) {
                context.unregisterReceiver(usbReceiver);
                workers.shutdown();
                throw error;
            }
        }

        /** Installs the engine's sole Dart listener without replaying existing devices. */
        public synchronized void listen(Events listener) {
            checkActive();
            if (events != null) throw new IllegalStateException("USB supports one Dart isolate per engine");
            events = listener;
        }

        /** Rejects access after disposal; caller holds the session monitor. */
        private void checkActive() {
            if (!active) throw new IllegalStateException("USB session has ended");
        }

        /** Rejects ended views even if Android later reuses their name. */
        private void checkDevice(Device device) {
            checkActive();
            if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
            if (!device.lifetime.isAlive()) throw new IllegalStateException("USB device is detached");
        }

        /** Keeps the latest framework view and the name's notification flag; requires the monitor. */
        private Device remember(UsbDevice usbDevice) {
            String name = usbDevice.getDeviceName();
            Device previous = devices.get(name);
            // Reusing a view saves an allocation; it does not validate an attachment.
            if (previous != null && previous.descriptor() == usbDevice) return previous;
            Lifetime lifetime = previous == null ? new Lifetime(name) : previous.lifetime;
            Device device = new Device(this, usbDevice, lifetime);
            device.attachNotified = previous != null && previous.attachNotified;
            devices.put(name, device);
            return device;
        }

        /**
         * Reconciles the live framework list and returns its original descriptor references.
         * Missing known names trigger cleanup/detach; presence alone emits no attach.
         * This direct JNI entry point enumerates synchronously on the calling thread.
         */
        public synchronized Device[] deviceList() {
            checkActive();
            Map<String, UsbDevice> found = manager.getDeviceList();
            // Reconcile resource owners as well as the latest descriptor views.
            Set<String> missing = new HashSet<>(devices.keySet());
            for (Connection connection : connections) missing.add(connection.deviceName);
            for (Permission permission : permissions.values()) missing.add(permission.device.lifetime.name);
            for (Call call : calls) if (call.openingName != null) missing.add(call.openingName);
            missing.removeAll(found.keySet());
            for (String name : missing) removeDevice(name);
            ArrayList<Device> result = new ArrayList<>();
            for (UsbDevice usbDevice : found.values()) {
                Device device = remember(usbDevice);
                device.lifetime.exposed = true;
                result.add(device);
            }
            return result.toArray(new Device[0]);
        }

        /**
         * Resolves delayed JNI event delivery in Java. Returning null means that the
         * event is obsolete; Dart forwards this decision without its own registry.
         * Discovery alone does not expose an attachment until enumeration or delivery.
         */
        public synchronized Device eventDevice(Device device, boolean detached) {
            if (!active) return null;
            if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
            if (detached) {
                Device current = devices.get(device.lifetime.name);
                if (current != null && current.lifetime != device.lifetime && current.lifetime.exposed) return null;
            } else {
                if (!device.lifetime.isAlive()) return null;
                device.lifetime.exposed = true;
            }
            return device;
        }

        /** Returns Android's synchronous permission result for the supplied device view. */
        public synchronized boolean hasPermission(Device device) {
            checkDevice(device);
            return manager.hasPermission(device.descriptor());
        }

        /**
         * Shares one pending Android permission decision per name, without a timeout.
         * Refusal or observed detach completes false; session disposal completes with an error.
         * Only submission to Android is dispatched to a worker; no worker waits for the reply.
         */
        public synchronized void requestPermission(Device device, Completion completion) {
            Call call = new Call(this, completion);
            try {
                checkDevice(device);
                if (manager.hasPermission(device.descriptor())) { call.finish(true, null); return; }
                for (Permission permission : permissions.values()) {
                    if (permission.device.lifetime == device.lifetime) {
                        permission.waiters.add(call);
                        return;
                    }
                }
                int request = ++nextPermission;
                Intent intent = new Intent(permissionAction).setPackage(context.getPackageName());
                intent.putExtra("request", request);
                int flags = PendingIntent.FLAG_CANCEL_CURRENT;
                if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_MUTABLE;
                PendingIntent pendingIntent = PendingIntent.getBroadcast(context, request, intent, flags);
                Permission permission = new Permission(device, pendingIntent, call);
                permissions.put(request, permission);
                try {
                    workers.execute(() -> {
                        UsbDevice descriptor;
                        synchronized (Session.this) {
                            if (!active || permissions.get(request) != permission) return;
                            descriptor = device.descriptor();
                        }
                        try {
                            manager.requestPermission(descriptor, pendingIntent);
                        } catch (Throwable error) {
                            synchronized (Session.this) {
                                if (permissions.remove(request, permission)) permission.finish(null, error);
                            }
                        }
                    });
                } catch (Throwable error) {
                    if (permissions.remove(request, permission)) permission.finish(null, error);
                }
            } catch (Throwable error) {
                call.finish(null, error);
            }
        }

        /**
         * Opens on a session worker without implicitly requesting permission.
         * Native null is preserved. Detach/session end invalidates the pending open call;
         * a native connection arriving afterwards is closed instead of being published.
         */
        public synchronized void open(Device device, Completion completion) {
            Call call = new Call(this, completion);
            try {
                checkDevice(device);
                call.openingName = device.lifetime.name;
                workers.execute(() -> {
                    UsbDeviceConnection opened;
                    try {
                        UsbDevice descriptor;
                        synchronized (Session.this) {
                            if (call.completion == null) return;
                            if (call.openingName == null) {
                                call.finish(null, new IllegalStateException("USB device detached while opening"));
                                return;
                            }
                            checkDevice(device);
                            descriptor = device.descriptor();
                        }
                        opened = manager.openDevice(descriptor);
                    } catch (Throwable error) { call.finish(null, error); return; }
                    synchronized (Session.this) {
                        // The native open may have completed after detach or session shutdown.
                        if (call.completion != null && call.openingName != null && device.lifetime.isAlive()) {
                            if (opened == null) { call.finish(null, null); return; }
                            Connection connection = new Connection(this, device.lifetime, opened);
                            connections.add(connection);
                            call.finish(connection, null);
                            return;
                        }
                    }
                    // No caller owns this result. Close it without holding the session monitor.
                    if (opened != null) {
                        try { opened.close(); }
                        catch (Throwable error) {
                            Log.w("UsbHostProxy", "Late USB open cleanup failed", error);
                            call.finish(null, error);
                            return;
                        }
                    }
                    call.finish(null, new IllegalStateException("USB device or session ended while opening"));
                });
            } catch (Throwable error) { call.finish(null, error); }
        }

        /** Tracks a callback and dispatches session work; Call arbitrates late completion. */
        private synchronized void work(Completion completion, Callable<Object> operation) {
            Call call = new Call(this, completion);
            if (!active) { call.finish(null, new IllegalStateException("USB session has ended")); return; }
            try {
                workers.execute(() -> {
                    try { call.finish(operation.call(), null); }
                    catch (Throwable error) { call.finish(null, error); }
                });
            } catch (Throwable error) { call.finish(null, error); }
        }

        /**
         * Accepts only a USB attach action with a readable UsbDevice payload.
         * Initial Activity state consumes attach silently; later deliveries may notify.
         * True means the payload was recognized, even if live reconciliation finds it stale.
         * Neither form opens a device, requests permission nor trusts the payload as live state.
         */
        private synchronized boolean handleActivityIntent(Intent intent, boolean initial) {
            if (!active || intent == null
                || !UsbManager.ACTION_USB_DEVICE_ATTACHED.equals(intent.getAction())) return false;
            UsbDevice device;
            try {
                device = extraDevice(intent);
            } catch (BadParcelableException | ClassCastException error) {
                return false;
            }
            if (device == null) return false;
            onAttached(device, !initial);
            return true;
        }

        /**
         * Reconciles a name hint using one notification flag for Activity and broadcast paths.
         * notify controls attach delivery only: observed absence still removes a known name.
         * Silent initial delivery consumes the notification without synthesizing an event.
         */
        private synchronized void onAttached(UsbDevice usbDevice, boolean notify) {
            if (!active) return;
            String name = usbDevice.getDeviceName();
            // A queued attach may already be obsolete. Use the live framework object,
            // not the event payload or a descriptor fingerprint, for a new wrapper.
            UsbDevice present = manager.getDeviceList().get(name);
            if (present == null) {
                removeDevice(name);
                return;
            }
            Device device = remember(present);
            if (device.attachNotified) return;
            device.attachNotified = true;
            if (notify && events != null) {
                try { events.attached(device); }
                catch (RuntimeException error) { Log.w("UsbHostProxy", "USB listener unavailable", error); }
            }
        }

        /** Treats Android detach as authoritative for cleanup of that name. */
        private synchronized void onDetached(UsbDevice usbDevice) {
            if (!active) return;
            removeDevice(usbDevice.getDeviceName());
        }

        /**
         * Removes a known name, resolves its permissions false and schedules its closes.
         * Pending opens are invalidated so late native results cannot escape cleanup.
         * Requires the session monitor. Only a known name emits an event; cleanup
         * ends all snapshots before notification. Removal is idempotent.
         */
        private void removeDevice(String name) {
            Device device = devices.remove(name);
            if (device != null) device.lifetime.end();
            for (Map.Entry<Integer, Permission> entry : new ArrayList<>(permissions.entrySet())) {
                if (entry.getValue().device.lifetime.name.equals(name)) {
                    entry.getValue().device.lifetime.end();
                    permissions.remove(entry.getKey());
                    entry.getValue().finish(false, null);
                }
            }
            for (Call call : new ArrayList<>(calls)) {
                if (name.equals(call.openingName)) call.openingName = null;
            }
            for (Connection connection : new ArrayList<>(connections)) {
                if (connection.deviceName.equals(name)) {
                    connection.deviceLifetime.end();
                    connection.close(null);
                }
            }
            if (device != null && events != null) {
                try { events.detached(device); }
                catch (RuntimeException error) { Log.w("UsbHostProxy", "USB listener unavailable", error); }
            }
        }

        /**
         * Ends the session, unregisters receivers and settles pending calls with errors.
         * Accepted native closes may finish later; shutdown does not join worker threads.
         */
        private synchronized void dispose() {
            if (!active) return;
            active = false;
            for (Device device : devices.values()) device.lifetime.end();
            context.unregisterReceiver(usbReceiver);
            context.unregisterReceiver(permissionReceiver);
            for (Permission permission : permissions.values()) permission.finish(null, new IllegalStateException("USB session has ended"));
            permissions.clear();
            devices.clear();
            for (Connection connection : new ArrayList<>(connections)) connection.close(null);
            for (Call call : new ArrayList<>(calls)) call.finish(null, new IllegalStateException("USB session has ended"));
            Events listener = events;
            events = null;
            if (listener != null) {
                try { listener.disposed(); }
                catch (RuntimeException error) { Log.w("UsbHostProxy", "USB listener unavailable", error); }
            }
            workers.shutdown();
        }
    }

    /** Extracts the optional USB payload using the Parcelable API for the runtime SDK. */
    private static UsbDevice extraDevice(Intent intent) {
        if (Build.VERSION.SDK_INT >= 33) return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice.class);
        return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
    }

    /** One Android permission request shared by callers of the same Android name. */
    private static final class Permission {
        /** Supplied descriptor view; only its Android name correlates device events. */
        final Device device;
        /** Android reply token, cancelled when the decision is settled. */
        final PendingIntent intent;
        /** Callbacks waiting for this decision; accessed under the owning session. */
        final ArrayList<Call> waiters = new ArrayList<>();

        /** Starts a decision with its first waiting call. */
        Permission(Device device, PendingIntent intent, Call first) {
            this.device = device;
            this.intent = intent;
            waiters.add(first);
        }

        /** Cancels the reply token and settles all waiters under the session monitor. */
        void finish(Object value, Throwable error) {
            intent.cancel();
            for (Call call : waiters) call.finish(value, error);
            waiters.clear();
        }
    }

    /** Lets either a worker or session cleanup deliver the callback, never both. */
    private static final class Call {
        /** Owns the pending-call set and the monitor used to arbitrate completion. */
        final Session owner;
        /** Cleared before delivery so late workers cannot complete the call twice. */
        Completion completion;
        /** Open-attempt name, set before dispatch and cleared on detach under the session monitor. */
        String openingName;

        /** Registers a pending callback; caller holds the owner's monitor. */
        Call(Session owner, Completion completion) {
            this.owner = owner;
            this.completion = completion;
            owner.calls.add(this);
        }

        /** Removes and delivers the callback once; errors from a dead listener are logged. */
        void finish(Object value, Throwable error) {
            synchronized (owner) {
                if (completion == null) return;
                Completion target = completion;
                completion = null;
                owner.calls.remove(this);
                try {
                    if (error == null) target.success(value); else target.failure(error);
                } catch (RuntimeException callbackError) {
                    // The engine may have already destroyed its Dart isolate.
                    Log.w("UsbHostProxy", "USB callback unavailable", callbackError);
                }
            }
        }
    }

    /**
     * Owns one framework connection; the Android name is used only for detach cleanup.
     * Connection lifecycle is validated here; Android/kernel decide
     * interface claim and setting policy. No claim or alternate-setting history is kept.
     *
     * <p>Native calls share a lifetime read lock; close alone takes its write lock.
     * This allows concurrent operations while preventing close from freeing an object
     * still in native use. Close marks admission closed under the session monitor,
     * but never waits for native access while holding that monitor. Workers release
     * native access before delivering callbacks or finalizing close under the monitor.
     */
    public static final class Connection {
        /** Session responsible for tracking this connection and its callbacks. */
        private final Session owner;
        /** Shared device validity; close remains available after it ends. */
        private final Lifetime deviceLifetime;
        /** Name used to close this particular native connection when Android reports detach. */
        private final String deviceName;
        /** Shared native access for operations; exclusive access for native close. */
        private final ReentrantReadWriteLock nativeLifetime = new ReentrantReadWriteLock();
        /** Original native connection; accessed only under the lifetime lock. */
        private UsbDeviceConnection connection;
        /** Set under the session monitor; volatile so direct reads reject close immediately. */
        private volatile boolean closing = false;
        /** Session-guarded completion of the native close attempt, including failure. */
        private boolean closed = false;
        /** Close callers awaiting the same close result; session-monitor guarded. */
        private final ArrayList<Call> closeWaiters = new ArrayList<>();

        /** Takes ownership of a successfully opened native connection. */
        private Connection(Session owner, Lifetime lifetime, UsbDeviceConnection connection) {
            this.owner = owner;
            this.deviceLifetime = lifetime;
            this.deviceName = lifetime.name;
            this.connection = connection;
        }

        /** Rejects access after close scheduling, including before taking a native lock. */
        private void checkOpen() {
            if (closing || !deviceLifetime.isAlive()) throw new IllegalStateException("USB connection is closed or detached");
        }

        /** Rejects an open result invalidated before Dart receives its callback. */
        public void checkResult() {
            synchronized (owner) {
                owner.checkActive();
                checkOpen();
            }
        }

        /** Returns the native descriptor without transferring ownership of it to the caller. */
        public int fileDescriptor() {
            checkOpen();
            nativeLifetime.readLock().lock();
            try {
                checkOpen();
                return connection.getFileDescriptor();
            } finally { nativeLifetime.readLock().unlock(); }
        }

        /** Reads Android's raw descriptor bytes while excluding native close; may return null. */
        public byte[] rawDescriptors() {
            checkOpen();
            nativeLifetime.readLock().lock();
            try {
                checkOpen();
                return connection.getRawDescriptors();
            } finally { nativeLifetime.readLock().unlock(); }
        }

        /**
         * Dispatches unordered management work through the session's existing pool.
         * Admission to native access is the final lifecycle check under the shared
         * lifetime lock. Close/detach rejects work that has not passed this check;
         * admitted native calls finish before native close can acquire exclusive access.
         */
        private void submit(Completion completion, Callable<Object> operation) {
            synchronized (owner) {
                Call call = new Call(owner, completion);
                if (closing) { call.finish(null, new IllegalStateException("USB connection is closed or detached")); return; }
                try {
                    owner.workers.execute(() -> {
                        try {
                            checkOpen();
                            Object value;
                            nativeLifetime.readLock().lock();
                            try {
                                synchronized (owner) {
                                    owner.checkActive();
                                    checkOpen();
                                }
                                value = operation.call();
                            } finally { nativeLifetime.readLock().unlock(); }
                            call.finish(value, null);
                        } catch (Throwable error) { call.finish(null, error); }
                    });
                } catch (Throwable error) { call.finish(null, error); }
            }
        }

        /** Reads the native connection's serial on a session worker. */
        public void serial(Completion completion) {
            submit(completion, () -> connection.getSerial());
        }

        /** Resolves a live Java view, without imposing descriptor-identity or claim rules. */
        public void claimInterface(Interface intf, boolean force, Completion completion) {
            UsbInterface descriptor = intf.descriptor();
            submit(completion, () -> connection.claimInterface(descriptor, force));
        }

        /** Explicit release remains an Android decision, even without a prior claim. */
        public void releaseInterface(Interface intf, Completion completion) {
            UsbInterface descriptor = intf.descriptor();
            submit(completion, () -> connection.releaseInterface(descriptor));
        }

        /** Forwards a live alternate-setting descriptor to Android. */
        public void setInterface(Interface intf, Completion completion) {
            UsbInterface descriptor = intf.descriptor();
            submit(completion, () -> connection.setInterface(descriptor));
        }

        /** Forwards a live configuration descriptor to Android. */
        public void setConfiguration(Configuration configuration, Completion completion) {
            UsbConfiguration descriptor = configuration.descriptor();
            submit(completion, () -> connection.setConfiguration(descriptor));
        }

        /**
         * Rejects pending/new work and dispatches one close to the session worker pool.
         * Native close waits only for admitted native calls, without FIFO ordering.
         * Concurrent callers share its result.
         * A null completion is used by lifecycle cleanup. Already-closed calls succeed;
         * a failure from the first native close attempt is not replayed to later callers.
         * No interface releases are issued here. The connection stays unusable even
         * on native close failure.
         */
        public void close(Completion completion) {
            synchronized (owner) {
                if (completion != null) {
                    Call call = new Call(owner, completion);
                    if (closed) { call.finish(null, null); return; }
                    closeWaiters.add(call);
                }
                if (closing) return;
                closing = true;
                try {
                    owner.workers.execute(() -> {
                        Throwable error = null;
                        nativeLifetime.writeLock().lock();
                        try {
                            connection.close();
                        } catch (Throwable failure) { error = failure; }
                        finally {
                            connection = null;
                            nativeLifetime.writeLock().unlock();
                        }
                        synchronized (owner) {
                            closed = true;
                            owner.connections.remove(this);
                            if (error != null) Log.w("UsbHostProxy", "USB connection close failed", error);
                            for (Call waiter : closeWaiters) waiter.finish(null, error);
                            closeWaiters.clear();
                        }
                    });
                } catch (Throwable error) {
                    // Native close never started. Retain the handle and allow another submission.
                    ArrayList<Call> waiters = new ArrayList<>(closeWaiters);
                    closeWaiters.clear();
                    closing = false;
                    Log.w("UsbHostProxy", "USB connection close submission failed", error);
                    for (Call waiter : waiters) waiter.finish(null, error);
                }
            }
        }
    }
}
