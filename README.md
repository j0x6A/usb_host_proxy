# usb_host_proxy

Dart declarations for Android's `android.hardware.usb` host API, excluding
`UsbAccessory` and Android parcel serialization, with Windows USB pipe extensions.

## Status

Version 0.2.0 is an unreleased project in development.

| Area | Current state |
| --- | --- |
| Public Dart API | Existing signatures preserved |
| Android USB backend | Enumeration, descriptors, permissions, connection management and events |
| JNI | Original framework objects retained through JNI references |
| JNIgen | Generated private bindings; configuration in tool/jnigen.dart |
| Data transport | Not implemented: bulk/control transfers, UsbRequest and requestWait |
| Windows | API extensions declared; backend and platform registration planned |

Android implements the management/information methods in the existing API.
"All descriptors" means the framework device/configuration/interface/endpoint
tree and `getRawDescriptors()` after opening a device. Additional descriptor
requests using control transfers are outside this implementation.

`UsbRequest` remains a placeholder. Transport and WinUSB operations on Android
connections throw `UnsupportedError`. Non-Android manager/static conversion
placeholders retain their previous behavior; no Windows backend is added.

This package is currently private. `publish_to: none` disables publication to
pub.dev. The GitHub repository must remain private unless explicitly
authorized otherwise.

## Requirements

- Dart 3.13.5 or later, below 4.0.0.
- Flutter 3.47.7 or later.
- Android SDK and a compatible JDK to build the example APK.

## Local installation

Add a path dependency to your application's `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  usb_host_proxy:
    path: ../usb_host_proxy
```

Adjust the path to the package location, then run `flutter pub get`.

```dart
import 'package:usb_host_proxy/usb_host_proxy.dart';
```

## API coverage

The public library exports `UsbManager`, `UsbDevice`, `UsbConfiguration`,
`UsbInterface`, `UsbEndpoint`, `UsbDeviceConnection`, `UsbRequest`, and
`UsbConstants`. It includes all 33 Android `UsbConstants` values and the four
host-related `UsbManager` constants.

Windows extensions declare `resetPipe`, `abortPipe`, `flushPipe`, `setPipePolicy`,
and `getPipePolicy`, with the nine WinUSB pipe policy identifiers.

Adaptations from Java:

- Platform operation signatures use `Future`; device event signatures use
  `Stream`.
- `requestPermission` represents a permission decision as `Future<bool>` instead
  of exposing Android's `PendingIntent`.
- Named optional arguments represent overloaded transfer and request methods.
- Static device name/ID conversions use `getDeviceIdFromName` and
  `getDeviceNameFromId` to avoid conflicts with instance methods in Dart.
- `Uint8List` ranges and `UsbRequest.transferredLength` replace Java
  `ByteBuffer` position/limit state. Deprecated queue behavior is not reproduced.
- Android `Parcelable` serialization members are not exposed.

The Windows extensions cover these pipe operations and policies only, not the
entire Windows USB API. They do not establish a Windows backend.

## Android lifecycle and errors

Use `UsbManager` from the Flutter engine's root isolate. Managers share that
engine's session; engines do not share USB connections or listeners. Synchronous
descriptor getters read the original Java objects without caching their fields.
Opening, reading the serial number and management ioctls run on Android worker
threads. Mutating operations and serial reads on each connection are queued in
order, independently of other connections. File descriptor/raw descriptor reads
are direct JNI calls guarded against concurrent close.

`requestPermission` shares a single pending decision for a device attachment.
It returns false for refusal or detach, and fails if the engine session ends.
There is no imposed timeout. Video-class devices may additionally need the
application's CAMERA permission; the plugin does not request that permission.
`openDevice` never requests permission implicitly. Native false/null results are
preserved; Android exceptions remain JNI exceptions with their Java details.
Invalid ownership/arguments map to `ArgumentError`, and using a closed connection
or ended session maps to `StateError`.

Call and await `close()` for each opened connection. Close is idempotent and
waits for an in-flight operation on that connection. Device detach immediately
rejects further operations and queues native close. Engine destruction and hot
restart unregister receivers, settle pending calls and close all connections.
There is no Dart cache of permission, descriptor or configuration state.
Temporary JNI references are released immediately. Descriptor wrappers have no
public dispose method, so their escaping JNI references use native finalizers;
do not retain unbounded collections of obsolete enumeration results.

The event streams are broadcast streams without history. An attachment while
the engine is running produces `deviceAttached`; an attachment that starts the
application is initial state obtained with `getDeviceList()`, not a replayed
stream event. Automatic application launch requires the consuming application's
activity USB intent filter and device-filter metadata. This plugin does not
install a filter matching every USB device or change the app's launch policy.
Detached descriptors remain readable as native descriptor objects; permission
and serial-number reads can require a live attachment and Android authorization.

## Generation and verification

Generate committed private bindings using Android SDK platform 36:

```sh
dart run tool/jnigen.dart /path/to/Android/Sdk
```

Alternatively set `ANDROID_SDK_ROOT`. `JNIGEN_SUMMARIZER` optionally selects a
prebuilt JNIgen ApiSummarizer command. The generator uses the original SDK JAR
and this plugin's Java sources, without modifying Gradle files.

From `example/android`, run `./gradlew :usb_host_proxy:testDebugUnitTest`
(`gradlew.bat` on Windows). The example's widget test uses `flutter test`.
Hardware verification should cover grant/refusal, detach while a permission
dialog or operation is pending, same-port reattachment, multiple devices, and
both ordinary launch and USB-triggered launch.

## Local tooling

Run these commands manually when dependency resolution or analysis is needed:

```sh
flutter pub get
flutter analyze
```

`jni` supplies runtime Java interop; `jnigen` generates bindings during development.
`dart:ffi` is part of the Dart SDK. A direct dependency on `package:ffi` should
be added when this package starts importing its allocation or conversion helpers.

Keep Flutter `.metadata` files in version control: they describe project type
and migration history. Generated registration, build outputs, local SDK paths,
and editor files are ignored. The library lockfile is ignored; the example
lockfile records application dependency resolution. The example version is
currently aligned with the package version by convention, not automatically.
The example widget test checks the displayed compilation message. Android tests
cover lifecycle, permissions and operation queues.

## Example APK

The example contains one Dart source file, `example/lib/main.dart`, and the
Android runner required by Flutter. Its application ID is
`dev.jarekxxxxx.usb_host_proxy`.

```sh
cd example
flutter pub get
flutter build apk --debug
```

The APK is written to `example/build/app/outputs/flutter-apk/app-debug.apk`.
The app references all eight public API classes and displays a compilation
message. It does not enumerate devices, request permissions, or perform USB I/O.
An APK build checks that the declarations can be included in an Android app;
it does not verify USB behavior. Build the example manually when needed. Existing
build outputs may predate subsequent source edits.

## References

- [Android USB API](https://developer.android.com/reference/android/hardware/usb/package-summary)
- [WinUSB pipe policies](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/winusb-functions-for-pipe-policy-modification)

## License

BSD-3-Clause. See [LICENSE](LICENSE).
