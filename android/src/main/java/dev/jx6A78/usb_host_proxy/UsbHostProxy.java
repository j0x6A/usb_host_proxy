package dev.jx6A78.usb_host_proxy;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbConfiguration;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.BadParcelableException;
import android.os.Build;
import android.util.Log;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Android backend exposed to Dart through JNIgen, without USB data transport.
 *
 * <p>Framework USB objects remain the source of descriptor data. This class adds
 * attachment identity, engine ownership, permission callbacks and operation queues.
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
        /** Reports a retired attachment after invalidation and scheduling close. */
        void detached(Device device);
        /** Ends this session's event stream; does not represent physical detach. */
        void disposed();
    }

    /** One observed attachment. A reused Android name alone cannot prove reattachment. */
    public static final class Device {
        /** Original descriptor object; retained even after this attachment is retired. */
        public final UsbDevice usbDevice;
        /** Session that created this wrapper and owns its mutable lifecycle state. */
        private final Session owner;
        /** Private Android name plus UUID, fixed for this observed attachment. */
        private final String internalId;
        /** Session-guarded flag; false after retirement and never becomes true again. */
        private boolean attached = true;
        /** Notification delivered, or consumed silently as initial Activity state; session-guarded. */
        private boolean attachNotified = false;

        /** Creates an identity only when the session observes a device as present. */
        private Device(Session owner, UsbDevice device) {
            this.owner = owner;
            this.usbDevice = device;
            this.internalId = device.getDeviceName() + "-" + UUID.randomUUID();
        }

        /** Reads the framework serial on a worker after checking attachment ownership. */
        public void serial(Completion completion) {
            owner.work(completion, () -> {
                synchronized (owner) { owner.checkDevice(this); }
                return usbDevice.getSerialNumber();
            });
        }
    }

    /**
     * Engine-scoped registry, receivers and pending work, shared by its Dart managers.
     *
     * <p>The session monitor guards devices, permissions, calls, connections and event
     * delivery. Normal worker operations run outside it; publication and late-open
     * cleanup reacquire it. Each connection's queue orders only that connection.
     */
    public static final class Session {
        /** Application context, so the session does not retain an Activity. */
        private final Context context;
        /** Android service used for discovery, permission decisions and opening. */
        private final UsbManager manager;
        /** Unique reply action for this session, not an attachment identifier. */
        private final String permissionAction;
        /** Session-level work such as opening, device serial reads and permission submission. */
        private final ExecutorService workers = Executors.newCachedThreadPool();
        /** Name index of current wrappers; the name is a locator, not lifetime identity. */
        private final Map<String, Device> devices = new HashMap<>();
        /** Published connections, retained until their queued close finishes. */
        private final Set<Connection> connections = new HashSet<>();
        /** Unsettled callbacks, including operations waiting in connection queues. */
        private final Set<Call> calls = new HashSet<>();
        /** Request code to coalesced permission decision for one attachment. */
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

        /** Matches replies by request code and attachment UUID before consuming a waiter. */
        private final BroadcastReceiver permissionReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                if (!permissionAction.equals(intent.getAction())) return;
                synchronized (Session.this) {
                    int request = intent.getIntExtra("request", -1);
                    Permission pending = permissions.get(request);
                    if (pending == null || !active
                        || !pending.device.internalId.equals(intent.getStringExtra("deviceInstance"))) return;
                    permissions.remove(request);
                    try {
                        UsbDevice reply = extraDevice(intent);
                        boolean granted = reply != null
                            && reply.getDeviceName().equals(pending.device.usbDevice.getDeviceName())
                            && isCurrentDevice(pending.device)
                            && intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                            && manager.hasPermission(pending.device.usbDevice);
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

        /** Distinguishes foreign ownership from a stale attachment; requires the monitor. */
        private void checkDevice(Device device) {
            checkActive();
            if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
            if (!isCurrentDevice(device)) throw new IllegalStateException("USB device attachment is no longer current");
        }

        /** Checks owner, lifecycle flag and current UUID under the session monitor. */
        private boolean isCurrentDevice(Device device) {
            Device current = devices.get(device.usbDevice.getDeviceName());
            return device.owner == this && device.attached && current != null
                && current.internalId.equals(device.internalId);
        }

        /**
         * Reconciles the live framework list and returns canonical attachment wrappers.
         * Missing names are retired and may emit detach; presence alone emits no attach.
         * This direct JNI entry point enumerates synchronously on the calling thread.
         */
        public synchronized Device[] deviceList() {
            checkActive();
            Map<String, UsbDevice> found = manager.getDeviceList();
            // Only an observed absence ends this attachment. Changed Java object
            // identity or descriptor values are not evidence of reattachment.
            for (Device old : new ArrayList<>(devices.values())) {
                if (!found.containsKey(old.usbDevice.getDeviceName())) retire(old, true);
            }
            ArrayList<Device> result = new ArrayList<>();
            for (Map.Entry<String, UsbDevice> entry : found.entrySet()) {
                Device device = devices.get(entry.getKey());
                if (device == null) {
                    device = new Device(this, entry.getValue());
                    devices.put(entry.getKey(), device);
                }
                result.add(device);
            }
            return result.toArray(new Device[0]);
        }

        /** Checks Android synchronously; a retired attachment returns false, a foreign one fails. */
        public synchronized boolean hasPermission(Device device) {
            checkActive();
            if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
            return isCurrentDevice(device) && manager.hasPermission(device.usbDevice);
        }

        /**
         * Shares one pending Android permission decision per attachment, without a timeout.
         * Refusal or retirement completes false; session disposal completes with an error.
         * Only submission to Android is dispatched to a worker; no worker waits for the reply.
         */
        public synchronized void requestPermission(Device device, Completion completion) {
            Call call = new Call(this, completion);
            try {
                checkActive();
                if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
                if (!isCurrentDevice(device)) { call.finish(false, null); return; }
                if (manager.hasPermission(device.usbDevice)) { call.finish(true, null); return; }
                for (Permission permission : permissions.values()) {
                    if (permission.device == device) { permission.waiters.add(call); return; }
                }
                int request = ++nextPermission;
                Intent intent = new Intent(permissionAction).setPackage(context.getPackageName());
                intent.putExtra("request", request);
                intent.putExtra("deviceInstance", device.internalId);
                int flags = PendingIntent.FLAG_CANCEL_CURRENT;
                if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_MUTABLE;
                PendingIntent pendingIntent = PendingIntent.getBroadcast(context, request, intent, flags);
                Permission permission = new Permission(device, pendingIntent, call);
                permissions.put(request, permission);
                workers.execute(() -> {
                    synchronized (Session.this) {
                        if (!active || !isCurrentDevice(device) || permissions.get(request) != permission) return;
                    }
                    try {
                        manager.requestPermission(device.usbDevice, pendingIntent);
                    } catch (Throwable error) {
                        synchronized (Session.this) {
                            if (permissions.remove(request, permission)) permission.finish(null, error);
                        }
                    }
                });
            } catch (Throwable error) {
                call.finish(null, error);
            }
        }

        /**
         * Opens on a session worker without implicitly requesting permission.
         * Native null is preserved. A connection opened across retirement/disposal is
         * closed here instead of being published to Dart under an obsolete identity.
         */
        public void open(Device device, Completion completion) {
            work(completion, () -> {
                synchronized (this) { checkDevice(device); }
                UsbDeviceConnection opened = manager.openDevice(device.usbDevice);
                if (opened == null) return null;
                synchronized (this) {
                    if (!active || !isCurrentDevice(device)) {
                        opened.close();
                        throw new IllegalStateException("USB device or session ended while opening");
                    }
                    Connection connection = new Connection(this, device, opened);
                    connections.add(connection);
                    return connection;
                }
            });
        }

        /** Tracks a callback and dispatches session work; Call arbitrates late completion. */
        private synchronized void work(Completion completion, Callable<Object> operation) {
            Call call = new Call(this, completion);
            if (!active) { call.finish(null, new IllegalStateException("USB session has ended")); return; }
            workers.execute(() -> {
                try { call.finish(operation.call(), null); }
                catch (Throwable error) { call.finish(null, error); }
            });
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
         * Reconciles a name hint using the same wrapper and flag for Activity and broadcast paths.
         * notify controls attach delivery only: observed absence still retires a known device.
         * Silent initial delivery consumes the notification without changing the wrapper's UUID.
         */
        private synchronized void onAttached(UsbDevice usbDevice, boolean notify) {
            if (!active) return;
            String name = usbDevice.getDeviceName();
            // A queued attach may already be obsolete. Use the live framework object,
            // not the event payload or a descriptor fingerprint, for a new wrapper.
            UsbDevice present = manager.getDeviceList().get(name);
            Device device = devices.get(name);
            if (present == null) {
                if (device != null) retire(device, true);
                return;
            }
            if (device == null) {
                device = new Device(this, present);
                devices.put(name, device);
            }
            // Enumeration and duplicate attach notifications share the same UUID.
            if (device.attachNotified) return;
            device.attachNotified = true;
            if (notify && events != null) {
                try { events.attached(device); }
                catch (RuntimeException error) { Log.w("UsbHostProxy", "USB listener unavailable", error); }
            }
        }

        /** Retires only a known, currently absent name; ignores unknown or ambiguous edges. */
        private synchronized void onDetached(UsbDevice usbDevice) {
            if (!active) return;
            String name = usbDevice.getDeviceName();
            // If this name is live, the notification may refer to an older attachment.
            // Without an Android attachment token we cannot assign that edge safely.
            if (manager.getDeviceList().containsKey(name)) return;
            Device device = devices.get(name);
            if (device != null) retire(device, true);
        }

        /**
         * Invalidates one wrapper, resolves its permissions false and queues its closes.
         * Requires the session monitor. notify is false during engine disposal, which
         * must not manufacture physical detach events. Repeated retirement is harmless.
         */
        private void retire(Device device, boolean notify) {
            if (!device.attached) return;
            device.attached = false;
            devices.remove(device.usbDevice.getDeviceName(), device);
            for (Map.Entry<Integer, Permission> entry : new ArrayList<>(permissions.entrySet())) {
                if (entry.getValue().device == device) {
                    permissions.remove(entry.getKey());
                    entry.getValue().finish(false, null);
                }
            }
            for (Connection connection : new ArrayList<>(connections)) {
                if (connection.device == device) connection.close(null);
            }
            if (notify && events != null) {
                try { events.detached(device); }
                catch (RuntimeException error) { Log.w("UsbHostProxy", "USB listener unavailable", error); }
            }
        }

        /**
         * Ends the session, unregisters receivers and settles pending calls with errors.
         * Queued native closes may finish later; shutdown does not join worker threads.
         */
        private synchronized void dispose() {
            if (!active) return;
            active = false;
            context.unregisterReceiver(usbReceiver);
            context.unregisterReceiver(permissionReceiver);
            for (Permission permission : permissions.values()) permission.finish(null, new IllegalStateException("USB session has ended"));
            permissions.clear();
            for (Device device : new ArrayList<>(devices.values())) retire(device, false);
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

    /** One Android permission request shared by callers of the exact same Device wrapper. */
    private static final class Permission {
        /** Attachment to which the decision belongs, not just its reusable name. */
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

    /** Exactly-once callback slot shared by normal completion and session cleanup. */
    private static final class Call {
        /** Owns the pending-call set and the monitor used to arbitrate completion. */
        final Session owner;
        /** Cleared before delivery so late workers cannot complete the call twice. */
        Completion completion;

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
     * Owns one framework connection, bound permanently to one attachment wrapper.
     *
     * <p>Lifecycle changes acquire the session monitor before readLock. Synchronous
     * reads use readLock alone; native close also uses it. Accepted management work
     * and close are serialized on this connection's queue, never on a global queue.
     */
    public static final class Connection {
        /** Session responsible for tracking this connection and its callbacks. */
        private final Session owner;
        /** Exact attachment used at open time; never rebound after name reuse. */
        private final Device device;
        /** FIFO executor for this connection's management operations and final close. */
        private final ExecutorService queue = Executors.newSingleThreadExecutor();
        /** Guards direct descriptor reads, native close and connection lifecycle flags. */
        private final Object readLock = new Object();
        /** Original native connection; cleared after the queued close attempt. */
        private UsbDeviceConnection connection;
        /** Rejects new work as soon as close is scheduled, before native close finishes. */
        private boolean closing = false;
        /** Marks completion of the native close attempt, including a failed attempt. */
        private boolean closed = false;
        /** Close callers awaiting the same queued close result; session-monitor guarded. */
        private final ArrayList<Call> closeWaiters = new ArrayList<>();
        /** Last returned ownership result, not a live query of kernel state. */
        private enum InterfaceState { UNCLAIMED, CLAIMED, UNKNOWN }
        /** Queue-owned observations shared by alternate settings with the same number. */
        private final Map<Integer, InterfaceState> interfaces = new HashMap<>();
        /**
         * Number of outstanding releases per interface, guarded by the session monitor.
         * Counts include queued work: settling one release must not remove the barrier
         * of another release already accepted for the same interface number.
         */
        private final Map<Integer, Integer> pendingReleases = new HashMap<>();

        /** Takes ownership of a successfully opened native connection. */
        private Connection(Session owner, Device device, UsbDeviceConnection connection) {
            this.owner = owner;
            this.device = device;
            this.connection = connection;
        }

        /** Rejects reads after close scheduling; caller holds readLock. */
        private void checkOpen() {
            if (closing) throw new IllegalStateException("USB connection is closed or detached");
        }

        /** Returns the native descriptor without transferring ownership of it to the caller. */
        public int fileDescriptor() {
            synchronized (readLock) {
                checkOpen();
                return connection.getFileDescriptor();
            }
        }

        /** Reads Android's raw descriptor bytes while excluding native close; may return null. */
        public byte[] rawDescriptors() {
            synchronized (readLock) {
                checkOpen();
                return connection.getRawDescriptors();
            }
        }

        /**
         * Enqueues management work and checks attachment validity before executing it.
         * Explicit close drains accepted work; retirement invalidates queued work.
         * An operation already inside a native call is not forcibly interrupted.
         */
        private void submit(Completion completion, Callable<Object> operation) {
            submit(completion, operation, null, false);
        }

        /**
         * Validates descriptors before installing a release admission barrier.
         * A null interface denotes connection-wide work. Non-release interface work
         * is rejected while releases are outstanding; its ownership state is checked
         * later on the FIFO queue, after earlier claims/releases have returned.
         * Every queued release removes its barrier before delivering success/error,
         * including a release invalidated by detach before native execution.
         */
        private void submit(Completion completion, Callable<Object> operation,
                            UsbInterface intf, boolean releasing) {
            synchronized (owner) {
                Call call = new Call(owner, completion);
                synchronized (readLock) {
                    if (closing) { call.finish(null, new IllegalStateException("USB connection is closed or detached")); return; }
                    final Integer id;
                    try {
                        if (intf != null) checkInterface(intf);
                        id = intf == null ? null : intf.getId();
                        if (id != null && !releasing && pendingReleases.containsKey(id)) {
                            throw new IllegalStateException("USB interface release is pending");
                        }
                    } catch (Throwable error) { call.finish(null, error); return; }
                    if (releasing) pendingReleases.merge(id, 1, Integer::sum);
                    queue.execute(() -> {
                        Object result = null;
                        Throwable failure = null;
                        try {
                            // Explicit close drains accepted work; detach/session end
                            // invalidates queued work before it touches the device.
                            synchronized (owner) { owner.checkDevice(device); }
                            result = operation.call();
                        } catch (Throwable error) { failure = error; }
                        synchronized (owner) {
                            if (releasing) {
                                int remaining = pendingReleases.get(id) - 1;
                                if (remaining == 0) pendingReleases.remove(id);
                                else pendingReleases.put(id, remaining);
                            }
                            call.finish(result, failure);
                        }
                    });
                }
            }
        }

        /** Reads the native connection's serial on its ordered operation queue. */
        public void serial(Completion completion) {
            submit(completion, () -> connection.getSerial());
        }

        /** Requires the original interface reference from this device, not matching numeric IDs. */
        private void checkInterface(UsbInterface intf) {
            for (int i = 0; i < device.usbDevice.getInterfaceCount(); i++) {
                if (device.usbDevice.getInterface(i) == intf) return;
            }
            throw new IllegalArgumentException("Interface belongs to another device attachment");
        }

        /** Queue-only state; absence means initial, released or configuration-invalidated. */
        private InterfaceState interfaceState(UsbInterface intf) {
            return interfaces.getOrDefault(intf.getId(), InterfaceState.UNCLAIMED);
        }

        /** Requires UNCLAIMED; only native true establishes CLAIMED. Force is not a guarantee. */
        public void claim(UsbInterface intf, boolean force, Completion completion) {
            submit(completion, () -> {
                if (interfaceState(intf) != InterfaceState.UNCLAIMED) {
                    throw new IllegalStateException("USB interface is already claimed or UNKNOWN");
                }
                boolean claimed = connection.claimInterface(intf, force);
                if (claimed) interfaces.put(intf.getId(), InterfaceState.CLAIMED);
                return claimed;
            }, intf, false);
        }

        /** Rejects UNCLAIMED. Only returned native false establishes UNKNOWN. */
        public void release(UsbInterface intf, Completion completion) {
            submit(completion, () -> {
                if (interfaceState(intf) == InterfaceState.UNCLAIMED) {
                    throw new IllegalStateException("USB interface is UNCLAIMED");
                }
                // The admission barrier is separate from the last returned state.
                // Exceptions are errors, not evidence of a native false result.
                boolean released = connection.releaseInterface(intf);
                if (released) interfaces.remove(intf.getId());
                else interfaces.put(intf.getId(), InterfaceState.UNKNOWN);
                return released;
            }, intf, true);
        }

        /** Requires CLAIMED at execution; selecting an alternate setting does not change ownership. */
        public void selectInterface(UsbInterface intf, Completion completion) {
            submit(completion, () -> {
                if (interfaceState(intf) != InterfaceState.CLAIMED) {
                    throw new IllegalStateException("USB interface must be CLAIMED");
                }
                return connection.setInterface(intf);
            }, intf, false);
        }

        /**
         * Validates the original configuration and rejects unresolved UNKNOWN states.
         * Only native true invalidates all recorded claims; false/errors retain the
         * last observations. No implicit release or recovery calls are performed.
         */
        public void selectConfiguration(UsbConfiguration configuration, Completion completion) {
            submit(completion, () -> {
                for (int i = 0; i < device.usbDevice.getConfigurationCount(); i++) {
                    if (device.usbDevice.getConfiguration(i) == configuration) {
                        if (interfaces.containsValue(InterfaceState.UNKNOWN)) {
                            throw new IllegalStateException("Release UNKNOWN interfaces or close before selecting configuration");
                        }
                        boolean selected = connection.setConfiguration(configuration);
                        if (selected) interfaces.clear();
                        return selected;
                    }
                }
                throw new IllegalArgumentException("Configuration belongs to another device attachment");
            });
        }

        /**
         * Schedules one native close after accepted work; concurrent callers share its result.
         * A null completion is used by lifecycle cleanup. Already-closed calls succeed;
         * a failure from the first native close attempt is not replayed to later callers.
         * No interface releases are issued here. The connection stays unusable even
         * on native close failure; discarding observations does not create UNKNOWN.
         */
        public void close(Completion completion) {
            synchronized (owner) {
                if (completion != null) {
                    Call call = new Call(owner, completion);
                    if (closed) { call.finish(null, null); return; }
                    closeWaiters.add(call);
                }
                synchronized (readLock) {
                    if (closing) return;
                    closing = true;
                    queue.execute(() -> {
                        Throwable error = null;
                        try {
                            synchronized (readLock) { connection.close(); }
                        } catch (Throwable failure) { error = failure; }
                        synchronized (owner) {
                            interfaces.clear();
                            synchronized (readLock) { connection = null; closed = true; }
                            owner.connections.remove(this);
                            for (Call waiter : closeWaiters) waiter.finish(null, error);
                            closeWaiters.clear();
                        }
                    });
                    queue.shutdown();
                }
            }
        }
    }
}
