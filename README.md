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
The Windows backend is not implemented; its API declarations and the existing
non-Android placeholders remain unchanged. `UsbAccessory` and Parcelable
serialization are excluded. Additional descriptor requests using control
transfers are outside this implementation.

## Requirements and use

Dart >=3.13.5 <4.0.0, Flutter >=3.47.7 and Android API >=24.
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
| `android/src/main/java/.../UsbHostProxy.java` | Attachment identities, permissions, live-device registry, native connection ownership and ordered work. |
| `android/src/main/java/.../UsbHostProxyPlugin.java` | Engine/Activity lifecycle and forwarding Activity intents; not USB descriptor or transport logic. |
| `android/src/test/java`, `example/` | Mock-backed backend/lifecycle tests and a manual USB Host diagnostic app with fake-backed widget tests. |

Within `UsbHostProxy`, `Session` is the engine owner, `Device` represents one
observed attachment and `Connection` owns one open native connection. `Permission`
coalesces callers awaiting a decision; `Call` ensures a callback is settled at
most once, even if session cleanup wins a race with a worker.

When reading concurrency paths, distinguish the class lock (engine registry),
session lock (lifecycle state and pending callbacks), per-connection queue
(ordered native operations) and `readLock` (direct reads versus native close).
Code needing both session and connection locks acquires the session first.
Neither session disposal nor detach forcibly interrupts a native call already
running; cleanup schedules close and rejects subsequent queued access.

## Lifecycle and errors

Use the engine's root Dart isolate. Managers share one session per engine.
Descriptor getters call JNI directly. Opening, serial reads and potentially
blocking management operations use Android workers; each connection has its own
ordered queue. File descriptor/raw descriptor reads are guarded against close.
`getDeviceList()` and `hasPermission()` still make synchronous framework calls
through JNI; a Future in the public signature does not move those calls to a worker.

`requestPermission` shares a pending decision for the same attachment. Refusal
or detach returns false; session termination fails pending calls. No timeout is
imposed. Video-class devices may additionally require the application's CAMERA
permission. `openDevice` never requests permission implicitly.

Native false/null results are preserved. Android exceptions retain their Java
details; invalid arguments/ownership map to `ArgumentError`, and closed
connections or ended sessions to `StateError`.

Await `close()` for each connection. Close is idempotent and drains accepted
operations. Detach rejects further operations and queues native close. Engine
destruction/hot restart unregister receivers, settle pending calls and close
connections. Temporary JNI references are released eagerly; escaping descriptor
references use native finalizers because the public API has no dispose method.

Event streams are broadcast streams without history. Attach while the engine is
running is an event; USB-triggered app launch is initial state obtained through
`getDeviceList()`. Automatic launch requires the consuming application's USB
intent filter and device-filter metadata. Detached descriptor objects remain
readable, but permission/serial reads can require a live authorized attachment.

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
`subclass` and `protocol` criteria. Do not use an attribute-free `usb-device`
entry: it matches all devices. See the [Android USB Host guide](https://developer.android.com/develop/connectivity/usb/host)
and [Activity launch modes](https://developer.android.com/guide/topics/manifest/activity-element#lmode).
Neither the plugin manifest nor the diagnostic example installs a launch filter.

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

Android unit test sources in `android/src/test/java` target API 24, 31, 33 and 35
to cover the permission PendingIntent and receiver API branches. They use
Robolectric and mocked USB objects; they cover attachment identity, duplicate
events, permission replies, ownership, connection queues and cleanup.
`UsbHostProxyPluginTest` checks engine attach, restart, destruction and plugin
detach using a mocked Flutter engine, without starting the Flutter runtime. It
also checks initial/new Activity intents, both Intent/broadcast delivery orders,
invalid payloads, stale intents/listeners and Activity configuration changes.

Widget tests in `example/test` exercise the diagnostic UI using a fake manager,
including cleanup and late results. They do not execute JNI. There is currently
no automated Dart-to-JNI integration test or physical-device test; Java tests do
not verify JNI reference ownership, Dart error mapping or real Android USB
behavior. The [example](example/README.md) supports manual management checks on
Android hardware without transfers, configuration changes or USB launch filters.

On-device verification remains necessary for JNI descriptors/list keys and
callbacks, permission grant/refusal, detach during pending work, same-name
reattachment, independent devices, engine restart and USB-triggered launch.
These are verification scenarios, not claims of completed hardware testing.

## References

- [Android USB Host](https://developer.android.com/develop/connectivity/usb/host)
- [Android USB API](https://developer.android.com/reference/android/hardware/usb/package-summary)
- [WinUSB pipe policies](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/winusb-functions-for-pipe-policy-modification)
