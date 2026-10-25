# usb_host_proxy

Flutter plugin for Android USB Host management through JNI/JNIgen. Android
integration is written in Java; Dart adapters retain references to the original
`android.hardware.usb` objects without caching their descriptor fields.

Version 0.2.0 is in development. The package and repository are private
(`publish_to: none`). License: BSD-3-Clause, see [LICENSE](LICENSE).

## Scope

- Device enumeration and device/configuration/interface/endpoint descriptors.
- USB permissions, opening/closing connections, claim/release interface,
  alternate settings and configuration selection.
- File descriptor, raw descriptors, serial numbers and device name/ID conversion.
- Attach/detach events and engine lifecycle cleanup.

Bulk/control transfers, `UsbRequest` and `requestWait` are not implemented.
Transport and WinUSB methods on Android connections throw `UnsupportedError`.
`UsbRequest` is a platform-independent placeholder: getters return null,
initialize/queue/cancel return false, and client-data setters/close do nothing.
No buffer is inspected, no request is initialized and no transfer is submitted.
The Windows backend is not implemented; its API declarations and the existing
non-Android placeholders remain unchanged. `UsbAccessory` and Parcelable
serialization are excluded. Additional descriptor requests using control
transfers are outside this implementation.

## Requirements and use

Dart >=3.13.5 <4.0.0, Flutter >=3.47.7 and Android API >=28 (Android 9).
The library compiles against API 36. The example inherits `compileSdk` and
`targetSdk` from Flutter while explicitly setting `minSdk` to 28. The plugin
does not set the consuming application's `targetSdk`; that remains an application
setting. The minimum supported device API and the target API are separate values.
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
| `lib/src/android/bindings.g.dart`, `tool/jnigen.dart` | Generated JNI signatures and the explicit regeneration entry point; no hand-written backend policy. |
| `android/src/main/java/.../UsbHostProxy.java` | Device-name bookkeeping, permissions, shared workers and native connection lifetime. |
| `android/src/main/java/.../UsbHostProxyPlugin.java` | Engine/Activity lifecycle and forwarding Activity intents; not USB descriptor or transport logic. |
| `android/src/test/java`, `example/` | Mock-backed backend/lifecycle tests and a manual USB Host diagnostic app with fake-backed widget tests. |

Within `UsbHostProxy`, `Session` is the engine owner, `Device` retains a framework
descriptor view and `Connection` owns one open native connection. `Permission`
coalesces callers awaiting a decision; `Call` ensures a callback is settled at
most once, even if session cleanup wins a race with a worker.

When reading concurrency paths, distinguish the class lock (engine registry),
session lock (lifecycle state and pending callbacks) and each connection's
read/write lifetime lock (parallel native operations versus exclusive native
close). Close marks admission closed under the session lock, then a worker waits
for exclusive native access without holding the session lock. Native access is
released before completion callbacks or close bookkeeping acquire the session
lock. Neither session disposal nor detach forcibly interrupts an admitted call;
cleanup schedules close and invalidates operations not yet admitted.

## Lifecycle and errors

Use the engine's root Dart isolate. Managers share one session per engine.
The existing single-root-isolate initialization and single Java event listener
are retained. No background-isolate binding, listener fan-out or cross-isolate
JNI-reference ownership is introduced.
Descriptor getters call JNI directly. Opening, serial reads and potentially
blocking management operations use the session's existing worker pool. There
are no per-connection queues or FIFO guarantees; callers must await operations
whose order matters. File descriptor/raw descriptor reads remain direct JNI
calls. All connection calls share lifetime protection against native close,
without serializing management calls against one another.
`getDeviceList()` and `hasPermission()` still make synchronous framework calls
through JNI; a Future in the public signature does not move those calls to a worker.
`Session.workers` remains necessary for open, device serial reads and permission
submission, connection management and close. Completion callbacks are also
shared by management operations and remain in use.

`requestPermission` shares a pending decision for the same Android name. Refusal
or detach returns false; session termination fails pending calls. No timeout is
imposed. Video-class devices may additionally require the application's CAMERA
permission. `openDevice` never requests permission implicitly.

Native false/null results are preserved. Android exceptions retain their Java
details; invalid arguments/ownership map to `ArgumentError`, and closed
connections or ended sessions to `StateError`.

Await `close()` for each connection. Close is idempotent and immediately rejects
new work and operations not yet admitted to native access. It invokes native close
without individual interface releases. Even on a close error, the connection
cannot be reused.
Native close waits only for admitted calls to return, not for older pending
worker tasks or callback delivery. It cannot overlap those native calls because
Android's management methods do not all share the framework close lock and
native close frees the connection object. This lifetime guard adds no USB
queue, timeout or cancellation policy. Detach also schedules native close. Engine
destruction/hot restart unregister receivers, settle pending calls and close
connections. Temporary JNI references are released eagerly; escaping descriptor
references use native finalizers because the public API has no dispose method.

Admission is the final lifecycle check while shared native access is held.
Invalidation prevents pending operations from entering Android, but their Futures
still settle through worker/callback scheduling. If an admitted native call does
not return, close cannot finish. No session monitor is held while close waits.

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
restrictions or automatic recovery. Operations share the session worker pool,
without FIFO ordering or release-specific admission blocking. Dart requires
Android descriptor adapters so their native references can be passed through JNI.
Java does not check reference identity against the connection's descriptor tree;
Android receives the supplied interface/configuration and decides the outcome.
Connection/session lifecycle and device-session ownership checks remain in place.

Android device adapters delegate `==` and `hashCode` to the framework's
`UsbDevice.equals()` and `hashCode()`. Two Android device adapters with the same
`deviceName` compare equal, including after name reuse or across sessions.
Equality is not a liveness or permission check. Comparisons to strings or custom
Dart device implementations
return false; the native Java `equals(String)` convenience is not exposed as
Dart equality because it would break symmetry with `String.==`.

Device identity follows Android's `deviceName`, with no private UUID, generation
counter or attachment lease. Older views from the same active session are valid
inputs to permission/open/serial calls; Android decides their result. Descriptor
fields still belong to the retained framework object and do not update by name.
Enumeration supplies the latest framework views without mutating older ones.
It does not infer a physical reconnection merely from a different Java object.

Attach delivery is deduplicated by name until observed absence or Android detach.
A detach is authoritative: connections for its name are closed even if a new
device is already present under that name in the latest list. Repeated detach
without intervening work is idempotent. Without an Android attachment token, a
late old detach cannot be distinguished from a new detach for a reused name;
the plugin follows Android's events instead of guessing. No unseen physical
unplug/replug cycle is reconstructed from descriptor fingerprints.

The UUID that remains in the permission reply action isolates callback routes
between engine sessions; it is not a USB identifier. Request codes identify
pending decisions, and detach cancels matching decisions by name. The removed
`deviceInstance` extra is unnecessary for correlation. Open attempts likewise
have operation lifetimes: detach invalidates the attempt, and any late native
connection is closed before its result is reported. Session shutdown settles
calls immediately and still cleans late native results. Name reuse never revives
a closed connection or an invalidated operation.

Enumeration reconciles names from event bookkeeping, connections, permissions
and pending opens. Shutdown closes all owned connections, including ones opened
using a saved device view before rediscovery. Neither path needs a device UUID.

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
| Activity detach/configuration change | Remove the old listener; preserve the session, notification flags and USB connections. |
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

Android unit test sources in `android/src/test/java` target API 28, 31, 33 and 35
to cover the permission PendingIntent and receiver API branches. They use
Robolectric and mocked USB objects; they cover name-based device views, duplicate
events, permission replies, device-session ownership, parallel management work
and cleanup. Interface tests cover native true/false/error forwarding, repeated
operations, original alternate descriptors, independent connections, concurrent
same-connection calls, forwarding of descriptors absent from the device registry,
close failures and rejection before native admission. Controlled worker starts
test close overtaking pending work; blocked native calls test lifetime protection
during close, detach and pool shutdown. Direct FD/raw reads also have tests that
hold native access while close is requested and verify rejection of later reads.
`UsbHostProxyPluginTest` checks engine attach, restart, destruction and plugin
detach using a mocked Flutter engine, without starting the Flutter runtime. It
also checks initial/new Activity intents, both Intent/broadcast delivery orders,
invalid payloads, stale intents/listeners and Activity configuration changes.

### Management coverage and limits

All management and information members declared by the Android-facing public
API have implementations. This is implementation coverage, not proof that every
branch or device behavior has been tested. The Windows pipe extensions,
`UsbAccessory` and Parcelable serialization are outside the Android Host scope.

| Area | Implementation and automated checks | Remaining verification |
| --- | --- | --- |
| Enumeration and names | Java tests preserve native views, refresh snapshots, reconcile absence and deduplicate notifications. | Dart list keys and JNI object lifetime on a device. |
| Device/configuration/interface/endpoint fields | Dart adapters call original Android getters; the example uses fake descriptors in widget tests. | Real JNI getter results, indices, optional strings and static name/ID conversion. |
| Permissions | Java tests cover name-based coalescing, grant/refusal, old/foreign views, late replies, session isolation, submission errors and cleanup. | System permission UI, class-specific permission policy and OEM behavior. |
| Open/Close and connection information | Java tests cover null/errors, late opens, serial values/errors, raw bytes/null/errors, FD results, close ordering and invalidation. | JNI byte-array conversion, error translation and real resource teardown. |
| Claim/Release and setting selection | Java tests verify native booleans/exceptions, force, original descriptors, parallel execution and independent connections. | Real kernel/device behavior, alternate settings and configuration changes; the example does not select settings. |
| Events and engine/Activity lifecycle | Java tests cover initial/new intents, broadcasts, deduplication, restart, listener removal and headless sessions. | Actual Flutter restart, USB app chooser and cold/warm launch on hardware. |

There is no full API or branch-coverage measurement. In particular, the
descriptor adapters (including device equality/hashing), static device-name
conversions, JNI finalizers and Dart exception mapping are not executed by the
mock-backed Java/widget suites.

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
ownership, Dart error mapping or real Android USB behavior.
The [example](example/README.md) supports manual management checks on
Android hardware without transfers or configuration changes, with a broad USB
launch filter. The example README lists test commands and their verification boundary.

On-device verification remains necessary for JNI descriptors/list keys and
callbacks, permission grant/refusal, detach during pending work, same-name
reattachment, independent devices, engine restart and USB-triggered launch.
These are verification scenarios, not claims of completed hardware testing.
For equality/hashing, compare adapters from consecutive enumerations and use
them as Set/Map keys. Older same-session views remain accepted inputs; Android
decides access, while previously closed connections remain unusable.
`example/test/usb_request_test.dart` checks placeholder return values, idempotent
no-op close and lack of buffer/native access. The withdrawn transport's buffer
helpers, request lifecycle tests and generated request/result bindings are removed.
The earlier close/active-transport issue remains outside this verification:
transport paths are absent, and the lifetime guard covers only implemented
management/information calls. Revisit transport ownership and close before
adding transfers or requests again.

## References

- [Android USB Host](https://developer.android.com/develop/connectivity/usb/host)
- [Android USB API](https://developer.android.com/reference/android/hardware/usb/package-summary)
- [WinUSB pipe policies](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/winusb-functions-for-pipe-policy-modification)
