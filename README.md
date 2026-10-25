# usb_host_proxy

Flutter plugin for Android USB Host management and transport through JNI/JNIgen.
Android integration is written in Java; Dart adapters retain references to the original
`android.hardware.usb` objects without caching their descriptor fields.

Version 0.2.0 is in development. The package and repository are private
(`publish_to: none`). License: BSD-3-Clause, see [LICENSE](LICENSE).

## Scope

- Device enumeration and device/configuration/interface/endpoint descriptors.
- USB permissions, opening/closing connections, claim/release interface,
  alternate settings and configuration selection.
- File descriptor, raw descriptors, serial numbers and device name/ID conversion.
- Attach/detach events and engine lifecycle cleanup.
- Bulk/control transfers and asynchronous bulk/interrupt requests with native
  queue, cancel and request-wait operations (Android API 28+).

WinUSB methods on Android connections throw `UnsupportedError`.
The Windows backend is not implemented; its API declarations and the existing
non-Android placeholders remain unchanged. `UsbAccessory` and Parcelable
serialization are excluded. Additional descriptor requests can be issued
explicitly through `controlTransfer`; enumeration does not issue them automatically.

## Requirements and use

Dart >=3.13.5 <4.0.0, Flutter >=3.47.7 and Android API >=28 (Android 9).
Add the package to an application's `pubspec.yaml`:

```yaml
dependencies:
  usb_host_proxy:
    path: ../usb_host_proxy
```

Import `package:usb_host_proxy/usb_host_proxy.dart`. The public classes are
`UsbManager`, `UsbDevice`, `UsbConfiguration`, `UsbInterface`, `UsbEndpoint`,
`UsbDeviceConnection`, `UsbRequest` and `UsbConstants`.

## Code map and reading order

Start with the public Dart declarations, then follow an operation through the
adapter to Java. Descriptor reads bypass the Java management wrapper and call
the original framework object directly.

| Location | Responsibility |
| --- | --- |
| `lib/usb_host_proxy.dart`, `lib/src/usb_*.dart` | Public contracts, descriptor meanings, constants and unsupported placeholders. |
| `lib/src/android/android_usb.dart` | JNI reference ownership, Java-to-Dart errors, completion-to-Future conversion and event streams. |
| `lib/src/android/transfer_buffer.dart` | Dart slice/JNI integer bounds and partial IN copy-back, without native state. |
| `lib/src/android/bindings.g.dart`, `tool/jnigen.dart` | Generated JNI signatures and the explicit regeneration entry point; no hand-written backend policy. |
| `android/src/main/java/.../UsbHostProxy.java` | Attachment identities, permissions, live-device registry, native connection ownership and ordered work. |
| `android/src/main/java/.../UsbHostProxyPlugin.java` | Engine/Activity lifecycle and forwarding Activity intents; not USB descriptor or transport logic. |
| `android/src/test/java`, `example/` | Mock-backed backend/lifecycle tests and a manual USB Host diagnostic app with fake-backed widget tests. |

Within `UsbHostProxy`, `Session` is the engine owner, `Device` represents one
observed attachment and `Connection` owns one open native connection. `Permission`
coalesces callers awaiting a decision; `Call` ensures a callback is settled at
most once, even if session cleanup wins a race with a worker. `Request` owns one
native UsbRequest and its pending buffer lease; `RequestResult` retains a completed
buffer and byte count until Dart decodes that result. Neither is a USB work queue.

When reading concurrency paths, distinguish the class lock (engine registry),
session lock (lifecycle state and pending callbacks), per-connection queue
(ordered native operations) and `readLock` (direct reads versus native close).
Code needing both session and connection locks acquires the session first.
Neither session disposal nor detach forcibly interrupts a native call already
running; cleanup schedules close and rejects subsequent queued access.

## Root isolate and operation dispatch

Use the engine's root Dart isolate. Managers share one session per engine.
Descriptor getters call JNI directly. Opening, serial reads and potentially
blocking management operations use Android workers; each connection has its own
ordered queue. File descriptor/raw descriptor reads are guarded against close.
`getDeviceList()` and `hasPermission()` still make synchronous framework calls
through JNI; a Future in the public signature does not move those calls to a worker.

## USB transport and buffers

`bulkTransfer`, `controlTransfer` and both `requestWait` variants run concurrently
on the existing `Session.workers`. They never occupy `Connection.queue`, which
continues to order management operations and native close. No per-interface
claim state, transfer queue, watchdog, retry or artificial timeout is added.
Native negative byte counts, false/null results and exceptions are preserved.

Offsets are relative to the supplied `Uint8List`, including views into a larger
allocation. Omitted length means the remaining slice. Invalid slices and values
outside a JNI int's range fail before allocation/narrowing. Null buffers require
offset/length zero. Android API 28+ has no library-imposed 16 KiB transport limit.
Bulk direction comes from the endpoint; control direction comes from requestType.
OUT data is copied at submission. IN copies only the completed prefix back to
the requested slice, leaving the remainder and neighboring bytes unchanged.
Do not mutate or reuse a buffer slice while its operation is pending.
IN destinations must be writable, not unmodifiable Dart views.

Synchronous transfers borrow a separate Java byte array until the worker returns;
the worker retains it even if engine shutdown has already failed the Dart future.
No Dart heap pointer is pinned or retained by native USB. Queued requests use a
Java-owned direct ByteBuffer retained through dequeue/close. The completion packet
retains its exact buffer and byte count independently of subsequent submissions.

Create `UsbRequest()`, initialize it with an original endpoint on an open connection,
then call `queue`. Its boolean is admission, not completion. `requestWait()` uses
Android's indefinite overload; `requestWait(timeout: n)` uses its timed overload,
where zero polls and a native timeout remains a Java TimeoutException. There is
no library polling loop. Requests from any endpoint of the connection may complete
first. The result is the original Dart request object, with its `transferredLength`
and IN bytes updated before delivery. Opaque `getClientData`/`setClientData` values
stay in Dart and retain object identity; native bookkeeping does not serialize them.

One request/buffer lease remains pending until its wait result is delivered;
reusing that request before delivery would overwrite in-flight buffer ownership.
`cancel()` forwards native acceptance and does not end the lease: collect its
completion with `requestWait` before reusing it. An already-closed request or a
connection being closed returns false from cancel without entering native cancel.
Close an initialized request before
reinitializing it. Explicit request close is idempotent and invalidates its pending
Dart copy-back, without fabricating a wait result. Connection close/detach/session
shutdown also close native requests. Close does not wait for blocking transport:
Android/kernel determine how already-entered I/O ends. No bounded wake-up guarantee
is added; permission and transport outcomes still require physical-device checks.
An internal Completion observes native connection cleanup without initiating it,
so detach/session end also discard outstanding Dart buffer leases and request
references even when the caller does not explicitly close the connection.

The diagnostic example remains management-only; it does not submit transfers.

## Management lifecycle and errors

`requestPermission` shares a pending decision for the same attachment. Refusal
or detach returns false; session termination fails pending calls. No timeout is
imposed. Video-class devices may additionally require the application's CAMERA
permission. `openDevice` never requests permission implicitly.

Native false/null results are preserved. Android exceptions retain their Java
details; invalid arguments/ownership map to `ArgumentError`, and closed
connections or ended sessions to `StateError`.

Await `close()` for each connection. Close is idempotent and drains accepted
management operations, immediately rejecting new work. It invokes native close without
individual interface releases. Even on a close error, the connection cannot be reused.
Detach rejects further operations and queues native close. Engine
destruction/hot restart unregister receivers, settle pending calls and close
connections. Temporary JNI references are released eagerly; escaping descriptor
references use native finalizers because the public API has no dispose method.

Event streams are broadcast streams without history. Attach while the engine is
running is an event; USB-triggered app launch is initial state obtained through
`getDeviceList()`. Automatic launch requires the consuming application's USB
intent filter and device-filter metadata. Detached descriptor objects remain
readable, but permission/serial reads can require a live authorized attachment.

Interface ownership is managed by Android and the kernel, not a library state
machine. `claimInterface`, `releaseInterface`, `setInterface` and `setConfiguration`
forward original descriptors and preserve native booleans and exceptions through
the error translation above. Repeated Claim, Release without prior Claim and
setting an alternate/configuration are not rejected based on operation history.
Force is forwarded unchanged and does not guarantee success. The library records
neither claims nor the active alternate setting; false/errors install no local
restrictions or automatic recovery. Operations retain the per-connection FIFO
queue, without release-specific admission blocking. Descriptor ownership and
connection/session lifecycle validation still apply before native access.

Each observed attachment has a private `deviceName-UUID` identity within the
engine session. Enumerations retain it; observed absence retires it and a later
presence receives a new UUID. Android device names and `getDeviceList()` keys
remain unchanged. Duplicate events do not create extra attachments; a detach
notification cannot retire a currently present name. Enumeration also reports
detach when it detects absence. A complete unplug/replug cycle under the same
name cannot be distinguished if Android provides no correlatable information
and no absence is observed; UUIDs do not remove that limitation.

## USB-triggered application launch

The consuming application owns the launch configuration, not the plugin.
Merge this USB filter and metadata into its existing Flutter Activity declaration
in `android/app/src/main/AndroidManifest.xml`. Keep its launcher filter, Flutter
metadata, themes and other attributes; adapt the Activity name to the application.
`singleTop` permits `onNewIntent()` when that Activity is already at the top of
the task; it does not guarantee reuse in every task/back-stack arrangement.

```xml
<activity
    android:name=".MainActivity"
    android:exported="true"
    android:launchMode="singleTop">
    <intent-filter>
        <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
    </intent-filter>
    <meta-data
        android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
        android:resource="@xml/device_filter" />
</activity>
```

Create `android/app/src/main/res/xml/device_filter.xml`. This is a template:
replace both placeholders with actual decimal VID/PID values for supported
hardware before using it. No device identifiers are supplied by this project.

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <usb-device vendor-id="DECIMAL_VID" product-id="DECIMAL_PID" />
</resources>
```

For a deliberately broader device family, Android also supports `class`,
`subclass` and `protocol` criteria. An attribute-free `usb-device` entry matches
all devices; use it only deliberately, as in the diagnostic example. See the [Android USB Host guide](https://developer.android.com/develop/connectivity/usb/host)
and [Activity launch modes](https://developer.android.com/guide/topics/manifest/activity-element#lmode).
The plugin manifest installs no launch filter. The diagnostic example deliberately
matches all USB devices and participates in Android's chooser/default-handler
mechanism. Accepting the system USB launch can grant permission until detach;
the example still does not automatically select, open or claim a device.

The plugin uses Flutter `ActivityAware` and the binding's new-intent listener;
no custom MainActivity override is required with the standard Flutter embedding.
If the application overrides `onNewIntent()`, it must retain Flutter's forwarding
by calling the superclass implementation. The plugin does not replace the
Activity's stored intent or automatically request USB permission.

Activity delivery follows the engine/session ownership boundary:

| Delivery or lifecycle change | Session and notification behavior |
| --- | --- |
| Initial `Activity.getIntent()` or Activity recreation | Reconcile silently; obtain initial devices through `getDeviceList()`. |
| `onNewIntent()` or USB broadcast | Use the same registry and attach flag; notify at most once per observed attachment. |
| Activity detach/configuration change | Remove the old listener; preserve the session, UUIDs and USB connections. |
| Engine restart | Replace the session, invalidate its old objects and pending work, retain the Activity registration. |
| Engine/plugin shutdown | Remove the Activity listener and dispose the session, including its receivers and pending work. |

Initial intent handling consumes any later duplicate attach notification for
that observed attachment; it cannot retract a broadcast already delivered.
Both paths verify live presence, so a saved intent cannot restore an absent
device. A listener result of true means a readable USB attach payload was
recognized, not necessarily that a device was present or an event was emitted.
Unrelated actions and missing/unreadable device payloads are not handled.
Headless engines retain broadcast/discovery support without an Activity.

## Bindings and tests

`tool/jnigen.dart` generates the committed private bindings from Android SDK
platform 36 and this plugin's Java sources:

```sh
dart run tool/jnigen.dart /path/to/Android/Sdk
```

The SDK path can instead come from `ANDROID_SDK_ROOT`. `JNIGEN_SUMMARIZER`
optionally selects a prebuilt ApiSummarizer command. Do not edit generated
binding code by hand. `jni` supplies the runtime; `jnigen` is a development tool.
If Windows Java diagnostics use a non-UTF-8 code page, the existing
`JNIGEN_SUMMARIZER` override can run the cached summarizer with UTF-8 output:
`java -Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8 -jar .dart_tool/jnigen/ApiSummarizer.jar`.

Android unit test sources in `android/src/test/java` target API 28, 31, 33 and 35
to cover the permission PendingIntent and receiver API branches. They use
Robolectric and mocked USB objects; they cover attachment identity, duplicate
events, permission replies, ownership, connection queues and cleanup. Interface
tests cover native true/false/error forwarding, repeated operations, original
alternate descriptors, independent connections, FIFO ordering, foreign descriptor
rejection, close failures and detach before queued Release reaches Android.
`UsbHostProxyPluginTest` checks engine attach, restart, destruction and plugin
detach using a mocked Flutter engine, without starting the Flutter runtime. It
also checks initial/new Activity intents, both Intent/broadcast delivery orders,
invalid payloads, stale intents/listeners and Activity configuration changes.
`UsbTransportTest` checks native bulk/control arguments and results, request
initialization/queue/cancel/wait/close, partial buffers, zero-length requests,
foreign endpoints, native timeouts/errors, parallel workers, blocked wait versus
cancel/close, detach and exactly-once session-shutdown completion.

Widget tests in `example/test` exercise the diagnostic UI using a fake manager,
including None selectors, force forwarding, fixed section geometry, unlimited
console history, unconditional end scrolling, Clear, cleanup and late results.
The raw/descriptor panels scroll independently; USB state changes replace data
and enabled callbacks rather than adding/removing sections. Tests compare panel
dimensions, section positions and retained scroll-position objects, not only text.
The console builds rows lazily while retaining the complete message history;
tests also cover multiline end scrolling and independent raw/descriptor panel
offsets after offscreen destruction and recreation. Logging still rebuilds the
screen, including its synchronous descriptor reads; lazy rows do not isolate
those reads or bound the memory occupied by stored messages.
Widget tests do not execute JNI. There is currently no automated Dart-to-JNI
integration test or physical-device test; Java tests do not verify JNI reference
ownership, Dart error mapping or real Android USB
behavior. The [example](example/README.md) supports manual management checks on
Android hardware without transfers or configuration changes, with a broad USB
launch filter. The example README lists test commands and their verification boundary.

On-device verification remains necessary for JNI descriptors/list keys and
callbacks, permission grant/refusal, detach during pending work, same-name
reattachment, independent devices, engine restart and USB-triggered launch.
These are verification scenarios, not claims of completed hardware testing.
Pure Dart tests in `example/test/transfer_buffer_test.dart` cover slice/view bounds,
unsigned byte copy-back, partial results, JNI integer bounds and unchanged
non-Android request placeholders. They do not verify the JNI callback or direct
buffer lifetime on hardware. On a device, also check IN/OUT bulk and control,
short transfers, buffers above 16 KiB, multiple interrupt requests, cancellation,
timed/indefinite waits and unplug/close while I/O is blocked.

## References

- [Android USB Host](https://developer.android.com/develop/connectivity/usb/host)
- [Android USB API](https://developer.android.com/reference/android/hardware/usb/package-summary)
- [WinUSB pipe policies](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/winusb-functions-for-pipe-policy-modification)
