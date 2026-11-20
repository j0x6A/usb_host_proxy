## 0.3.0

- Add Android bulk and control transfers on the session worker pool. The adapter
  forwards Android results and timeouts and copies only the selected buffer slice.
- Cover transfer parameters, results and lifetime in Java and across Dart/JNI
  with framework USB test doubles.

## 0.2.0

- Implement Android USB Host discovery, descriptor access, permissions,
  connection and interface management, and device events through JNI.
- Keep USB lifetimes and cleanup in Java per engine. Invalidate old descriptor
  views on detach, observed absence or session end, including when Android
  reuses a name. Preserve native operation results and descriptor semantics.
- Use shared workers for blocking connection operations and close. Reject
  unstarted work after close begins and wait for admitted work before freeing
  the connection.
- Support USB launch and runtime intents. Share attachment deduplication
  between Activity intents and broadcasts, and preserve the session across
  Activity recreation.
- Provide an Android API 28+ diagnostic example. Cover Android lifecycle and
  operation contracts with Robolectric and diagnostic UI behavior with Flutter.
- Reserve public API declarations for USB requests and Windows pipe operations.

## 0.1.0

- Declare the Android USB Host API in Dart, excluding `UsbAccessory` and
  `Parcelable` serialization.
- Include all 33 Android USB protocol constants and four host manager constants.
- Declare five Windows pipe operations and nine WinUSB pipe policy constants.
- Use abstract declarations and placeholders marked `NOT IMPLEMENTED YET`;
  placeholders return default values or do nothing.
- Include a minimal Android compilation example.
- Configure private package use with `publish_to: none` and BSD-3-Clause licensing.
