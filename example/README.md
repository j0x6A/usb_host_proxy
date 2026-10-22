# usb_host_proxy_example

Manual USB Host diagnostics for a physical Android device (API >=24) with USB
Host/OTG support. Start it from the launcher or Android's USB app chooser.
Application ID: `dev.jx6A78.usb_host_proxy`. There are no data transfers and
no Windows implementation.

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
   alternate settings and endpoints. The tree
   is descriptive; the app does not select configurations or alternate settings.
   Attach never selects a device. Device **None** clears selection and closes
   the previous connection through the public API. The interface remains None
   after device selection and Open; choose it explicitly before Claim/Release.
3. Read the permission status. **Request Permission** is the only app action that
   explicitly requests a USB permission decision; enumeration/selection never does.
   False means denied or detached; the API does not distinguish those reasons.
4. **Open** requires a selected, authorized device. **Read FD / raw descriptors**
   reads connection information, not an extra control transfer. The file
   descriptor remains owned by the plugin; do not close or use it externally.
   Raw bytes are shown as hex (at most 256 displayed bytes, with total length).
5. Choose an interface descriptor and use **Claim** / **Release**. **Force claim**
   defaults OFF and is passed unchanged; ON does not guarantee success. Selecting
   another interface or interface None neither releases nor selects alternate
   settings. Several interfaces can stay claimed until explicit Release/Close.
   State is by interface number (alternate settings share it) and connection:
   UNCLAIMED permits Claim; native true records CLAIMED, false stays UNCLAIMED.
   CLAIMED permits Release; true records UNCLAIMED, false records UNKNOWN.
   UNKNOWN permits retrying Release or Close, never Claim. The driver independently
   enforces these rules. The UI records returned results, not global OS ownership.
   Exceptions are displayed and do not pretend to be native false; the UI retains
   its last observation, which may be stale after an exceptional native release.
6. **Close** releases the connection. Unsupported actions are disabled. The log
   retains the latest 40 operation results, events and failures. Close calls native
   close, not individual releases, and permanently invalidates the connection.

The console is oldest-first on a dark background with monospace text: gray
information, green success, yellow warnings/false results and red errors. It has
independent scrolling, follows new entries only at the tail (24-pixel tolerance),
and stops following while older entries are being read. Entries beyond the last
40 are discarded, including entries currently being read.

## Lifecycle and concurrency

The screen owns at most one published connection. Changing the selected device,
observing its detach/absence, or disposing the screen clears its UI ownership
and attempts native close. Late open results are closed, never adopted by a new
selection. Selection, discovery and permission-check versions discard obsolete
results; original public device/interface references are passed to the plugin.
Names are list keys, not UUID replacements. An unobservable unplug/replug cycle
under a reused name remains subject to the plugin's documented limitation.

One user operation runs at a time; cleanup also blocks new USB operations until
it finishes. Discovery and device selection remain available. A pending permission
dialog has no application timeout. Dispose cancels both stream subscriptions and
starts cleanup, but Flutter's synchronous dispose cannot await native futures.
An in-flight completion retains responsibility for closing any late connection.
Cleanup errors after disposal go to the debug log; failures while visible go to
the diagnostics log. A close failure reports unconfirmed native cleanup, but
the connection remains unusable, not UNKNOWN. Abrupt process termination cannot
await Dart cleanup.

The UI action gate is deliberately screen-wide: it prevents opening another
connection before previous action/cleanup futures settle. It is separate from
the plugin's native per-connection queues. Permission checks and descriptor
getters still follow the public API's synchronous JNI behavior; returning a
Future does not by itself move those calls off the root isolate.

If a refresh fails, the last accepted list remains visible with an explicit error;
it is not a fresh proof of presence. Successful refresh is not a hardware identity
comparison. Selecting an interface changes only which original descriptor is
passed to Claim/Release, not the active configuration or alternate setting.

## Reading the example

- `lib/main.dart`: one stateful screen. `_refresh` owns scan revisions, `_select`
  invalidates the previous selection, and `_checkPermission` owns check revisions.
- `_run` gates user actions. `_closeOwned` remains responsible for native cleanup
  even if the selected device or screen no longer exists. `_current` is a UI
  result-acceptance rule, not a replacement for the plugin's attachment UUID.
- `_deviceLabel`, `_descriptorDetails` and `_interfaceControls` render public API
  data and local operation results; they do not open devices while building.
- `_interfaceStates` contains only returned operation results for presentation.
  `_interfaceOperation` never converts exceptions into false; Java independently
  validates ownership and the state machine. `_forceClaim` is only user input.
- `_log` appends severity-colored entries and schedules tail following after
  layout; `_consoleScroll` is disposed with the screen. No log stream or replay
  service is added to the plugin.
- `test/widget_test.dart`: fake public interfaces and controlled-future scenarios.
  No production manager methods are replaced or mocked inside the plugin.

## Tests and verification boundary

`test/widget_test.dart` injects a fake `UsbManager` into `UsbDiagnosticsApp`.
It covers automatic/manual/event discovery, empty state, permission decisions,
descriptor display, open/null/errors, claim/release results, selection cleanup,
out-of-order results, same-name replacement after detach and screen disposal,
None/Force behavior, per-interface observations and console history/scrolling.
Tests use controlled futures and never access real USB/JNI. They do not establish
hardware correctness. Java unit tests cover the driver's state machine and
admission barriers independently of the UI.

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
application-level permissions (for example CAMERA for video devices); the example does not request
those automatically. See the [plugin README](../README.md) for API contracts.
