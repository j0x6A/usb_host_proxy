import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';
import 'package:usb_host_proxy_example/main.dart';

// These tests exercise UI policy and result ownership, not JNI or Android USB.
// Controlled futures model ordering explicitly; test timeouts are not permission
// timeouts. The screen is disposed before each fake's event controllers close.
void main() {
  late FakeManager manager;
  late FakeDevice first;
  late FakeDevice second;
  late FakeConnection connection;

  setUp(() {
    first = FakeDevice('A');
    second = FakeDevice('B');
    connection = FakeConnection();
    manager = FakeManager()
      ..devices = {'A': first, 'B': second}
      ..permissions = {'A': false, 'B': true}
      ..onOpen = (_) async => connection;
  });

  /// Makes controls/descriptor fixtures visible and owns teardown ordering.
  Future<void> launch(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 2200));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await manager.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(UsbDiagnosticsApp(manager: manager));
    await tester.pumpAndSettle();
  }

  /// Checks the actual callback, not only the button's displayed label.
  bool enabled(WidgetTester tester, String key) =>
      tester.widget<ElevatedButton>(find.byKey(Key(key))).onPressed != null;

  /// Exercises a user action and settles frames, not unresolved operation futures.
  Future<void> press(WidgetTester tester, String key) async {
    expect(enabled(tester, key), isTrue, reason: '$key should be enabled');
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  /// Selects by the public list key; no fake UUID or JNI reference is involved.
  Future<void> select(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.byKey(ValueKey('device-$name')));
    await tester.tap(find.byKey(ValueKey('device-$name')));
    await tester.pumpAndSettle();
  }

  testWidgets('Enumerates automatically, handles empty state and attach refresh', (tester) async {
    manager.devices.clear();
    await launch(tester);
    expect(manager.scans, 1);
    expect(find.text('No USB devices connected'), findsOneWidget);
    for (final key in ['permission', 'open', 'close', 'read']) {
      expect(enabled(tester, key), isFalse);
    }
    expect(manager.requests, 0);
    expect(manager.opens, 0);
    manager.devices['A'] = first;
    manager.attached.add(first);
    await tester.pumpAndSettle();
    expect(manager.scans, 2);
    expect(find.byKey(const ValueKey('device-A')), findsOneWidget);
    await select(tester, 'A');
    expect(find.textContaining('VID 0x1111 / PID 0x2222'), findsWidgets);
    expect(find.textContaining('Configuration 0: value 1'), findsOneWidget);
    expect(find.textContaining('Endpoint 0x0081'), findsWidgets);
    expect(find.text('Permission: not granted'), findsOneWidget);
    expect(manager.requests, 0);
    await press(tester, 'refresh');
    expect(manager.scans, 3);
    expect(manager.opens, 0);
  });

  testWidgets('Permission denial/grant, open, descriptors, claim/release and close', (tester) async {
    await launch(tester);
    await select(tester, 'A');
    expect(enabled(tester, 'open'), isFalse);
    manager.requestResult = false;
    await press(tester, 'permission');
    expect(find.text('Request Permission: not granted (denied or detached)'), findsOneWidget);
    expect(enabled(tester, 'open'), isFalse);
    manager.requestResult = true;
    await press(tester, 'permission');
    expect(find.text('Permission: granted'), findsOneWidget);
    expect(enabled(tester, 'permission'), isFalse);
    await press(tester, 'open');
    expect(find.text('Connection: Open'), findsOneWidget);
    expect(enabled(tester, 'open'), isFalse);
    await press(tester, 'read');
    expect(find.text('File descriptor: 42'), findsOneWidget);
    expect(find.textContaining('3 bytes: 01 02 ff'), findsOneWidget);
    connection.claimResult = false;
    await press(tester, 'claim');
    expect(find.text('Interface 0: unclaimed'), findsOneWidget);
    expect(enabled(tester, 'claim'), isTrue);
    connection.claimResult = true;
    await press(tester, 'claim');
    expect(connection.lastInterface, same(first.interfaces[0]));
    expect(connection.lastForce, isFalse);
    expect(find.text('Interface 0: claimed'), findsOneWidget);
    expect(enabled(tester, 'claim'), isFalse);
    // Alternate settings share the same interface-number ownership state.
    tester.widget<DropdownButton<int>>(find.byKey(const Key('interfaces'))).onChanged!(1);
    await tester.pumpAndSettle();
    expect(find.text('Interface 0: claimed'), findsOneWidget);
    connection.releaseResult = false;
    await press(tester, 'release');
    expect(find.text('Interface 0: claimed'), findsOneWidget);
    connection.releaseResult = true;
    await press(tester, 'release');
    expect(connection.lastInterface, same(first.interfaces[1]));
    expect(find.text('Interface 0: unclaimed'), findsOneWidget);
    expect(enabled(tester, 'release'), isFalse);
    await press(tester, 'close');
    expect(connection.closes, 1);
    expect(find.text('Connection: Closed'), findsOneWidget);
    expect(find.text('File descriptor: 42'), findsNothing);
    expect(enabled(tester, 'read'), isFalse);
  });

  testWidgets('Native null and exceptions are visible without a fictitious connection', (tester) async {
    manager.permissions['A'] = true;
    manager.onOpen = (_) async => null;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    expect(find.textContaining('Open returned null'), findsOneWidget);
    expect(enabled(tester, 'close'), isFalse);
    manager.onOpen = (_) async => throw StateError('open denied');
    await press(tester, 'open');
    expect(find.textContaining('Open failed: Bad state: open denied'), findsOneWidget);
    expect(find.text('Connection: Closed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Latest enumeration wins even when an older scan finishes last', (tester) async {
    final oldScan = Completer<Map<String, UsbDevice>>();
    manager.onScan = () => oldScan.future;
    await launch(tester);
    manager.onScan = () async => {'B': second};
    await press(tester, 'refresh');
    oldScan.complete({'A': first});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-B')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-A')), findsNothing);
  });

  testWidgets('Late permission checks do not overwrite the next selection', (tester) async {
    final oldCheck = Completer<bool>();
    manager.onCheck = (device) => device == first ? oldCheck.future : Future.value(false);
    await launch(tester);
    await select(tester, 'A');
    await select(tester, 'B');
    oldCheck.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Selected: B'), findsOneWidget);
    expect(find.text('Permission: not granted'), findsOneWidget);
    expect(enabled(tester, 'open'), isFalse);
  });

  testWidgets('A pending permission decision cannot grant access to another selection', (tester) async {
    final decision = Completer<bool>();
    manager.onRequest = (_) => decision.future;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'permission');
    await select(tester, 'B');
    expect(enabled(tester, 'open'), isFalse);
    decision.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Selected: B'), findsOneWidget);
    expect(find.text('Permission: granted'), findsOneWidget);
    expect(find.text('Request Permission: granted'), findsNothing);
    expect(enabled(tester, 'open'), isTrue);
  });

  testWidgets('Late open is closed and new open stays blocked until cleanup finishes', (tester) async {
    manager.permissions['A'] = true;
    final opened = Completer<UsbDeviceConnection?>();
    final closed = Completer<void>();
    manager.onOpen = (_) => opened.future;
    connection.onClose = () => closed.future;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    await select(tester, 'B');
    opened.complete(connection);
    await tester.pumpAndSettle();
    expect(connection.closes, 1);
    expect(enabled(tester, 'open'), isFalse);
    closed.complete();
    await tester.pumpAndSettle();
    expect(find.text('Selected: B'), findsOneWidget);
    expect(find.text('Connection: Closed'), findsOneWidget);
    expect(enabled(tester, 'open'), isTrue);
  });

  testWidgets('Selection change closes the previous published connection', (tester) async {
    manager.permissions['A'] = true;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    await select(tester, 'B');
    expect(connection.closes, 1);
    expect(find.text('Connection: Closed'), findsOneWidget);
    expect(enabled(tester, 'release'), isFalse);
  });

  testWidgets('Enumeration absence invalidates selection even without a detach event', (tester) async {
    manager.permissions['A'] = true;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    manager.devices.remove('A');
    await press(tester, 'refresh');
    expect(find.text('No device selected'), findsOneWidget);
    expect(connection.closes, 1);
    expect(enabled(tester, 'open'), isFalse);
    expect(enabled(tester, 'close'), isFalse);
  });

  testWidgets('Descriptor errors remain visible without hiding VID/PID or crashing', (tester) async {
    first.productError = true;
    await launch(tester);
    await select(tester, 'A');
    expect(find.textContaining('VID 0x1111 / PID 0x2222'), findsWidgets);
    expect(find.textContaining('Product name error:'), findsOneWidget);
    expect(find.textContaining('Descriptor error:'), findsOneWidget);
    expect(find.text('Permission: not granted'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Detach invalidates claims even if the same name returns before completion', (tester) async {
    manager.permissions['A'] = true;
    final claimed = Completer<bool>();
    connection.onClaim = () => claimed.future;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    final oldInterfaceChoice = tester.widget<DropdownButton<int>>(
      find.byKey(const Key('interfaces')),
    ).onChanged!;
    await press(tester, 'claim');
    manager.devices.remove('A');
    manager.detached.add(first);
    await tester.pumpAndSettle();
    expect(find.text('No device selected'), findsOneWidget);
    final replacement = FakeDevice('A');
    manager.devices['A'] = replacement;
    manager.attached.add(replacement);
    await tester.pumpAndSettle();
    await select(tester, 'A');
    oldInterfaceChoice(1);
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(
      find.byKey(const Key('interfaces')),
    ).value, 0);
    claimed.complete(true);
    await tester.pumpAndSettle();
    expect(connection.closes, 1);
    expect(find.text('Connection: Closed'), findsOneWidget);
    expect(find.text('Interface 0: claimed'), findsNothing);
    expect(enabled(tester, 'release'), isFalse);
  });

  testWidgets('Late FD read does not invoke another operation on the old connection', (tester) async {
    manager.permissions['A'] = true;
    final fd = Completer<int>();
    connection.onFileDescriptor = () => fd.future;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    await press(tester, 'read');
    await select(tester, 'B');
    fd.complete(99);
    await tester.pumpAndSettle();
    expect(connection.rawReads, 0);
    expect(find.text('File descriptor: 99'), findsNothing);
    expect(find.text('Selected: B'), findsOneWidget);
  });

  testWidgets('Disposal cancels both subscriptions and closes the owned connection', (tester) async {
    manager.permissions['A'] = true;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(manager.attached.hasListener, isFalse);
    expect(manager.detached.hasListener, isFalse);
    expect(connection.closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A connection returned after screen disposal is still closed', (tester) async {
    manager.permissions['A'] = true;
    final opened = Completer<UsbDeviceConnection?>();
    manager.onOpen = (_) => opened.future;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    await tester.pumpWidget(const SizedBox());
    opened.complete(connection);
    await tester.pump();
    expect(connection.closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Discovery and close errors remain explicit', (tester) async {
    manager.onScan = () async => throw StateError('USB service unavailable');
    await launch(tester);
    expect(find.textContaining('Enumeration error:'), findsOneWidget);
    expect(find.text('Device list unavailable'), findsOneWidget);
    manager.onScan = null;
    manager.permissions['A'] = true;
    await press(tester, 'refresh');
    await select(tester, 'A');
    await press(tester, 'open');
    connection.onClose = () async => throw StateError('close error');
    await press(tester, 'close');
    expect(find.text('Connection: Close failed; native state unknown'), findsOneWidget);
    expect(find.textContaining('Close failed: Bad state: close error'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Independent controls for discovery, permission, open results and USB events.
/// Emitting an event does not mutate discovery: each test sets both explicitly.
class FakeManager extends UsbManager {
  /// Default scan snapshot and per-name authorization, used unless overridden.
  Map<String, UsbDevice> devices = {};
  Map<String, bool> permissions = {};
  final attached = StreamController<UsbDevice>.broadcast(sync: true);
  final detached = StreamController<UsbDevice>.broadcast(sync: true);
  /// Hooks return controlled futures or throw to exercise stale/error paths.
  Future<Map<String, UsbDevice>> Function()? onScan;
  Future<bool> Function(UsbDevice)? onCheck;
  Future<bool> Function(UsbDevice)? onRequest;
  Future<UsbDeviceConnection?> Function(UsbDevice)? onOpen;
  /// Default request result; successful completion updates only its device name.
  bool requestResult = false;
  /// Observable side effects: initial discovery must not imply request or open.
  int scans = 0;
  int requests = 0;
  int opens = 0;

  @override
  Stream<UsbDevice> get deviceAttached => attached.stream;
  @override
  Stream<UsbDevice> get deviceDetached => detached.stream;
  @override
  Future<Map<String, UsbDevice>> getDeviceList() {
    scans++;
    return onScan?.call() ?? Future.value(Map.of(devices));
  }
  @override
  Future<bool> hasPermission(UsbDevice device) =>
      onCheck?.call(device) ?? Future.value(permissions[device.getDeviceName()] ?? false);
  @override
  Future<bool> requestPermission(UsbDevice device) async {
    requests++;
    final allowed = await (onRequest?.call(device) ?? Future.value(requestResult));
    permissions[device.getDeviceName()] = allowed;
    return allowed;
  }
  @override
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) {
    opens++;
    return onOpen?.call(device) ?? Future.value(null);
  }
  /// Called only after the widget has relinquished both subscriptions.
  Future<void> dispose() async {
    await attached.close();
    await detached.close();
  }
}

/// Records ownership and arguments; it does not reproduce Android's native queue.
/// Unsupported methods deliberately fail rather than silently simulating transport.
class FakeConnection implements UsbDeviceConnection {
  /// Optional gates keep close/claim/read pending across selection or disposal.
  Future<void> Function()? onClose;
  Future<bool> Function()? onClaim;
  Future<int> Function()? onFileDescriptor;
  bool releaseResult = true;
  bool claimResult = true;
  /// Checks that the UI passes original descriptor instances and force:false.
  UsbInterface? lastInterface;
  bool? lastForce;
  /// Count attempts, including failures, so repeated cleanup cannot be hidden.
  int closes = 0;
  int rawReads = 0;
  @override
  Future<void> close() async {
    closes++;
    await onClose?.call();
  }
  @override
  Future<int> getFileDescriptor() => onFileDescriptor?.call() ?? Future.value(42);
  @override
  Future<Uint8List?> getRawDescriptors() async {
    rawReads++;
    return Uint8List.fromList([1, 2, 255]);
  }
  @override
  Future<bool> claimInterface(UsbInterface intf, {bool force = false}) {
    lastInterface = intf;
    lastForce = force;
    return onClaim?.call() ?? Future.value(claimResult);
  }
  @override
  Future<bool> releaseInterface(UsbInterface intf) async {
    lastInterface = intf;
    return releaseResult;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected connection call: ${invocation.memberName}');
}

/// Synthetic descriptors only; these test IDs are not an application hardware filter.
class FakeDevice implements UsbDevice {
  FakeDevice(this.name);
  final String name;
  /// Independent optional-string failure, leaving VID/PID readable.
  bool productError = false;
  /// Two alternate settings sharing interface number zero.
  final interfaces = [FakeInterface(0), FakeInterface(1)];
  @override
  String getDeviceName() => name;
  @override
  int getVendorId() => 0x1111;
  @override
  int getProductId() => 0x2222;
  @override
  String getProductName() {
    if (productError) throw StateError('product unavailable');
    return 'Test device $name';
  }
  @override
  String getManufacturerName() => 'Fake';
  @override
  String getVersion() => '1.0';
  @override
  int getDeviceId() => 1;
  @override
  int getDeviceClass() => 0;
  @override
  int getDeviceSubclass() => 0;
  @override
  int getDeviceProtocol() => 0;
  @override
  int getConfigurationCount() => 1;
  @override
  UsbConfiguration getConfiguration(int index) => FakeConfiguration(interfaces);
  @override
  int getInterfaceCount() => interfaces.length;
  @override
  UsbInterface getInterface(int index) => interfaces[index];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected device call: ${invocation.memberName}');
}

/// One descriptive configuration; neither fixture nor UI switches configuration.
class FakeConfiguration implements UsbConfiguration {
  FakeConfiguration(this.interfaces);
  final List<UsbInterface> interfaces;
  @override
  int getId() => 1;
  @override
  String? getName() => null;
  @override
  int getMaxPower() => 100;
  @override
  bool isSelfPowered() => false;
  @override
  bool isRemoteWakeup() => false;
  @override
  int getInterfaceCount() => interfaces.length;
  @override
  UsbInterface getInterface(int index) => interfaces[index];
}

/// Alternate-setting fixture whose interface number is intentionally constant.
class FakeInterface implements UsbInterface {
  FakeInterface(this.alt);
  final int alt;
  @override
  int getId() => 0;
  @override
  int getAlternateSetting() => alt;
  @override
  String? getName() => null;
  @override
  int getInterfaceClass() => 255;
  @override
  int getInterfaceSubclass() => 0;
  @override
  int getInterfaceProtocol() => 0;
  @override
  int getEndpointCount() => 1;
  @override
  UsbEndpoint getEndpoint(int index) => FakeEndpoint();
}

/// A bulk IN descriptor; its presence never submits a USB transfer.
class FakeEndpoint implements UsbEndpoint {
  @override
  int getAddress() => 0x81;
  @override
  int getAttributes() => 2;
  @override
  int getDirection() => UsbConstants.USB_DIR_IN;
  @override
  int getEndpointNumber() => 1;
  @override
  int getInterval() => 0;
  @override
  int getMaxPacketSize() => 64;
  @override
  int getType() => UsbConstants.USB_ENDPOINT_XFER_BULK;
}
