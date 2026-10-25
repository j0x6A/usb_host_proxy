# usb_host_proxy

A Flutter plugin for discovering and managing Android USB Host devices. It can
read device information, request permission, open connections and manage USB
interfaces. **It does not transfer application data.**

The Android implementation uses Java and JNI. JNI lets Dart call Android classes;
JNIgen generates the private bindings for those calls. Dart objects retain
references to Android USB objects rather than copying their descriptor fields.

Version 0.2.0 is in development. The package is not configured for publication
to pub.dev (`publish_to: none`). License: [BSD-3-Clause](LICENSE).

## What works

All management and information operations declared by this package's Android
Host API have implementations:

| Task | Public API |
| --- | --- |
| Discover devices | `UsbManager.getDeviceList()` |
| Read device/configuration/interface/endpoint information | `UsbDevice`, `UsbConfiguration`, `UsbInterface`, `UsbEndpoint` getters |
| Check/request access | `hasPermission()`, `requestPermission()` |
| Open/close connections | `openDevice()`, `UsbDeviceConnection.close()` |
| Manage interfaces and settings | `claimInterface()`, `releaseInterface()`, `setInterface()`, `setConfiguration()` |
| Read connection information | `getFileDescriptor()`, `getRawDescriptors()`, `getSerial()` |
| Read device serial or convert Android names/IDs | `getSerialNumber()`, `getDeviceIdFromName()`, `getDeviceNameFromId()` |
| Receive device events | `deviceAttached`, `deviceDetached` streams |

This is the implemented scope, not a claim of complete hardware or test coverage.
Descriptor access covers Android's USB classes and the raw bytes returned by
Android; additional descriptor requests through control transfers are not implemented.

- `bulkTransfer()`, `controlTransfer()` and `requestWait()` fail with
  `UnsupportedError` on Android.
- `UsbRequest` is a placeholder on every platform: getters return null,
  initialize/queue/cancel return false, and client-data setters/close do nothing.
  It does not access buffers or submit native requests.
- The Windows backend is not implemented. WinUSB methods fail with
  `UnsupportedError` on Android; other platforms retain their placeholders.
- `UsbAccessory` and Android Parcelable serialization are outside this API.

## Requirements and installation

Use Dart >=3.13.5 <4.0.0, Flutter >=3.47.7, and an Android device running API 28
(Android 9) or later with USB Host/OTG support. Add the local plugin to your app:

```yaml
dependencies:
  usb_host_proxy:
    path: ../usb_host_proxy
```

Use USB from the engine's root Dart isolate: the isolate started by Flutter,
normally running your UI. Managers in that engine share one session; creating
another manager does not create another registry.
Additional Dart isolates are not supported.

## Basic workflow

Import `package:usb_host_proxy/usb_host_proxy.dart`, then enumerate devices in an
async UI action. Let the user choose one, check permission, then open it.
The map keys are Android device names:

```dart
final manager = UsbManager();
final devices = await manager.getDeviceList();
```

If permission is needed, call `await manager.requestPermission(device)` from an
explicit user action. Android may show a dialog; refusal or observed detach
returns false. Enumeration and opening never request permission implicitly.
Device-class policy can also require application permissions such as CAMERA for
video devices; the plugin does not request those.

This function reads information for a chosen, authorized device and always closes
the connection it opens:

```dart
import 'package:flutter/foundation.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

Future<void> readConnectionInfo(UsbManager manager, UsbDevice device) async {
  if (!await manager.hasPermission(device)) {
    debugPrint('USB permission is required.');
    return;
  }

  final connection = await manager.openDevice(device);
  if (connection == null) {
    debugPrint('Android could not open the device.');
    return;
  }

  try {
    debugPrint('FD: ${await connection.getFileDescriptor()}');
    final descriptors = await connection.getRawDescriptors();
    debugPrint(
      descriptors == null
          ? 'Raw descriptors are unavailable.'
          : 'Raw descriptors: ${descriptors.length} bytes',
    );
  } finally {
    await connection.close();
  }
}
```

An unplug or Android error can fail an awaited call. Handle exceptions in your
screen, subscribe to device events and cancel subscriptions on disposal. The
[diagnostic example](example/README.md) demonstrates selection, permissions,
cleanup and visible errors without transfers.

## Devices, descriptors and connections

A **device** describes USB hardware. A **connection** is an opened native resource
that you must close. Reading a descriptor does not open a connection, claim an
interface or change a setting.

Configurations contain interface descriptors; interfaces contain endpoint
descriptors. Each interface descriptor represents an interface number and one
alternate setting. Getter arguments are zero-based list indices, which are not
necessarily configuration values, interface IDs or endpoint addresses.

`UsbDevice.getInterface()` lists interfaces across configurations. Use
`getConfiguration(i).getInterface(j)` when walking a particular configuration.

Device identity follows Android's `deviceName`, with no private device UUID or
generation number. Android device adapters preserve Android equality/hashing,
so views with the same name compare equal. Names may be reused after disconnection and
are not permanent hardware identifiers. Comparisons to strings or custom Dart
device implementations return false.

Views remain valid while that device stays in Android's observed list. Detach,
observed absence or engine shutdown permanently invalidates every saved device,
configuration, interface and endpoint view. Their JNI references are released;
implemented reads/operations then fail with `StateError`. Only the immutable
device name, equality and Android-compatible hash remain usable without JNI.
Enumerate again for a new view after reconnecting. Equal names/hashes do not
revive an old object. Objects from another engine or implementation are rejected.

## Operation results and close

Native true/false/null results remain results. Exceptions are not changed into
false: Java argument failures become `ArgumentError`, state failures become
`StateError`, and other Java exceptions retain their details.

A result already completed by Java is preserved even if Dart receives it after
detach. It reports the completed operation, not continued device availability.
New native access through an invalidated view still fails with `StateError`.
A non-null Open result is not adopted after invalidation; Java owns its cleanup.

Claim, Release and setting selection go directly to Android. There is no local
claim-state machine, automatic recovery, prior-Claim requirement or check that a
descriptor reference occurs in the connection's descriptor tree. Arguments must
still be Android adapters so their native references can be passed through JNI.
`force` is forwarded unchanged and does not guarantee a successful Claim.

Management calls may run concurrently, even on the same connection. They have
**no guaranteed submission order (FIFO)**. Await a result before submitting an
operation that depends on it. Enumeration, permission checks, descriptor getters
and FD/raw reads still call JNI synchronously; a Future signature does not itself
move work off the isolate.

`close()` immediately rejects new connection operations and prevents pending
work from starting native access. It waits only for calls already allowed to
start, including direct information reads, then calls native close once without
individual Release calls. It does not drain older worker tasks or wait for their
Dart callback delivery. A native call that does not return can prevent close from
finishing; there is no extra timeout or forced interruption.

Repeated close is safe. Even if native close fails, that connection cannot be
reused; the failure reaches callers awaiting that attempt and is not replayed to
later close calls. Releasing a JNI reference is not a substitute for native close.

## Device events and cleanup

Use `getDeviceList()` for initial state and `deviceAttached`/`deviceDetached` for
changes. Streams do not replay earlier events. Enumeration can also detect a
missing name and trigger cleanup.

Activity intents and broadcasts share attach deduplication by name. A stored
initial Activity intent is handled silently; a runtime new intent may emit an
attach event. Enumeration alone does not synthesize attach.

Android detach is authoritative: it closes connections and cancels pending
permission/open work for that name, even if the latest list contains it again.
`deviceDetached` means invalidation and the start of cleanup, not that native
close has finished. Its payload has no JNI handles; use `getDeviceName()` for
identification. Cleanup runs without stream subscribers. The manager and system
event receivers remain active even when no devices are present.
If a newer view of a same-name device has already reached Dart, a queued detach
for the old view is not forwarded to subscribers; it must not clear the newer
selection or close the newer connection.

A late native open result is closed before reporting the failed open. Session
shutdown fails pending calls immediately and still cleans late results. Name
reuse never revives a closed connection or cancelled operation.

Already-admitted native calls retain local references until they return; close
uses the existing connection lifetime lock before releasing native resources.
The library releases references it owns; Android or the application may retain
their own descriptor snapshots. It cannot erase caller-held Dart variables or
copies of raw descriptor bytes/FD integers. Old wrappers are inert, and a copied
FD no longer grants valid use after close. If no system event is received,
absence is detected by the next enumeration; no polling mechanism is added.

The plugin follows Android's events. Without additional Android information it
cannot distinguish an old delayed detach from a new detach for the same reused
name, and it does not infer hidden reconnects from descriptor changes.

## Optional USB-triggered application launch

The consuming application owns the launch configuration. The plugin manifest
declares USB Host support as optional and installs no launch filter. To join
Android's USB app chooser, merge this filter and metadata into the existing
Flutter Activity. Keep its launcher filter, Flutter metadata, themes and other
required attributes; adapt the Activity name to your application:

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

Create `android/app/src/main/res/xml/device_filter.xml`. Replace both placeholders
with actual decimal VID/PID values before using this template:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <usb-device vendor-id="DECIMAL_VID" product-id="DECIMAL_PID" />
</resources>
```

Android also supports class/subclass/protocol criteria. An attribute-free
`<usb-device />` matches every device; the diagnostic example intentionally uses
that broad filter, but the plugin does not impose it on consumers.

Android controls the chooser, remembered default handler and permission grant.
Choosing the app can grant permission until detach; it does not make the plugin
select, open or claim a device. `singleTop` permits reuse at the top of the task,
not in every back-stack arrangement. If you override `onNewIntent()`, call the
superclass so Flutter can forward it. Engines without an Activity retain
enumeration and broadcast support.

See the [Android USB Host guide](https://developer.android.com/develop/connectivity/usb/host)
and [Activity launch modes](https://developer.android.com/guide/topics/manifest/activity-element#lmode).

## Tests and verification limits

| Area | Automated checks | Remaining JNI/device verification |
| --- | --- | --- |
| Discovery/events | Java tests cover views, name reuse, missing devices, deduplication, Activity intents and lifecycle. | Real list keys, callbacks and USB chooser behavior. |
| Permissions | Java tests cover coalescing, grant/refusal, old views, late replies, session isolation and errors. | System dialogs, device-class permissions and OEM behavior. |
| Connections/management | Java tests cover native results/errors, concurrent calls, close exclusion, late opens and cleanup. | Actual kernel/device behavior, settings and resource teardown. |
| Descriptor getters/equality | Getters read JNI; name/hash survive invalidation. Widget tests use fake descriptors. | JNI values, equality/hash and name/ID conversion. |
| Resource ownership | Java tests check shared invalidation; Dart helper tests check cascading release, close completion and errors without JNI. | Actual JNI reference deletion and cleanup on a device. |
| Diagnostic UI | Widget tests cover selection, cleanup, late results, fixed layout, log colors/history/scrolling and Clear. | Physical-device interaction. |
| Request placeholders | Tests check null/false/no-op results without native/buffer access. | Transport is not implemented or verified. |

Robolectric tests run against API 28, 31, 33 and 35 with mocked USB objects.
Widget tests use fake public interfaces. Neither suite executes Dart-to-JNI USB
integration. There is no full branch/API-coverage measurement or automated
physical-device suite; passing tests do not establish complete hardware support
or JNI ownership/error-conversion correctness.

In particular, automated tests do not exercise every descriptor getter through
JNI, the real permission dialog, native name/ID conversion or physical unplug
during a native call. The ownership-helper tests check release callbacks, not
the JVM's actual reference deletion. These are verification gaps, not additional
implemented features. Use the example's manual checklist on Android hardware.

With dependencies and tooling already installed, run:

```powershell
# Repository root
flutter analyze --no-pub

# example/
flutter test --no-pub
flutter analyze --no-pub

# example/android/
.\gradlew.bat :usb_host_proxy:testDebugUnitTest --offline --console=plain --no-daemon
```

The Java task compiles library/test code, not an example APK. Offline mode needs
cached dependencies. Manual hardware scenarios are in the [example README](example/README.md).

## Working on the plugin

Read [the Android backend guide](doc/android_backend.md) for the source map,
resource ownership, synchronization, Activity lifecycle and JNI regeneration.
The library compiles against API 36; library and example both require API 28.
The example inherits `compileSdk`/`targetSdk` from Flutter. Consuming applications
choose their own `targetSdk`.

Android API reference: [android.hardware.usb](https://developer.android.com/reference/android/hardware/usb/package-summary).
