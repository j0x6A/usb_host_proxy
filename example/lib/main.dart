import 'dart:async';

import 'package:flutter/material.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

/// Uses the real public manager in the Android engine's root isolate.
void main() => runApp(UsbDiagnosticsApp());

/// Launcher-started diagnostics. Tests supply a manager without starting JNI.
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
  /// Selected list key, not the plugin's private attachment UUID.
  String? _selectedName;
  /// Retained original selection; not replaced by a new adapter on each scan.
  UsbDevice? _device;
  /// Original flattened interface references used as claim/release arguments.
  List<UsbInterface> _interfaces = [];
  /// Descriptor index into [_interfaces], not bInterfaceNumber.
  int? _interfaceIndex;
  /// The sole published connection; cleared before cleanup hands it to a future.
  UsbDeviceConnection? _connection;

  // Claim results belong to interface numbers on this connection, not alt settings.
  final Set<int> _claimed = {};
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
  /// Bounded, newest-first diagnostics; no persistent logging or replay service.
  final List<String> _messages = [];

  // Versions arbitrate results, not device identity (the private UUID stays native).
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
        onError: (Object error) => _log('Attach stream error: $error'),
      );
      _detached = widget.manager.deviceDetached.listen(
        (device) => _deviceEvent(device, attached: false),
        onError: (Object error) => _log('Detach stream error: $error'),
      );
    } catch (error) {
      _log('USB event subscription failed: $error');
    }
    unawaited(_refresh());
  }

  /// Reports visible results, or cleanup messages to debug output after disposal.
  void _log(String message) {
    if (!_alive) {
      debugPrint('USB diagnostics: $message');
      return;
    }
    setState(() {
      _messages.insert(0, message);
      if (_messages.length > 40) _messages.removeLast();
    });
  }

  /// Invalidates the selected name on detach, then requests a fresh public list.
  void _deviceEvent(UsbDevice device, {required bool attached}) {
    if (!_alive) return;
    try {
      final name = device.getDeviceName();
      _log('${attached ? 'Attached' : 'Detached'}: $name');
      if (!attached) {
        setState(() => _devices.remove(name));
        // Public adapters are not identity tokens. Never compare Dart wrappers
        // to correlate enumerations; a delivered detach invalidates this name.
        if (_selectedName == name) _select(null);
      }
    } catch (error) {
      _log('USB event descriptor error: $error');
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
        _log('Selected device is no longer present');
        _select(null);
      }
      // Keep the attachment wrapper across continuous enumeration, even when
      // Android returns a new Dart adapter for the same underlying attachment.
      if (_device != null && _idle) {
        unawaited(_checkPermission(_device!, _selectionVersion));
      }
    } catch (error) {
      if (_alive && scan == _scanVersion) {
        setState(() => _scanError = '$error');
        _log('Enumeration failed: $error');
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
      _claimed.clear();
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
        for (var i = 0; i < device.getInterfaceCount(); i++) device.getInterface(i),
      ];
      setState(() {
        _interfaces = interfaces;
        _interfaceIndex = interfaces.isEmpty ? null : 0;
      });
    } catch (error) {
      _log('Interface enumeration failed: $error');
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
        _log('hasPermission failed: $error');
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
      _log('$label${_current(version) ? '' : ' (previous selection)'} failed: $error');
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
  Future<void> _closeOwned(UsbDeviceConnection connection, String reason) async {
    if (_alive) setState(() => _pendingActions++);
    try {
      await connection.close();
      _log('$reason: closed');
    } catch (error) {
      _log('$reason failed; native close state is unknown: $error');
    } finally {
      if (_alive) setState(() => _pendingActions--);
    }
  }

  /// The only path requesting a system decision; reads actual permission after it.
  Future<void> _requestPermission() => _run('Request Permission', (version) async {
    final device = _device;
    if (device == null || _permission == true || _checkingPermission) return;
    ++_permissionVersion; // Invalidate older automatic hasPermission results.
    setState(() => _checkingPermission = false);
    final allowed = await widget.manager.requestPermission(device);
    if (!_current(version)) return;
    _log('Request Permission: ${allowed ? 'granted' : 'not granted (denied or detached)'}');
    await _checkPermission(device, version);
  });

  /// Adopts a native result only for the current selection, otherwise closes it.
  Future<void> _open() => _run('Open', (version) async {
    final device = _device;
    if (device == null || _permission != true || _checkingPermission || _connection != null) return;
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
        _log('Open returned null; no connection was created');
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
    });
    _log('Open: connected');
  });

  /// Transfers connection ownership to this call before awaiting native close.
  Future<void> _close() => _run('Close', (version) async {
    final connection = _connection;
    if (connection == null) return;
    setState(() {
      _connection = null;
      _connectionState = 'Closing…';
      _claimed.clear();
      _fileDescriptor = null;
      _rawDescriptors = null;
    });
    try {
      await connection.close();
      if (_current(version)) {
        setState(() => _connectionState = 'Closed');
        _log('Close: closed');
      }
    } catch (_) {
      if (_current(version)) {
        setState(() => _connectionState = 'Close failed; native state unknown');
      }
      rethrow;
    }
  });

  /// Reads connection metadata, not USB transport; publishes only a complete pair.
  /// A change between the two awaits prevents further access to the old handle.
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
    _log('Read connection: fd=$fd, raw=${raw?.length ?? 'null'}');
  });

  /// Uses original descriptors; false preserves the last confirmed local claim state.
  Future<void> _interfaceOperation({required bool claim}) =>
      _run(claim ? 'Claim' : 'Release', (version) async {
        final connection = _connection;
        final index = _interfaceIndex;
        if (connection == null || index == null) return;
        final intf = _interfaces[index];
        final id = intf.getId();
        if (claim == _claimed.contains(id)) return;
        final success = claim
            ? await connection.claimInterface(intf, force: false)
            : await connection.releaseInterface(intf);
        if (!_current(version) || !identical(connection, _connection)) return;
        if (success) {
          setState(() {
            if (claim) {
              _claimed.add(id);
            } else {
              _claimed.remove(id);
            }
          });
        }
        _log('${claim ? 'Claim' : 'Release'} interface $id: $success');
      });

  /// Settles subscription cleanup errors without an unhandled dispose-time future.
  Future<void> _cancel(StreamSubscription<UsbDevice>? subscription) async {
    try {
      await subscription?.cancel();
    } catch (error) {
      _log('Subscription cleanup failed: $error');
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
    if (connection != null) unawaited(_closeOwned(connection, 'Screen cleanup'));
    super.dispose();
  }

  /// Common VID/PID/address formatting; never changes values sent to Android.
  String _hex(int value) => '0x${value.toRadixString(16).padLeft(4, '0')}';

  /// Optional product-name failure must not hide readable VID/PID values.
  Widget _deviceTile(String name, UsbDevice device) {
    String subtitle;
    try {
      subtitle = 'VID ${_hex(device.getVendorId())} / PID ${_hex(device.getProductId())}';
    } catch (error) {
      subtitle = 'Descriptor error: $error';
    }
    try {
      subtitle += '\n${device.getProductName() ?? '(no product name)'}';
    } catch (error) {
      subtitle += '\nProduct name error: $error';
    }
    return ListTile(
      key: ValueKey('device-$name'),
      title: Text(name),
      subtitle: Text(subtitle),
      selected: name == _selectedName,
      onTap: () => _select(name),
    );
  }

  /// Displays all configurations without claiming or selecting any of them.
  Widget _descriptorDetails(UsbDevice device) {
    try {
      final lines = <Widget>[
        Text('Device: ${device.getDeviceName()}'),
        Text('VID ${_hex(device.getVendorId())} / PID ${_hex(device.getProductId())}'),
        Text('Product: ${device.getProductName() ?? '(unknown)'}'),
        Text('Manufacturer: ${device.getManufacturerName() ?? '(unknown)'}'),
        Text('Version: ${device.getVersion()} / ID: ${device.getDeviceId()}'),
        Text('Class ${device.getDeviceClass()}, subclass ${device.getDeviceSubclass()}, '
            'protocol ${device.getDeviceProtocol()}'),
      ];
      for (var c = 0; c < device.getConfigurationCount(); c++) {
        final config = device.getConfiguration(c);
        lines.add(Text('Configuration $c: value ${config.getId()}, '
            '${config.getName() ?? '(unnamed)'}, ${config.getMaxPower()} mA, '
            'self-powered=${config.isSelfPowered()}, wakeup=${config.isRemoteWakeup()}'));
        for (var i = 0; i < config.getInterfaceCount(); i++) {
          final intf = config.getInterface(i);
          lines.add(Text('  Interface ${intf.getId()}, alt ${intf.getAlternateSetting()}: '
              '${intf.getName() ?? '(unnamed)'}, class ${intf.getInterfaceClass()}, '
              'subclass ${intf.getInterfaceSubclass()}, protocol ${intf.getInterfaceProtocol()}'));
          for (var e = 0; e < intf.getEndpointCount(); e++) {
            final endpoint = intf.getEndpoint(e);
            lines.add(Text('    Endpoint ${_hex(endpoint.getAddress())}: '
                'direction=${endpoint.getDirection()}, type=${endpoint.getType()}, '
                'attributes=${endpoint.getAttributes()}, packet=${endpoint.getMaxPacketSize()}, '
                'interval=${endpoint.getInterval()}'));
          }
        }
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines);
    } catch (error) {
      return Text('Descriptor error: $error');
    }
  }

  /// Distinguishes descriptor index/alternate setting from connection claim ID.
  Widget _interfaceControls() {
    if (_interfaces.isEmpty) return const Text('No interfaces available');
    try {
      final id = _interfaces[_interfaceIndex!].getId();
      final claimed = _claimed.contains(id);
      final usable = _idle && _connection != null;
      final selection = _selectionVersion;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<int>(
            key: const Key('interfaces'),
            value: _interfaceIndex,
            isExpanded: true,
            items: [
              for (var i = 0; i < _interfaces.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    'Interface ${_interfaces[i].getId()}, '
                    'alt ${_interfaces[i].getAlternateSetting()} (descriptor $i)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _idle
                ? (index) {
                    // A dropdown route may return after detach or device selection.
                    if (_current(selection) && _idle && index != null) {
                      setState(() => _interfaceIndex = index);
                    }
                  }
                : null,
          ),
          Text('Interface $id: ${_connection == null ? 'no open connection' : claimed ? 'claimed' : 'unclaimed'}'),
          const Text('Claim state reflects successful operations on this connection. Force: false.'),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                key: const Key('claim'),
                onPressed: usable && !claimed ? () => _interfaceOperation(claim: true) : null,
                child: const Text('Claim'),
              ),
              ElevatedButton(
                key: const Key('release'),
                onPressed: usable && claimed ? () => _interfaceOperation(claim: false) : null,
                child: const Text('Release'),
              ),
            ],
          ),
        ],
      );
    } catch (error) {
      return Text('Interface descriptor error: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
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
            if (_refreshing) const Text('Enumerating devices…'),
            if (_scanError != null) Text('Enumeration error: $_scanError'),
            if (_devices.isEmpty && !_refreshing)
              Text(_scanError == null ? 'No USB devices connected' : 'Device list unavailable'),
            for (final entry in _devices.entries) _deviceTile(entry.key, entry.value),
            const Divider(),
            if (device == null) const Text('No device selected'),
            if (device != null) ...[
              Text('Selected: $_selectedName', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(_checkingPermission ? 'Checking permission…'
                  : 'Permission: ${_permission == null ? 'unknown' : _permission! ? 'granted' : 'not granted'}'),
              Text('Connection: $_connectionState'),
            ],
            if (!_idle) Text(_operation == null ? 'Closing previous connection…' : 'Running: $_operation'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  key: const Key('permission'),
                  onPressed: device != null && _idle && !_checkingPermission && _permission != true
                      ? _requestPermission : null,
                  child: const Text('Request Permission'),
                ),
                ElevatedButton(
                  key: const Key('open'),
                  onPressed: device != null && _idle && !_checkingPermission
                      && _permission == true && _connection == null ? _open : null,
                  child: const Text('Open'),
                ),
                ElevatedButton(
                  key: const Key('close'),
                  onPressed: _idle && _connection != null ? _close : null,
                  child: const Text('Close'),
                ),
                ElevatedButton(
                  key: const Key('read'),
                  onPressed: _idle && _connection != null ? _readConnection : null,
                  child: const Text('Read FD / raw descriptors'),
                ),
              ],
            ),
            if (_fileDescriptor != null) Text('File descriptor: $_fileDescriptor'),
            if (_rawDescriptors != null) SelectableText('Raw descriptors: $_rawDescriptors'),
            if (device != null) ...[
              const SizedBox(height: 12),
              _interfaceControls(),
              const Divider(),
              _descriptorDetails(device),
            ],
            const Divider(),
            const Text('Diagnostics (newest first, last 40 entries)'),
            for (final message in _messages) Text(message),
          ],
        ),
      ),
    );
  }
}
