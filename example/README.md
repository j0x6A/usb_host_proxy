# usb_host_proxy_example

Manual USB Host diagnostics for a physical Android device running API 28
(Android 9) or later with USB Host/OTG support.
Application ID: `dev.jx6A78.usb_host_proxy`. There are no data transfers and
no Windows implementation.

`minSdk` is explicitly 28; `compileSdk` and `targetSdk` follow the installed
Flutter SDK through the app's Gradle configuration. This example does not impose
its target API on applications consuming the plugin.

## Run the example

With Flutter and Android tooling installed, connect the Android device and run
these commands from `example/`:

```powershell
flutter pub get
flutter run
```

Start the installed app from its launcher icon or Android's USB app chooser.
The app enumerates automatically, but both selectors start at **None**. It requests
permission only when you press **Request Permission**. Open, Close, Claim and
Release also require an explicit click; Android's USB chooser may grant access
separately, as described below.

Use this screen to inspect descriptors, permissions, connection information and
Claim/Release results. It has no transfer controls and no controls for setting
configurations/alternate settings, reading serial numbers or converting names/IDs.
Those management/information methods remain available in the library; see the
[API overview and verification limits](../README.md).

## USB launch and defaults

Only this example's Activity declares `USB_DEVICE_ATTACHED` plus metadata for
`res/xml/device_filter.xml`. Its attribute-free `<usb-device />` intentionally
matches **all USB devices**, without VID/PID restrictions. The plugin's own
manifest remains unchanged; consuming apps choose their own filters.

Android decides whether to show a USB application chooser or launch a previously
selected default. Availability and default-reset UI vary by Android version/OEM;
use the system's app/default settings to clear a remembered handler. This is not
a guarantee that every device/OEM will launch the Activity. Choosing the app can
grant USB permission until detach without a separate requestPermission dialog.
The application itself does not request permission, open or claim on startup.

Initial Activity intents contribute initial state through enumeration, not a
synthetic attached event. New intents and broadcasts share the plugin's existing
deduplication/lifecycle handling. Neither selects a device or interface in the UI.

## Manual workflow

1. Connect supported USB hardware. Discovery runs at startup and after attach/
   detach events; **Refresh devices** also enumerates and rechecks permission for
   the selected attachment when no operation is pending.
2. Both dropdowns initially select **None**. Select a device to see its name,
   VID/PID, product/manufacturer and descriptor tree: configurations, interface
   alternate settings and endpoints. The tree is descriptive; the app does not
   select configurations or alternate settings.
   Attach never selects a device. Device **None** clears selection and closes
   the previous connection through the public API. The interface remains None
   after device selection and Open; choose it explicitly before Claim/Release.
3. Read the permission status. **Request Permission** is the only app action that
   explicitly requests a USB permission decision; enumeration/selection never does.
   False means no access was obtained; the API does not distinguish refusal from detach.
4. **Open** requires a selected, authorized device. **Read FD / raw descriptors**
   reads connection information, not an extra control transfer. The file
   descriptor remains owned by the plugin; do not close or use it externally.
   Raw bytes are shown as hex (at most 256 displayed bytes, with total length).
5. Choose an interface descriptor and use **Claim** / **Release**. **Force claim**
   defaults OFF and is passed unchanged; ON does not guarantee success. Selecting
   another interface or interface None neither releases nor selects alternate
   settings. Both buttons are available whenever a connection is open, an
   interface is selected and no UI operation/cleanup is pending. Every click calls
   the plugin, including repeated Claim and Release without prior Claim. The
   console displays native true/false or an exception; neither the UI nor the
   library records ownership history or infers claim state from earlier results.
   Android/kernel decide what each call can do. An exception is never shown as false.
6. **Close** closes the native connection. Buttons that require a device,
   interface, permission or idle screen are disabled until those conditions hold. The log
   retains operation results, events and failures until Clear or screen disposal.
   Close calls native close, not individual releases, and permanently invalidates
   the connection.

## Fixed screen layout

All sections and controls remain in the layout, including when discovery is
empty or the selected device is detached. USB state changes only displayed
values and enabled callbacks. Status/error rows reserve 24 logical pixels each;
long text is ellipsized and its tooltip exposes the complete value. Unavailable
values use placeholders, while FD/raw values are blank until read.

Raw descriptors have an 80-pixel panel and the descriptor tree a 300-pixel panel
above the interface controls. Each panel scrolls independently. Their contents,
including errors and long descriptor strings, do not move subsequent sections.
The console is labeled **Log**. All three scroll controllers belong to the screen
and are not recreated on selection, Open/Close
or attach/detach. The page still scrolls as a whole; controls need not fit
simultaneously on a phone screen.
Independent PageStorage keys restore the raw and descriptor panel offsets when
the outer list destroys and recreates offscreen panels with unchanged data.
The raw text's internal scroll has a separate key so it cannot overwrite the
raw panel's saved offset. Shorter contents can still clamp the restored position.

Interface descriptor failures leave the selector, Force and Claim/Release
controls in place but disable unsafe callbacks. This affects presentation only,
not USB ownership, permission or operation policy.

The console is oldest-first on a dark background with monospace text. Colors
come from an explicit message category, never from matching words in its text:

| Category | Color | ARGB |
| --- | --- | --- |
| Attached and Detached | Cyan | `0xFF55D9EF` |
| Successful operation | Green | `0xFF45D483` |
| False or failure without an exception | Amber | `0xFFF6BE55` |
| Exception/error | Red | `0xFFFF7070` |
| Ordinary information | Gray | `0xFFAAAAAA` |

Both USB events always use cyan. A null Open result, invalid file descriptor or
null raw-descriptor result uses amber; readable connection metadata uses green.
These colors describe the returned operation result, not cached interface ownership.

The console is 330 logical pixels high and scrolls independently of the page.
Every appended message scrolls it to the end after layout, even if the user was
reading earlier entries. Attached and Detached behave identically. History is
chronological and unlimited for the screen's lifetime, so memory use grows with
the number of messages. Rows are built lazily rather than creating a Text widget
for every stored entry. This does not isolate screen rebuilds: logging still
updates the screen state, whose build reads selected-device descriptors.
**Clear**, directly below the console, empties history and resets its scroll
position without logging a confirmation or affecting USB
selection, permissions, connections or pending operations. Subsequent messages
are added normally and again scroll to the end. Only Clear or screen disposal
removes history; there is no automatic trimming.
If the outer list recreates an offscreen console, controller attachment also
restores the end after layout, without scrolling the enclosing page.
For variable-height rows, scrolling follows corrections to the lazy list's
estimated extent after subsequent layouts until the current end is reached.

## Lifecycle and concurrency

The screen owns at most one published connection. Changing the selected device,
observing its detach/absence, or disposing the screen clears its UI ownership
and attempts native close. Late open results are closed, never adopted by a new
selection. Selection, discovery and permission-check versions discard obsolete
results; original public device/interface references are passed to the plugin.
Names are Android list keys. The plugin adds no device UUID. Observed removal
invalidates saved device/descriptor views and starts connection cleanup. Only
the old device's name, equality and hash remain available, without JNI handles;
reconnecting under the same name does not revive those views. The screen clears
its selection on detach. While the device remains present, a new enumeration
does not update fields of previously obtained descriptor views.

One user operation runs at a time; cleanup also blocks new USB operations until
it finishes. Discovery and device selection remain available. A pending permission
dialog has no application timeout. Dispose cancels both stream subscriptions and
starts cleanup, but Flutter's synchronous dispose cannot await native futures.
An in-flight completion retains responsibility for closing any late connection.
Cleanup errors after disposal go to the debug log; failures while visible go to
the diagnostics log. A close failure reports unconfirmed native cleanup, but
the connection remains unusable. Abrupt process termination cannot await Dart cleanup.

The UI action gate is deliberately screen-wide: it prevents opening another
connection before previous action/cleanup futures settle. It is separate from
the plugin's shared worker pool, which provides no FIFO ordering. Permission
checks and descriptor getters still follow the public API's synchronous JNI
behavior; returning a Future does not by itself move those calls off the root
isolate.

If a refresh fails, the last accepted list remains visible with an explicit error;
it is not a fresh proof of presence. Successful refresh is not a hardware identity
comparison. Selecting an interface changes only which original descriptor is
passed to Claim/Release, not the active configuration or alternate setting.

## Reading the example

- `lib/main.dart`: one stateful screen. `_refresh` owns scan revisions, `_select`
  invalidates the previous selection, and `_checkPermission` owns check revisions.
- `_run` gates user actions. `_closeOwned` remains responsible for native cleanup
  even if the selected device or screen no longer exists. `_current` is a UI
  result-acceptance rule, not an additional USB device identity.
- `_deviceLabel`, `_descriptorDetails` and `_interfaceControls` render public API
  data and local operation results; they do not open devices while building.
- `_statusLine` reserves stable status/error geometry. The raw/descriptor panels
  constrain variable data to their own scroll areas rather than growing the page.
- `_interfaceOperation` invokes the chosen method and logs the returned boolean;
  `_run` reports exceptions without converting them to false. Java validates
  connection lifecycle and forwards descriptors without checking reference
  identity against the selected device's tree, leaving claim policy to Android.
  `_forceClaim` is only user input.
- `_LogLevel` distinguishes USB events, successes, negative results, exceptions
  and ordinary information. `_log` appends category-colored entries and scrolls
  to the end after layout. `_scrollConsoleToEnd` also handles reattachment after
  the outer list hid the console offscreen, with disposal/client guards. All
  three panel controllers are disposed with the screen. No log stream or replay
  service is added to the plugin.
- `test/widget_test.dart`: fake public interfaces and controlled-future scenarios.
  No production manager methods are replaced or mocked inside the plugin.

## Tests and verification boundary

`test/widget_test.dart` injects a fake `UsbManager` into `UsbDiagnosticsApp`.
It covers automatic/manual/event discovery, empty state, permission decisions,
descriptor display, open/null/errors, claim/release results, selection cleanup,
out-of-order results, same-name replacement after detach and screen disposal,
None/Force behavior, repeated Claim/Release, all five console color categories
and unlimited console history, unconditional scrolling, Clear and disposal.
Layout tests compare section types, positions, dimensions and scroll-position
identity across USB states, long data, pending operations and descriptor errors.
They also check independent panel offsets after offscreen destruction/recreation,
lazy console rows with complete history and scrolling after multiline log bursts.
Color tests include exception text resembling a USB/success message to ensure
text content never determines the category.
Tests use controlled futures and never access real USB/JNI. They do not establish
hardware correctness. Java unit tests check native result/error forwarding,
descriptor forwarding, parallel execution and lifecycle independently of the UI.
Those Java tests cover invalidation of saved views after detach, name-based permission coalescing,
session-isolated replies and cleanup of opens invalidated by detach/restart,
including rejection of stale views after reconnection. No device UUID is involved.
They also check device/connection serial values and errors, native FD/raw
descriptor results, rejection after close and permission submission failures.
Blocked direct FD/raw reads verify that native close waits for their return
while later reads are rejected. This does not add any operation to the UI.
This does not cover JNI conversion or native USB behavior. Library features
without screen controls require a separate caller for manual verification.
`test/device_lifetime_test.dart` checks the production resource-ownership helpers
without JNI: cascading invalidation, reference release, cleanup failures, native
close completion, repeated close and independent lifetimes for reused names.
`test/usb_request_test.dart` separately checks the withdrawn transport's public
UsbRequest placeholders: null/false/no-op results, no native calls and no buffer
reads or writes. It does not test a working transport implementation.

With dependencies and Android tooling already available, run from `example/`:

```powershell
flutter test --no-pub
flutter analyze --no-pub
```

Run the Java suite from `example/android/`:

```powershell
.\gradlew.bat :usb_host_proxy:testDebugUnitTest --offline --console=plain --no-daemon
```

The Java task compiles test/library code and writes reports under
`example/build/usb_host_proxy/`; it does not build/install an example APK.
Offline mode requires dependencies to be cached. Run `flutter analyze --no-pub`
from the repository root as well to include the plugin sources and generation tool.

The example pins KGP tooling in `android/settings.gradle.kts` with `apply false`:
this overrides AGP's older transitive dependency for Flutter's version check,
not the Java source language. Existing `android.newDsl=false` and
`android.builtInKotlin=false` are transitional compatibility settings; their
deprecation warnings do not establish a test failure and require a separate
toolchain migration before a future AGP upgrade.

On a device, verify grant/refusal, unplug during open/claim/read, reattachment,
two-device selection changes, interface ownership, native raw descriptors and
screen/engine teardown. Also check USB chooser/default selection, clearing a
default, cold/warm USB launches, duplicate Intent/broadcast delivery, force claim
with a kernel-owned interface and release failures. Device class policy may require
application-level permissions (for example CAMERA for video devices); the example
does not request those automatically. See the [plugin README](../README.md) for API contracts.

For device-removal cleanup, also verify with a small caller using the public API:

1. Retain a device, configuration, interface and endpoint, then unplug or disable
   the device's USB port. Their descriptor getters must fail with `StateError`.
2. The removed device's name, equality and hash must remain usable. Its detach
   payload must allow reading the name without accessing any other descriptor.
3. Repeat without subscribing to device streams. Enumeration must return an
   empty map, the saved objects must be invalid and repeated close must be safe.
4. Reconnect and enumerate a new device view. The old views must stay invalid,
   even if Android reuses the name; the manager must remain usable throughout.

These checks exercise the JNI boundary that the fake-backed widget tests and
ownership-helper tests do not run. A detach event marks the start of cleanup;
native close can finish later, after already-admitted native calls return.
