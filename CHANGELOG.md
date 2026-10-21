## 0.2.0 (unreleased)

- Implement Android USB Host enumeration, descriptor access, permissions,
  connection management, interface/configuration selection and device events
  using JNI/JNIgen, without data transport.
- Keep blocking connection operations on independent per-connection queues;
  close connections on detach and engine shutdown/restart.
- Add Android lifecycle/concurrency unit tests.

- Convert the package to an Android Flutter plugin with a registration skeleton.
- Add JNI runtime and JNIgen development dependencies for planned Java interop.
- Remove MethodChannel template code and its obsolete tests and dependencies.
- Keep one example MainActivity and use Gradle namespace for the library manifest.
- Give the example a separate namespace while preserving its application ID.
- Adapt the example widget test and document the current development status.

## 0.1.0

- Declare the Android USB Host API in Dart, excluding `UsbAccessory` and
  `Parcelable` serialization.
- Include all 33 Android USB protocol constants and four host manager constants.
- Declare five Windows pipe operations and nine WinUSB pipe policy constants.
- Use abstract declarations and placeholders marked `NOT IMPLEMENTED YET`;
  placeholders return default values or do nothing.
- Include a minimal Android compilation example with application ID
  `dev.jarekxxxxx.usb_host_proxy`.
- Configure private package use with `publish_to: none` and BSD-3-Clause licensing.
