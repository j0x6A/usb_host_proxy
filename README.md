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

## Lifecycle and errors

Use the engine's root Dart isolate. Managers share one session per engine.
Descriptor getters call JNI directly. Opening, serial reads and potentially
blocking management operations use Android workers; each connection has its own
ordered queue. File descriptor/raw descriptor reads are guarded against close.

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

## Bindings and tests

`tool/jnigen.dart` generates the committed private bindings from Android SDK
platform 36 and this plugin's Java sources:

```sh
dart run tool/jnigen.dart /path/to/Android/Sdk
```

The SDK path can instead come from `ANDROID_SDK_ROOT`. `JNIGEN_SUMMARIZER`
optionally selects a prebuilt ApiSummarizer command. Do not edit generated
bindings by hand. `jni` supplies the runtime; `jnigen` is a development tool.

Android unit tests are in `android/src/test/java`; the example widget test is in
`example/test`. Physical hardware checks should cover permission grant/refusal,
detach during pending work, same-port reattachment, multiple devices and
USB-triggered launch. The [example](example/README.md) only displays API names.

## References

- [Android USB Host](https://developer.android.com/develop/connectivity/usb/host)
- [Android USB API](https://developer.android.com/reference/android/hardware/usb/package-summary)
- [WinUSB pipe policies](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/winusb-functions-for-pipe-policy-modification)
