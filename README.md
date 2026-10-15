# usb_host_proxy

Dart declarations for Android's `android.hardware.usb` host API, excluding
`UsbAccessory` and Android parcel serialization, with Windows USB pipe extensions.

## Status

Version 0.1.0 is an unreleased API skeleton. Android and Windows backends are not
implemented or registered.

- `UsbDevice`, `UsbConfiguration`, `UsbInterface`, `UsbEndpoint`, and
  `UsbDeviceConnection` expose abstract methods without implementations.
- The static `UsbDevice` conversion methods and concrete `UsbManager` and
  `UsbRequest` members are placeholders marked `NOT IMPLEMENTED YET`.
- Placeholders return `false`, `null`, `-1`, an empty map, or an empty stream.
  Empty streams complete immediately. Void placeholders do nothing.
- `getClientData()` always returns `null`; `setClientData()` stores nothing.

The package does not perform USB I/O, enumerate devices, request permissions,
validate arguments, manage resource lifetimes, or maintain request state.
Descriptor classes have no public data fields or constructors for manually
creating descriptors. Default results do not establish platform behavior.

This package is currently private. `publish_to: none` disables publication to
pub.dev. Any future GitHub repository must remain private unless explicitly
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
entire Windows USB API. The declarations do not establish behavioral parity or
working USB access.

## Local tooling

Run these commands manually when dependency resolution or analysis is needed:

```sh
flutter pub get
flutter analyze
```

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
