## 0.2.0 (unreleased)

- Centralize platform selection behind an internal backend contract. Keep Android
  session binding lazy and name/ID conversion session-free, preserving all
  non-Android placeholders. Remove four Java connection forwarding helpers while
  keeping descriptor resolution before worker dispatch; exercise JNI entry points
  directly in management tests.
- Make Java the sole owner of USB lifecycle, descriptor validity, delayed-event
  admission and automatic cleanup. Dart forwards calls/results/events and retains
  only JNI references to Java views; remove its lifecycle registry and helpers.
- Clear all Java descriptor holders on removal/session end. Technical JNI
  references to inert views may remain until Dart GC; name/equality/hash stay
  usable and other getters fail with StateError. Keep the existing worker pool
  and native close protection without FIFO or additional serialisation.
- Preserve completed Java results across delayed delivery. Add Java coverage for
  every descriptor getter, child invalidation, late child creation, event admission
  and awaited proxy operations. Clear a stale diagnostic selection when Java
  rejects its view, even if a same-name replacement has already been enumerated.
- Add a first-use workflow and connection example, separate backend internals
  into a maintainer's guide, and clarify implemented scope versus test coverage.
  Correct descriptions that implied active transport or repository visibility.
- Use Android device names without private device UUIDs, generation checks or
  deviceInstance permission extras. Keep session-isolated callback routes and
  request codes and preserve native results for views of a still-present device.
- Honor detach by name even when that name is already present again. Invalidate
  pending open attempts separately, close late native results and clean resources
  created before rediscovery during enumeration and engine shutdown.
- Document native admission, pending Future completion and close waiting;
  extend lifetime tests to direct file-descriptor and raw-descriptor reads.
- Remove per-connection FIFO executors; dispatch management operations and close
  through the existing session worker pool. Close rejects unstarted native work
  immediately and uses exclusive lifetime protection after admitted calls return;
  management calls can run concurrently, with no FIFO or callback-order guarantee.
- Preserve Android device name-based equality and hashing in Java views,
  independently of wrapper identity. Remove interface/configuration
  reference-identity validation while retaining session and connection lifecycle
  checks; forward descriptors and preserve Android results and exceptions.
- Clarify management implementation versus test coverage, application-owned
  targetSdk and unsupported-operation errors; add information/permission
  regression tests without changing management behavior.
- Withdraw experimental bulk/control/request transport and its JNI buffer,
  completion-observer and request ownership state. Keep the public declarations:
  Android connection transport is unsupported and UsbRequest is a no-op placeholder.
- Retain management workers and Completion callbacks;
  remove only transport-specific tests/helpers and regenerate private bindings.
- Keep native close/active-transport investigation unresolved; the current
  lifetime guard covers implemented management/information calls only.
- Retain the existing single-root-isolate initialization and one listener per
  engine; add regression coverage that a second listener cannot replace the first.
- Require Android API 28 (Android 9) or later in the plugin and diagnostic example.
- Implement Android USB Host enumeration, descriptor access, permissions,
  connection management, interface/configuration selection and device events
  using JNI/JNIgen, without data transport.
- Run blocking connection operations on shared session workers;
  close connections on detach and engine shutdown/restart.
- Deduplicate notifications by name and report detach when enumeration detects
  absence. Do not infer physical attachment identities beyond Android's events.
- Add Android lifecycle/concurrency, name-based device and permission tests
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
