## 0.2.0 (unreleased)

- Reject non-empty read-only Dart IN buffers before native submission; preserve
  read-only OUT and empty/null IN behavior, with buffer regression tests.
- Clarify targetSdk-dependent bulk/request compatibility limits and record the
  unresolved native close/I/O lifetime race; no close-policy change is made.
- Mark close/I/O lifetime work as deferred, not resolved or waived; retain its
  analysis and verification boundary without adding cancellation or synchronization.
- Require Android API 28 (Android 9) or later in the plugin and diagnostic example.
- Implement bulk/control transport and native UsbRequest initialize/queue/cancel/
  close/wait through JNIgen; keep blocking I/O on parallel session workers and
  management/close on the existing per-connection FIFO.
- Preserve native outcomes/timeouts and original Dart request/client-data identity;
  retain Java-owned buffers through completion and copy only completed IN bytes.
- Regenerate private bindings and test transport concurrency, cleanup, errors and
  buffer boundaries without changing the management-only diagnostic UI or Windows.
- Implement Android USB Host enumeration, descriptor access, permissions,
  connection management, interface/configuration selection and device events
  using JNI/JNIgen.
- Keep blocking connection operations on independent per-connection queues;
  close connections on detach and engine shutdown/restart.
- Identify observed attachments privately by `deviceName-UUID`, retaining the
  UUID across enumerations without changing Android names or public list keys.
- Deduplicate attach/detach notifications, bind permission replies to attachment
  instances and report detach when enumeration detects absence. Unobserved
  same-name unplug/replug cycles cannot be distinguished.
- Add Android lifecycle/concurrency, attachment identity and permission tests
  across API 28, 31, 33 and 35, including plugin engine callbacks.
- Use Java for the Android plugin and example activity; keep Gradle Kotlin DSL.
- Provide a launcher/USB-started diagnostic example with its own namespace
  and fake-backed widget tests, without data transfers.
- Delegate interface claim/release and setting selection to Android/kernel,
  preserving native results and exceptions without local ownership tracking
  or release-specific admission barriers.
- Add explicit None selectors, force claim and a chronological terminal-style
  console to the example; opt only the diagnostic app into all-device USB launch.
- Give console categories fixed colors: cyan USB events, green success, amber
  negative results, red errors and gray information, with widget coverage.
- Keep console history until Clear or screen disposal, always scroll new entries
  to the end and provide Clear directly below the 330-pixel console.
- Stabilize diagnostic sections across USB states with reserved status/error rows
  and independently scrollable raw/descriptor panels; test geometry and lifecycle.
- Enlarge the descriptor tree panel to 300 pixels, place it before interface
  controls and label the diagnostic console Log.
- Build console rows lazily while keeping unlimited history, Clear and automatic
  end scrolling, including corrections for variable-height entries.
- Restore independent raw/descriptor panel offsets after offscreen recreation;
  keep the raw text's internal scroll separate from the panel's saved position.
- Extend widget coverage for lazy history, multiline log bursts and panel
  destruction/recreation without changing USB operation policy.
- Document source responsibilities, reference ownership, synchronization,
  attachment lifecycle and operation/error contracts without changing behavior.
- Handle USB Activity launch/new intents through ActivityAware and the existing
  session registry; keep launch/recreation state silent, deduplicate broadcasts
  and remove Activity listeners independently of headless engine resources.
- Document consumer-owned USB launch filters and extend Activity lifecycle tests.
- Rename the Android namespace to `dev.jx6A78` and update JNI signatures,
  source paths and example identifiers consistently.
- Pin example KGP tooling to 2.4.0 without applying it to the app, satisfying
  Flutter's dependency validation while keeping application/plugin sources in Java.

## 0.1.0

- Declare the Android USB Host API in Dart, excluding `UsbAccessory` and
  `Parcelable` serialization.
- Include all 33 Android USB protocol constants and four host manager constants.
- Declare five Windows pipe operations and nine WinUSB pipe policy constants.
- Use abstract declarations and placeholders marked `NOT IMPLEMENTED YET`;
  placeholders return default values or do nothing.
- Include a minimal Android compilation example.
- Configure private package use with `publish_to: none` and BSD-3-Clause licensing.
