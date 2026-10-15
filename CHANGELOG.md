## 0.1.0 (unreleased)

- Declare the Android USB Host API in Dart, excluding `UsbAccessory` and
  `Parcelable` serialization.
- Include all 33 Android USB protocol constants and four host manager constants.
- Declare five Windows pipe operations and nine WinUSB pipe policy constants.
- Use abstract declarations and placeholders marked `NOT IMPLEMENTED YET`;
  placeholders return default values or do nothing.
- Include a minimal Android compilation example with application ID
  `dev.jarekxxxxx.usb_host_proxy`.
- Configure private package use with `publish_to: none` and BSD-3-Clause licensing.
