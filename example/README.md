# usb_host_proxy_example

Manual USB Host diagnostics for a physical Android device (API >=28, Android 9) with USB
Host/OTG support. Start it from the launcher or Android's USB app chooser.
Application ID: `dev.jx6A78.usb_host_proxy`. This screen submits no data transfers
(the plugin now implements Android transport). There is no Windows implementation.

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
   False means denied or detached; the API does not distinguish those reasons.
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
6. **Close** releases the connection. Unsupported actions are disabled. The log
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
The console remains 330 pixels high and is labeled **Log**. These three scroll
controllers belong to the screen and are not recreated on selection, Open/Close
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
**Clear**, directly below the console, empties history
and resets its scroll position without logging a confirmation or affecting USB
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
Names are list keys, not UUID replacements. An unobservable unplug/replug cycle
under a reused name remains subject to the plugin's documented limitation.

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
- `_statusLine` reserves stable status/error geometry. The raw/descriptor panels
  constrain variable data to their own scroll areas rather than growing the page.
- `_interfaceOperation` invokes the chosen method and logs the returned boolean;
  `_run` reports exceptions without converting them to false. Java validates
  descriptor ownership and lifecycle, leaving claim policy to Android.
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
`test/transfer_buffer_test.dart` separately checks the library's pure Dart transport
slice/copy-back helpers, early rejection of non-empty read-only IN destinations,
read-only OUT/empty IN behavior and unchanged non-Android request placeholders; it does
not submit transfers through this screen. Java `UsbTransportTest` covers the
mocked native transport boundary on API 28, 31, 33 and 35.
Tests use controlled futures and never access real USB/JNI. They do not establish
hardware correctness. Java unit tests check native result/error forwarding,
descriptor validation, ordering and lifecycle independently of the UI.
The native close/active-I/O lifetime issue is deferred, not resolved. Neither
suite establishes its safety, and this example does not exercise USB transport.
See the [deferred issue in the plugin README](../README.md#deferred-issue-native-closeio-lifetime)
before planning transport teardown tests on hardware.

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
