import 'dart:async';

import 'package:flutter/material.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

/// Explicit console category; USB events are independent of operation outcomes.
enum _LogLevel { info, usbEvent, success, warning, error }

/// Uses the real public manager in the Android engine's root isolate.
void main() => runApp(UsbDiagnosticsApp());

/// USB/launcher-started diagnostics. Tests supply a manager without starting JNI.
/// The manager is fixed for this widget's lifetime.
class UsbDiagnosticsApp extends StatefulWidget {
  /// Accepts an optional test double; constructing a manager does not open USB.
  UsbDiagnosticsApp({super.key, UsbManager? manager})
    : manager = manager ?? UsbManager();

  /// Public API entry point shared by discovery, streams and explicit actions.
  final UsbManager manager;

  @override
  State<UsbDiagnosticsApp> createState() => _UsbDiagnosticsAppState();
}

/// Owns screen-local diagnostics, not a second native attachment registry.
///
/// Selection/discovery/check versions invalidate results independently. A stale
/// Open result still has a resource to close, even though its UI result is ignored.
class _UsbDiagnosticsAppState extends State<UsbDiagnosticsApp> {
  /// Cancelled on dispose; subscriptions are installed before the first scan.
  StreamSubscription<UsbDevice>? _attached;
  StreamSubscription<UsbDevice>? _detached;

  /// Latest accepted enumeration, keyed by the unchanged public Android name.
  Map<String, UsbDevice> _devices = {};

  /// Selected Android device-list key.
  String? _selectedName;

  /// Retained original selection; not replaced by a new adapter on each scan.
  UsbDevice? _device;

  /// Original flattened interface references used as claim/release arguments.
  List<UsbInterface> _interfaces = [];

  /// Descriptor index into [_interfaces], not bInterfaceNumber; null is UI None.
  int? _interfaceIndex;

  /// The sole published connection; cleared before cleanup hands it to a future.
  UsbDeviceConnection? _connection;

  /// Explicit user preference; forwarded only by Claim and never auto-enabled.
  bool _forceClaim = false;

  /// Latest permission observation; null means unknown, not denial.
  bool? _permission;

  /// Automatic hasPermission work; excluded from the user-action counter.
  bool _checkingPermission = false;

  /// Progress/error state belongs only to the latest accepted scan version.
  bool _refreshing = false;

  /// UI status includes pending close and uncertainty after native close failure.
  String _connectionState = 'Closed';
  String? _scanError;

  /// Results of the last successful paired read; cleared on retry or selection.
  int? _fileDescriptor;
  String? _rawDescriptors;

  /// Chronological history retained until Clear or disposal, without a size limit.
  final List<({String text, Color color})> _messages = [];

  /// Owned by the screen; attachment follows the end after offscreen recreation.
  /// Disposed after result acceptance has been disabled.
  late final ScrollController _consoleScroll = ScrollController(
    onAttach: (_) => _scrollConsoleToEnd(),
  );

  /// Screen-owned controllers are not replaced on USB state changes. Flutter may
  /// clamp their offsets when panel contents shrink; that does not replace them.
  /// Panel PageStorage keys restore offsets if their scroll positions are recreated.
  final ScrollController _rawScroll = ScrollController();
  final ScrollController _descriptorScroll = ScrollController();

  // Versions arbitrate UI results; Android names identify device-list entries.
  int _selectionVersion = 0;
  int _scanVersion = 0;
  int _permissionVersion = 0;

  /// User action plus cleanup futures. This is a UI gate, not a native work queue.
  int _pendingActions = 0;

  /// User-action label; cleanup alone is displayed separately by [build].
  String? _operation;

  /// Set before asynchronous disposal work, while mounted may still be true.
  bool _disposed = false;

  /// Prevents setState both during and after disposal.
  bool get _alive => mounted && !_disposed;

  /// Discovery/selection can continue while USB action buttons are gated.
  bool get _idle => _pendingActions == 0;

  /// A completion may mutate selected state only while its selection is current.
  bool _current(int version) => _alive && version == _selectionVersion;

  @override
  void initState() {
    super.initState();
    // Subscribe before enumeration so a concurrent physical edge is not missed.
    try {
      _attached = widget.manager.deviceAttached.listen(
        (device) => _deviceEvent(device, attached: true),
        onError: (Object error) =>
            _log('Attach stream error: $error', _LogLevel.error),
      );
      _detached = widget.manager.deviceDetached.listen(
        (device) => _deviceEvent(device, attached: false),
        onError: (Object error) =>
            _log('Detach stream error: $error', _LogLevel.error),
      );
    } catch (error) {
      _log('USB event subscription failed: $error', _LogLevel.error);
    }
    unawaited(_refresh());
  }

  /// Appends visible results, or sends cleanup messages to debug output after disposal.
  /// Category alone determines color; text and prior USB results are not inspected.
  /// Every append scrolls only the console to its end after layout.
  /// This still rebuilds the screen; lazy rows avoid building the entire history,
  /// but do not isolate the descriptor getters called elsewhere in [build].
  void _log(String message, [_LogLevel level = _LogLevel.info]) {
    if (!_alive) {
      debugPrint('USB diagnostics: $message');
      return;
    }
    final color = switch (level) {
      _LogLevel.info => const Color(0xFFAAAAAA),
      _LogLevel.usbEvent => const Color(0xFF55D9EF),
      _LogLevel.success => const Color(0xFF45D483),
      _LogLevel.warning => const Color(0xFFF6BE55),
      _LogLevel.error => const Color(0xFFFF7070),
    };
    setState(() {
      _messages.add((text: message, color: color));
    });
    _scrollConsoleToEnd();
  }

  /// Follows lazy extent corrections until the laid-out end is reached.
  /// Also handles a console recreated after the outer lazy list hid it offscreen.
  /// Stops without clients or after disposal; no timer or persistent frame loop.
  void _scrollConsoleToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_alive && _consoleScroll.hasClients) {
        final position = _consoleScroll.position;
        if (position.pixels != position.maxScrollExtent) {
          _consoleScroll.jumpTo(position.maxScrollExtent);
          // Lazy, variable-height rows can refine the estimated extent after
          // this jump. Follow the updated end after their next layout as well.
          _scrollConsoleToEnd();
        }
      }
    });
  }

  /// Invalidates the selected name on detach, then requests a fresh public list.
  void _deviceEvent(UsbDevice device, {required bool attached}) {
    if (!_alive) return;
    try {
      final name = device.getDeviceName();
      _log('${attached ? 'Attached' : 'Detached'}: $name', _LogLevel.usbEvent);
      if (!attached) {
        setState(() => _devices.remove(name));
        // Public adapters are not identity tokens. Never compare Dart wrappers
        // to correlate enumerations; a delivered detach invalidates this name.
        if (_selectedName == name) _select(null);
      }
    } catch (error) {
      _log('USB event descriptor error: $error', _LogLevel.error);
    }
    unawaited(_refresh());
  }

  /// Latest scan wins; failure keeps the previous list visible with an error.
  /// Continuous presence keeps the original selected reference and connection.
  Future<void> _refresh() async {
    final scan = ++_scanVersion;
    if (!_alive) return;
    setState(() {
      _refreshing = true;
      _scanError = null;
    });
    try {
      final found = await widget.manager.getDeviceList();
      if (!_alive || scan != _scanVersion) return;
      setState(() => _devices = Map.of(found));
      if (_selectedName != null && !found.containsKey(_selectedName)) {
        _log('Selected device is no longer present', _LogLevel.info);
        _select(null);
      }
      // Keep the selected descriptor view while its name stays present. New
      // enumeration entries do not mutate previously obtained framework objects.
      if (_device != null && _idle) {
        unawaited(_checkPermission(_device!, _selectionVersion));
      }
    } catch (error) {
      if (_alive && scan == _scanVersion) {
        setState(() => _scanError = '$error');
        _log('Enumeration failed: $error', _LogLevel.error);
      }
    } finally {
      if (_alive && scan == _scanVersion) {
        setState(() => _refreshing = false);
      }
    }
  }

  /// Immediately gives up UI ownership; cleanup may finish after a new selection.
  void _select(String? name) {
    if (!_alive || name == _selectedName) return;
    if (name != null && !_devices.containsKey(name)) return;
    final previous = _connection;
    final version = ++_selectionVersion;
    ++_permissionVersion;
    setState(() {
      _selectedName = name;
      _device = name == null ? null : _devices[name];
      _connection = null;
      _interfaces = [];
      _interfaceIndex = null;
      _permission = null;
      _checkingPermission = false;
      _connectionState = 'Closed';
      _fileDescriptor = null;
      _rawDescriptors = null;
    });
    if (previous != null) unawaited(_closeOwned(previous, 'Selection cleanup'));
    final device = _device;
    if (device == null) return;
    try {
      final interfaces = [
        for (var i = 0; i < device.getInterfaceCount(); i++)
          device.getInterface(i),
      ];
      setState(() {
        _interfaces = interfaces;
      });
    } catch (error) {
      _log('Interface enumeration failed: $error', _LogLevel.error);
    }
    unawaited(_checkPermission(device, version));
  }

  /// Non-dialog check guarded against both selection changes and newer checks.
  Future<void> _checkPermission(UsbDevice device, int selection) async {
    if (!_current(selection)) return;
    final check = ++_permissionVersion;
    setState(() => _checkingPermission = true);
    try {
      final allowed = await widget.manager.hasPermission(device);
      if (!_current(selection) || check != _permissionVersion) return;
      setState(() => _permission = allowed);
    } catch (error) {
      if (_current(selection) && check == _permissionVersion) {
        setState(() => _permission = null);
        _log('hasPermission failed: $error', _LogLevel.error);
      }
    } finally {
      if (_current(selection) && check == _permissionVersion) {
        setState(() => _checkingPermission = false);
      }
    }
  }

  /// At most one user action runs. Cleanup is counted too, not queued in Dart.
  /// Old-action failures may enter the log but cannot replace new device state.
  Future<void> _run(String label, Future<void> Function(int) operation) async {
    if (!_alive || !_idle) return;
    final version = _selectionVersion;
    setState(() {
      _pendingActions++;
      _operation = label;
    });
    try {
      await operation(version);
    } catch (error) {
      _log(
        '$label${_current(version) ? '' : ' (previous selection)'} failed: $error',
        _LogLevel.error,
      );
    } finally {
      if (_alive) {
        setState(() {
          _pendingActions--;
          _operation = null;
        });
      }
    }
  }

  /// Owns cleanup even after disposal; no late native connection is abandoned.
  Future<void> _closeOwned(
    UsbDeviceConnection connection,
    String reason,
  ) async {
    if (_alive) setState(() => _pendingActions++);
    try {
      await connection.close();
      _log('$reason: closed', _LogLevel.success);
    } catch (error) {
      _log(
        '$reason failed; connection unusable, native cleanup not confirmed: $error',
        _LogLevel.error,
      );
    } finally {
      if (_alive) setState(() => _pendingActions--);
    }
  }

  /// The only path requesting a system decision; reads actual permission after it.
  Future<void> _requestPermission() => _run('Request Permission', (
    version,
  ) async {
    final device = _device;
    if (device == null || _permission == true || _checkingPermission) return;
    ++_permissionVersion; // Invalidate older automatic hasPermission results.
    setState(() => _checkingPermission = false);
    final allowed = await widget.manager.requestPermission(device);
    if (!_current(version)) return;
    _log(
      'Request Permission: ${allowed ? 'granted' : 'not granted (denied or detached)'}',
      allowed ? _LogLevel.success : _LogLevel.warning,
    );
    await _checkPermission(device, version);
  });

  /// Adopts a native result only for the current selection, otherwise closes it.
  /// Every successful Open resets the interface selector to None, not its first item.
  Future<void> _open() => _run('Open', (version) async {
    final device = _device;
    if (device == null ||
        _permission != true ||
        _checkingPermission ||
        _connection != null) {
      return;
    }
    setState(() => _connectionState = 'Opening…');
    UsbDeviceConnection? opened;
    try {
      opened = await widget.manager.openDevice(device);
    } catch (_) {
      if (_current(version)) setState(() => _connectionState = 'Closed');
      rethrow;
    }
    if (opened == null) {
      if (_current(version)) {
        setState(() => _connectionState = 'Closed');
        _log(
          'Open returned null; no connection was created',
          _LogLevel.warning,
        );
      }
      return;
    }
    if (!_current(version)) {
      await _closeOwned(opened, 'Late Open cleanup');
      return;
    }
    setState(() {
      _connection = opened;
      _connectionState = 'Open';
      _interfaceIndex = null;
    });
    _log('Open: connected', _LogLevel.success);
  });

  /// Transfers connection ownership to this call before awaiting native close.
  Future<void> _close() => _run('Close', (version) async {
    final connection = _connection;
    if (connection == null) return;
    setState(() {
      _connection = null;
      _connectionState = 'Closing…';
      _fileDescriptor = null;
      _rawDescriptors = null;
    });
    try {
      await connection.close();
      if (_current(version)) {
        setState(() => _connectionState = 'Closed');
        _log('Close: closed', _LogLevel.success);
      }
    } catch (_) {
      if (_current(version)) {
        setState(
          () => _connectionState = 'Closed; native cleanup not confirmed',
        );
      }
      rethrow;
    }
  });

  /// Reads connection metadata, not USB transport; publishes only a complete pair.
  /// A change between the two awaits prevents further access to the old handle.
  /// Missing/invalid metadata changes only the log category, not the native result.
  Future<void> _readConnection() => _run('Read connection', (version) async {
    final connection = _connection;
    if (connection == null) return;
    setState(() {
      _fileDescriptor = null;
      _rawDescriptors = null;
    });
    final fd = await connection.getFileDescriptor();
    if (!_current(version) || !identical(connection, _connection)) return;
    final raw = await connection.getRawDescriptors();
    if (!_current(version) || !identical(connection, _connection)) return;
    setState(() {
      _fileDescriptor = fd;
      _rawDescriptors = raw == null
          ? 'null'
          : '${raw.length} bytes: ${raw.take(256).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}'
                '${raw.length > 256 ? ' … (display limited to 256 bytes)' : ''}';
    });
    _log(
      'Read connection: fd=$fd, raw=${raw?.length ?? 'null'}',
      fd >= 0 && raw != null ? _LogLevel.success : _LogLevel.warning,
    );
  });

  /// Calls the selected operation each time; results/errors are logged, not cached.
  Future<void> _interfaceOperation({required bool claim}) =>
      _run(claim ? 'Claim' : 'Release', (version) async {
        final connection = _connection;
        final index = _interfaceIndex;
        if (connection == null || index == null) return;
        final intf = _interfaces[index];
        final id = intf.getId();
        final success = claim
            ? await connection.claimInterface(intf, force: _forceClaim)
            : await connection.releaseInterface(intf);
        if (!_current(version) || !identical(connection, _connection)) return;
        _log(
          '${claim ? 'Claim' : 'Release'} interface $id: $success',
          success ? _LogLevel.success : _LogLevel.warning,
        );
      });

  /// Settles subscription cleanup errors without an unhandled dispose-time future.
  Future<void> _cancel(StreamSubscription<UsbDevice>? subscription) async {
    try {
      await subscription?.cancel();
    } catch (error) {
      _log('Subscription cleanup failed: $error', _LogLevel.error);
    }
  }

  @override
  void dispose() {
    // Flutter dispose is synchronous. Futures keep ownership of late/closing
    // connections; invalidated versions prevent them from touching this UI.
    _disposed = true;
    ++_selectionVersion;
    ++_scanVersion;
    ++_permissionVersion;
    unawaited(_cancel(_attached));
    unawaited(_cancel(_detached));
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      unawaited(_closeOwned(connection, 'Screen cleanup'));
    }
    _consoleScroll.dispose();
    _rawScroll.dispose();
    _descriptorScroll.dispose();
    super.dispose();
  }

  /// Common VID/PID/address formatting; never changes values sent to Android.
  String _hex(int value) => '0x${value.toRadixString(16).padLeft(4, '0')}';

  /// One reserved line: long values/errors never move the sections below it.
  /// The tooltip retains the complete message when the displayed text is ellipsized.
  Widget _statusLine(String key, String text, {TextStyle? style}) => SizedBox(
    key: Key(key),
    height: 24,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: text,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    ),
  );

  /// Optional product-name failure must not hide readable VID/PID values.
  String _deviceLabel(String name, UsbDevice device) {
    String subtitle;
    try {
      subtitle =
          'VID ${_hex(device.getVendorId())} / PID ${_hex(device.getProductId())}';
    } catch (error) {
      subtitle = 'Descriptor error: $error';
    }
    try {
      subtitle += ' / ${device.getProductName() ?? '(no product name)'}';
    } catch (error) {
      subtitle += ' / Product name error: $error';
    }
    return '$name — $subtitle';
  }

  /// Displays all configurations without claiming or selecting any of them.
  Widget _descriptorDetails(UsbDevice device) {
    try {
      final lines = <Widget>[
        Text('Device: ${device.getDeviceName()}'),
        Text(
          'VID ${_hex(device.getVendorId())} / PID ${_hex(device.getProductId())}',
        ),
        Text('Product: ${device.getProductName() ?? '(unknown)'}'),
        Text('Manufacturer: ${device.getManufacturerName() ?? '(unknown)'}'),
        Text('Version: ${device.getVersion()} / ID: ${device.getDeviceId()}'),
        Text(
          'Class ${device.getDeviceClass()}, subclass ${device.getDeviceSubclass()}, '
          'protocol ${device.getDeviceProtocol()}',
        ),
      ];
      for (var c = 0; c < device.getConfigurationCount(); c++) {
        final config = device.getConfiguration(c);
        lines.add(
          Text(
            'Configuration $c: value ${config.getId()}, '
            '${config.getName() ?? '(unnamed)'}, ${config.getMaxPower()} mA, '
            'self-powered=${config.isSelfPowered()}, wakeup=${config.isRemoteWakeup()}',
          ),
        );
        for (var i = 0; i < config.getInterfaceCount(); i++) {
          final intf = config.getInterface(i);
          lines.add(
            Text(
              '  Interface ${intf.getId()}, alt ${intf.getAlternateSetting()}: '
              '${intf.getName() ?? '(unnamed)'}, class ${intf.getInterfaceClass()}, '
              'subclass ${intf.getInterfaceSubclass()}, protocol ${intf.getInterfaceProtocol()}',
            ),
          );
          for (var e = 0; e < intf.getEndpointCount(); e++) {
            final endpoint = intf.getEndpoint(e);
            lines.add(
              Text(
                '    Endpoint ${_hex(endpoint.getAddress())}: '
                'direction=${endpoint.getDirection()}, type=${endpoint.getType()}, '
                'attributes=${endpoint.getAttributes()}, packet=${endpoint.getMaxPacketSize()}, '
                'interval=${endpoint.getInterval()}',
              ),
            );
          }
        }
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      );
    } catch (error) {
      return Text('Descriptor error: $error');
    }
  }

  /// Selects original descriptors without performing or tracking interface claims.
  /// Getter failures change only content/availability, never remove these controls.
  Widget _interfaceControls() {
    int? id;
    String? descriptorError;
    final items = <DropdownMenuItem<int>>[
      const DropdownMenuItem(value: -1, child: Text('None')),
    ];
    try {
      id = _interfaceIndex == null
          ? null
          : _interfaces[_interfaceIndex!].getId();
      for (var i = 0; i < _interfaces.length; i++) {
        items.add(
          DropdownMenuItem(
            value: i,
            child: Text(
              'Interface ${_interfaces[i].getId()}, '
              'alt ${_interfaces[i].getAlternateSetting()} (descriptor $i)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
    } catch (error) {
      descriptorError = 'Interface descriptor error: $error';
      id = null;
      items.removeRange(1, items.length);
    }
    final usable =
        _idle && _connection != null && id != null && descriptorError == null;
    final selection = _selectionVersion;
    return Column(
      key: const Key('interface-controls'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<int>(
          key: const Key('interfaces'),
          value: descriptorError == null ? _interfaceIndex ?? -1 : -1,
          isExpanded: true,
          items: items,
          onChanged: _idle && descriptorError == null
              ? (index) {
                  // A dropdown route may return after detach or device selection.
                  if (_current(selection) && _idle && index != null) {
                    if (index >= -1 && index < _interfaces.length) {
                      setState(
                        () => _interfaceIndex = index == -1 ? null : index,
                      );
                    }
                  }
                }
              : null,
        ),
        _statusLine(
          'interface-status',
          id == null
              ? 'No interface selected'
              : 'Interface $id: ${_connection == null ? 'no open connection' : 'selected'}',
        ),
        _statusLine('interface-error', descriptorError ?? 'Interface error: —'),
        const Text(
          'Claim/Release results are shown in the console; Android manages ownership.',
        ),
        SwitchListTile(
          key: const Key('force'),
          title: Text(
            'Force claim: ${_forceClaim ? 'ON' : 'OFF'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: _forceClaim,
          onChanged: _idle && descriptorError == null
              ? (value) => setState(() => _forceClaim = value)
              : null,
        ),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton(
              key: const Key('claim'),
              onPressed: usable ? () => _interfaceOperation(claim: true) : null,
              child: const Text('Claim'),
            ),
            ElevatedButton(
              key: const Key('release'),
              onPressed: usable
                  ? () => _interfaceOperation(claim: false)
                  : null,
              child: const Text('Release'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final selection = _selectionVersion;
    final scan = _scanVersion;
    return MaterialApp(
      title: 'USB Host diagnostics',
      home: Scaffold(
        appBar: AppBar(title: const Text('USB Host diagnostics')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ElevatedButton(
              key: const Key('refresh'),
              onPressed: () => _refresh(),
              child: const Text('Refresh devices'),
            ),
            _statusLine(
              'scan-status',
              _refreshing ? 'Enumerating devices…' : 'Enumeration: idle',
            ),
            _statusLine(
              'scan-error',
              'Enumeration error: ${_scanError ?? '—'}',
            ),
            _statusLine(
              'device-list-status',
              _devices.isEmpty && !_refreshing
                  ? (_scanError == null
                        ? 'No USB devices connected'
                        : 'Device list unavailable')
                  : 'Devices: ${_devices.length}',
            ),
            DropdownButton<String>(
              key: const Key('devices'),
              // Android device paths are nonempty; empty is the UI-only None value.
              value: _selectedName ?? '',
              isExpanded: true,
              items: [
                const DropdownMenuItem(value: '', child: Text('None')),
                for (final entry in _devices.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      _deviceLabel(entry.key, entry.value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (name) {
                if (_current(selection) &&
                    scan == _scanVersion &&
                    name != null) {
                  _select(name.isEmpty ? null : name);
                }
              },
            ),
            const Divider(),
            _statusLine(
              'selected-device',
              device == null
                  ? 'No device selected'
                  : 'Selected: $_selectedName',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            _statusLine(
              'device-info',
              device == null
                  ? 'Device: —'
                  : _deviceLabel(_selectedName!, device),
            ),
            _statusLine(
              'permission-status',
              _checkingPermission
                  ? 'Checking permission…'
                  : 'Permission: ${_permission == null
                        ? 'unknown'
                        : _permission!
                        ? 'granted'
                        : 'not granted'}',
            ),
            _statusLine('connection-status', 'Connection: $_connectionState'),
            _statusLine(
              'operation-status',
              _idle
                  ? 'Operation: —'
                  : _operation == null
                  ? 'Closing previous connection…'
                  : 'Running: $_operation',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  key: const Key('permission'),
                  onPressed:
                      device != null &&
                          _idle &&
                          !_checkingPermission &&
                          _permission != true
                      ? _requestPermission
                      : null,
                  child: const Text('Request Permission'),
                ),
                ElevatedButton(
                  key: const Key('open'),
                  onPressed:
                      device != null &&
                          _idle &&
                          !_checkingPermission &&
                          _permission == true &&
                          _connection == null
                      ? _open
                      : null,
                  child: const Text('Open'),
                ),
                ElevatedButton(
                  key: const Key('close'),
                  onPressed: _idle && _connection != null ? _close : null,
                  child: const Text('Close'),
                ),
                ElevatedButton(
                  key: const Key('read'),
                  onPressed: _idle && _connection != null
                      ? _readConnection
                      : null,
                  child: const Text('Read FD / raw descriptors'),
                ),
              ],
            ),
            _statusLine(
              'file-descriptor',
              'File descriptor: ${_fileDescriptor ?? ''}',
            ),
            SizedBox(
              key: const Key('raw-panel'),
              height: 80,
              child: SingleChildScrollView(
                key: const PageStorageKey('raw-scroll'),
                controller: _rawScroll,
                primary: false,
                child: SelectableText(
                  // Its internal text scroll must not overwrite the panel's
                  // independent PageStorage offset when both are disposed.
                  key: const PageStorageKey('raw-text'),
                  'Raw descriptors: ${_rawDescriptors ?? ''}',
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              key: const Key('descriptor-panel'),
              height: 300,
              child: SingleChildScrollView(
                key: const PageStorageKey('descriptor-scroll'),
                controller: _descriptorScroll,
                primary: false,
                child: device == null
                    ? const Text('Descriptors: —')
                    : _descriptorDetails(device),
              ),
            ),
            const Divider(),
            _interfaceControls(),
            const Divider(),
            const Text('Log'),
            Container(
              key: const Key('console-panel'),
              height: 330,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              color: Colors.black,
              child: Scrollbar(
                controller: _consoleScroll,
                child: ListView.builder(
                  key: const Key('console'),
                  controller: _consoleScroll,
                  primary: false,
                  padding: EdgeInsets.zero,
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    return Text(
                      message.text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: message.color,
                      ),
                    );
                  },
                ),
              ),
            ),
            ElevatedButton(
              key: const Key('clear'),
              onPressed: () {
                setState(_messages.clear);
                if (_consoleScroll.hasClients) _consoleScroll.jumpTo(0);
              },
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    );
  }
}
