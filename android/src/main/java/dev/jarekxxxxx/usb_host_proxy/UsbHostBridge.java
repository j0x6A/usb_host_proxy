package dev.jarekxxxxx.usb_host_proxy;

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

/** Lifecycle and asynchronous Android integration, not a copy of the USB model. */
public final class UsbHostBridge {
    private UsbHostBridge() {}

    private static final Map<Long, Session> sessions = new HashMap<>();

    static synchronized void attach(Context context, long engineId) {
        detach(engineId);
        sessions.put(engineId, new Session(context.getApplicationContext()));
    }

    static synchronized void detach(long engineId) {
        Session session = sessions.remove(engineId);
        if (session != null) session.dispose();
    }

    public static synchronized Session session(long engineId) {
        Session session = sessions.get(engineId);
        if (session == null) throw new IllegalStateException("USB engine is not attached");
        return session;
    }

    /** Rethrow on the calling JNI thread, preserving Android exception details. */
    public static void rethrowError(Throwable error) throws Throwable { throw error; }

    /** Implemented by Dart as a nonblocking JNIgen listener. */
    public interface Completion {
        void success(Object value);
        void failure(Throwable error);
    }

    /** Startup USB intents are initial state, not replayed attach events. */
    public interface Events {
        void attached(Device device);
        void detached(Device device);
        void disposed();
    }

    /** A reference to one physical attachment, invalidated even if its name is reused. */
    public static final class Device {
        public final UsbDevice usbDevice;
        private final Session owner;
        private boolean attached = true; // Session monitor owns this lifecycle flag.

        private Device(Session owner, UsbDevice device) {
            this.owner = owner;
            this.usbDevice = device;
        }

        public void serial(Completion completion) {
            owner.work(completion, () -> {
                synchronized (owner) { owner.checkDevice(this); }
                return usbDevice.getSerialNumber();
            });
        }
    }

    public static final class Session {
        private final Context context;
        private final UsbManager manager;
        private final String permissionAction;
        private final ExecutorService workers = Executors.newCachedThreadPool();
        private final Map<String, Device> devices = new HashMap<>();
        private final Set<Connection> connections = new HashSet<>();
        private final Set<Call> calls = new HashSet<>();
        private final Map<Integer, Permission> permissions = new HashMap<>();
        private int nextPermission = 0;
        private boolean active = true;
        private Events events;

        private final BroadcastReceiver usbReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                UsbDevice device = extraDevice(intent);
                if (device == null) return;
                if (UsbManager.ACTION_USB_DEVICE_ATTACHED.equals(intent.getAction())) {
                    onAttached(device);
                } else if (UsbManager.ACTION_USB_DEVICE_DETACHED.equals(intent.getAction())) {
                    onDetached(device);
                }
            }
        };

        private final BroadcastReceiver permissionReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                if (!permissionAction.equals(intent.getAction())) return;
                synchronized (Session.this) {
                    Permission pending = permissions.remove(intent.getIntExtra("request", -1));
                    if (pending == null || !active) return;
                    try {
                        UsbDevice reply = extraDevice(intent);
                        boolean granted = reply != null
                            && reply.getDeviceName().equals(pending.device.usbDevice.getDeviceName())
                            && pending.device.attached
                            && intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                            && manager.hasPermission(pending.device.usbDevice);
                        pending.finish(granted, null);
                    } catch (Throwable error) { pending.finish(null, error); }
                }
            }
        };

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

        public synchronized void listen(Events listener) {
            checkActive();
            if (events != null) throw new IllegalStateException("USB supports one Dart isolate per engine");
            events = listener;
        }

        private void checkActive() {
            if (!active) throw new IllegalStateException("USB session has ended");
        }

        private void checkDevice(Device device) {
            checkActive();
            if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
            if (!device.attached) throw new IllegalStateException("USB device is detached");
        }

        public synchronized Device[] deviceList() {
            checkActive();
            Map<String, UsbDevice> found = manager.getDeviceList();
            // A missed detach must not leave an open connection usable forever.
            for (Device old : new ArrayList<>(devices.values())) {
                if (!found.containsKey(old.usbDevice.getDeviceName())) retire(old);
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

        public synchronized boolean hasPermission(Device device) {
            checkActive();
            if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
            return device.attached && manager.hasPermission(device.usbDevice);
        }

        public synchronized void requestPermission(Device device, Completion completion) {
            Call call = new Call(this, completion);
            try {
                checkActive();
                if (device.owner != this) throw new IllegalArgumentException("Device belongs to another session");
                if (!device.attached) { call.finish(false, null); return; }
                if (manager.hasPermission(device.usbDevice)) { call.finish(true, null); return; }
                for (Permission permission : permissions.values()) {
                    if (permission.device == device) { permission.waiters.add(call); return; }
                }
                int request = ++nextPermission;
                Intent intent = new Intent(permissionAction).setPackage(context.getPackageName());
                intent.putExtra("request", request);
                int flags = PendingIntent.FLAG_CANCEL_CURRENT;
                if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_MUTABLE;
                PendingIntent pendingIntent = PendingIntent.getBroadcast(context, request, intent, flags);
                Permission permission = new Permission(device, pendingIntent, call);
                permissions.put(request, permission);
                workers.execute(() -> {
                    synchronized (Session.this) {
                        if (!active || !device.attached || !permissions.containsKey(request)) return;
                    }
                    try {
                        manager.requestPermission(device.usbDevice, pendingIntent);
                    } catch (Throwable error) {
                        synchronized (Session.this) {
                            if (permissions.remove(request) == permission) permission.finish(null, error);
                        }
                    }
                });
            } catch (Throwable error) {
                call.finish(null, error);
            }
        }

        public void open(Device device, Completion completion) {
            work(completion, () -> {
                synchronized (this) { checkDevice(device); }
                UsbDeviceConnection opened = manager.openDevice(device.usbDevice);
                if (opened == null) return null;
                synchronized (this) {
                    if (!active || !device.attached) {
                        opened.close();
                        throw new IllegalStateException("USB device or session ended while opening");
                    }
                    Connection connection = new Connection(this, device, opened);
                    connections.add(connection);
                    return connection;
                }
            });
        }

        private synchronized void work(Completion completion, Callable<Object> operation) {
            Call call = new Call(this, completion);
            if (!active) { call.finish(null, new IllegalStateException("USB session has ended")); return; }
            workers.execute(() -> {
                try { call.finish(operation.call(), null); }
                catch (Throwable error) { call.finish(null, error); }
            });
        }

        private synchronized void onAttached(UsbDevice usbDevice) {
            if (!active) return;
            // Enumeration can win the race with delivery of this same attach broadcast.
            Device device = devices.get(usbDevice.getDeviceName());
            if (device == null) {
                device = new Device(this, usbDevice);
                devices.put(usbDevice.getDeviceName(), device);
            }
            if (events != null) {
                try { events.attached(device); }
                catch (RuntimeException error) { Log.w("UsbHostProxy", "USB listener unavailable", error); }
            }
        }

        private synchronized void onDetached(UsbDevice usbDevice) {
            if (!active) return;
            Device device = devices.get(usbDevice.getDeviceName());
            if (device == null) device = new Device(this, usbDevice);
            retire(device);
            if (events != null) {
                try { events.detached(device); }
                catch (RuntimeException error) { Log.w("UsbHostProxy", "USB listener unavailable", error); }
            }
        }

        private void retire(Device device) {
            device.attached = false;
            devices.remove(device.usbDevice.getDeviceName());
            for (Map.Entry<Integer, Permission> entry : new ArrayList<>(permissions.entrySet())) {
                if (entry.getValue().device == device) {
                    permissions.remove(entry.getKey());
                    entry.getValue().finish(false, null);
                }
            }
            for (Connection connection : new ArrayList<>(connections)) {
                if (connection.device == device) connection.close(null);
            }
        }

        private synchronized void dispose() {
            if (!active) return;
            active = false;
            context.unregisterReceiver(usbReceiver);
            context.unregisterReceiver(permissionReceiver);
            for (Permission permission : permissions.values()) permission.finish(null, new IllegalStateException("USB session has ended"));
            permissions.clear();
            for (Device device : new ArrayList<>(devices.values())) retire(device);
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

    private static UsbDevice extraDevice(Intent intent) {
        if (Build.VERSION.SDK_INT >= 33) return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice.class);
        return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
    }

    private static final class Permission {
        final Device device;
        final PendingIntent intent;
        final ArrayList<Call> waiters = new ArrayList<>();

        Permission(Device device, PendingIntent intent, Call first) {
            this.device = device;
            this.intent = intent;
            waiters.add(first);
        }

        void finish(Object value, Throwable error) {
            intent.cancel();
            for (Call call : waiters) call.finish(value, error);
            waiters.clear();
        }
    }

    private static final class Call {
        final Session owner;
        Completion completion;

        Call(Session owner, Completion completion) {
            this.owner = owner;
            this.completion = completion;
            owner.calls.add(this);
        }

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

    /** Owns exactly one original connection and its own operation queue. */
    public static final class Connection {
        private final Session owner;
        private final Device device;
        private final ExecutorService queue = Executors.newSingleThreadExecutor();
        private final Object readLock = new Object();
        private UsbDeviceConnection connection;
        private boolean closing = false;
        private boolean closed = false;
        private final ArrayList<Call> closeWaiters = new ArrayList<>();

        private Connection(Session owner, Device device, UsbDeviceConnection connection) {
            this.owner = owner;
            this.device = device;
            this.connection = connection;
        }

        private void checkOpen() {
            if (closing) throw new IllegalStateException("USB connection is closed or detached");
        }

        public int fileDescriptor() {
            synchronized (readLock) { checkOpen(); return connection.getFileDescriptor(); }
        }

        public byte[] rawDescriptors() {
            synchronized (readLock) { checkOpen(); return connection.getRawDescriptors(); }
        }

        private void submit(Completion completion, Callable<Object> operation) {
            synchronized (owner) {
                Call call = new Call(owner, completion);
                synchronized (readLock) {
                    if (closing) { call.finish(null, new IllegalStateException("USB connection is closed or detached")); return; }
                    queue.execute(() -> {
                        try {
                            // Explicit close drains accepted work; detach/session end
                            // invalidates queued work before it touches the device.
                            synchronized (owner) { owner.checkDevice(device); }
                            call.finish(operation.call(), null);
                        } catch (Throwable error) { call.finish(null, error); }
                    });
                }
            }
        }

        public void serial(Completion completion) { submit(completion, () -> connection.getSerial()); }

        private void checkInterface(UsbInterface intf) {
            for (int i = 0; i < device.usbDevice.getInterfaceCount(); i++) {
                if (device.usbDevice.getInterface(i) == intf) return;
            }
            throw new IllegalArgumentException("Interface belongs to another device attachment");
        }

        public void claim(UsbInterface intf, boolean force, Completion completion) {
            submit(completion, () -> { checkInterface(intf); return connection.claimInterface(intf, force); });
        }

        public void release(UsbInterface intf, Completion completion) {
            submit(completion, () -> { checkInterface(intf); return connection.releaseInterface(intf); });
        }

        public void selectInterface(UsbInterface intf, Completion completion) {
            submit(completion, () -> { checkInterface(intf); return connection.setInterface(intf); });
        }

        public void selectConfiguration(UsbConfiguration configuration, Completion completion) {
            submit(completion, () -> {
                for (int i = 0; i < device.usbDevice.getConfigurationCount(); i++) {
                    if (device.usbDevice.getConfiguration(i) == configuration) return connection.setConfiguration(configuration);
                }
                throw new IllegalArgumentException("Configuration belongs to another device attachment");
            });
        }

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
