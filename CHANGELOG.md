## 0.2.0 (unreleased)

- Implement Android USB Host enumeration, descriptor access, permissions,
  connection management, interface/configuration selection and device events
  using JNI/JNIgen, without data transport.
- Keep blocking connection operations on independent per-connection queues;
  close connections on detach and engine shutdown/restart.
- Identify observed attachments privately by `deviceName-UUID`, retaining the
  UUID across enumerations without changing Android names or public list keys.
- Deduplicate attach/detach notifications, bind permission replies to attachment
  instances and report detach when enumeration detects absence. Unobserved
  same-name unplug/replug cycles cannot be distinguished.
- Add Android lifecycle/concurrency, attachment identity and permission tests
  across API 24, 31, 33 and 35, including plugin engine callbacks.
- Use Java for the Android plugin and example activity; keep Gradle Kotlin DSL.
- Provide a launcher-started USB Host diagnostic example with its own namespace
  and fake-backed widget tests, without data transfers or USB launch filters.
- Document source responsibilities, reference ownership, synchronization,
  attachment lifecycle and operation/error contracts without changing behavior.
- Handle USB Activity launch/new intents through ActivityAware and the existing
  session registry; keep launch/recreation state silent, deduplicate broadcasts
  and remove Activity listeners independently of headless engine resources.
- Document consumer-owned USB launch filters and extend Activity lifecycle tests.

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
