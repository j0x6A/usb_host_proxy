# usb_host_proxy_example

Manual USB Host diagnostics for a physical Android device (API >=24) with USB
Host/OTG support. Start it normally from the launcher. Application ID:
`dev.jarekxxxxx.usb_host_proxy`. There are no USB launch filters or VID/PID filters
in the manifest, no data transfers and no Windows implementation.

## Manual workflow

1. Connect supported USB hardware. Discovery runs at startup and after attach/
   detach events; **Refresh devices** also enumerates and rechecks permission for
   the selected attachment when no operation is pending.
2. Select a device to see its name, VID/PID, product/manufacturer and descriptor
   tree: configurations, interface alternate settings and endpoints. The tree
   is descriptive; the app does not select configurations or alternate settings.
3. Read the permission status. **Request Permission** is the only action that
   requests a system USB permission decision; enumeration/selection never does.
   False means denied or detached; the API does not distinguish those reasons.
4. **Open** requires a selected, authorized device. **Read FD / raw descriptors**
   reads connection information, not an extra control transfer. The file
   descriptor remains owned by the plugin; do not close or use it externally.
   Raw bytes are shown as hex (at most 256 displayed bytes, with total length).
5. Choose an interface descriptor and use **Claim** / **Release**. Claim always
   uses `force: false`. State records successful calls on this connection, by
   interface number (alternate settings share ownership). It is not a global OS
   ownership query. Native false results leave the recorded state unchanged.
6. **Close** releases the connection. Unsupported actions are disabled. The log
   retains the latest 40 operation results, events and failures.

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
the diagnostics log. A close failure is reported as unknown native state, not
as confirmed success. Abrupt process termination cannot await Dart cleanup.

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
- `_deviceTile`, `_descriptorDetails` and `_interfaceControls` render public API
  data and local operation results; they do not open devices while building.
- `test/widget_test.dart`: fake public interfaces and controlled-future scenarios.
  No production manager methods are replaced or mocked inside the plugin.

## Tests and verification boundary

`test/widget_test.dart` injects a fake `UsbManager` into `UsbDiagnosticsApp`.
It covers automatic/manual/event discovery, empty state, permission decisions,
descriptor display, open/null/errors, claim/release results, selection cleanup,
out-of-order results, same-name replacement after detach and screen disposal.
Tests use controlled futures and never access real USB/JNI. These test sources
do not establish hardware correctness and were not executed as part of this change.

On a device, verify grant/refusal, unplug during open/claim/read, reattachment,
two-device selection changes, interface ownership, native raw descriptors and
screen/engine teardown. Device class policy may also require application-level
permissions (for example CAMERA for video devices); the example does not request
those automatically. See the [plugin README](../README.md) for API contracts.
