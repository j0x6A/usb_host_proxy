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

  /// Calls the selector callback by public list key; empty is its UI None value.
  /// Popup mechanics are exercised separately from controlled-future race cases.
  Future<void> select(WidgetTester tester, String name) async {
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const Key('devices')),
    );
    expect(dropdown.items!.any((item) => item.value == name), isTrue);
    dropdown.onChanged!(name);
    await tester.pumpAndSettle();
  }

  /// Reads menu values without depending on which popup rows are currently painted.
  List<String?> deviceChoices(WidgetTester tester) => tester
      .widget<DropdownButton<String>>(find.byKey(const Key('devices')))
      .items!
      .map((item) => item.value)
      .toList();

  /// Chooses a descriptor index, or -1 for None, without performing USB work.
  Future<void> selectInterface(WidgetTester tester, int index) async {
    tester
        .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
        .onChanged!(index);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Enumerates automatically, handles empty state and attach refresh',
    (tester) async {
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
      expect(deviceChoices(tester), ['', 'A']);
      expect(find.text('No device selected'), findsOneWidget);
      await select(tester, 'A');
      expect(find.textContaining('VID 0x1111 / PID 0x2222'), findsWidgets);
      expect(find.textContaining('Configuration 0: value 1'), findsOneWidget);
      expect(find.textContaining('Endpoint 0x0081'), findsWidgets);
      expect(find.text('Permission: not granted'), findsOneWidget);
      expect(manager.requests, 0);
      await press(tester, 'refresh');
      expect(manager.scans, 3);
      expect(manager.opens, 0);
    },
  );

  testWidgets(
    'Permission denial/grant, open, descriptors, claim/release and close',
    (tester) async {
      await launch(tester);
      await select(tester, 'A');
      expect(enabled(tester, 'open'), isFalse);
      manager.requestResult = false;
      await press(tester, 'permission');
      expect(
        find.text('Request Permission: not granted (denied or detached)'),
        findsOneWidget,
      );
      expect(enabled(tester, 'open'), isFalse);
      manager.requestResult = true;
      await press(tester, 'permission');
      expect(find.text('Permission: granted'), findsOneWidget);
      expect(enabled(tester, 'permission'), isFalse);
      await press(tester, 'open');
      expect(find.text('Connection: Open'), findsOneWidget);
      expect(find.text('No interface selected'), findsOneWidget);
      expect(enabled(tester, 'claim'), isFalse);
      await selectInterface(tester, 0);
      expect(enabled(tester, 'open'), isFalse);
      await press(tester, 'read');
      expect(find.text('File descriptor: 42'), findsOneWidget);
      expect(find.textContaining('3 bytes: 01 02 ff'), findsOneWidget);
      // Release is offered before Claim; its actual result is not inferred by UI.
      connection.releaseResult = false;
      await press(tester, 'release');
      expect(find.text('Release interface 0: false'), findsOneWidget);
      expect(connection.claims, 0);
      connection.claimResult = false;
      await press(tester, 'claim');
      expect(find.text('Claim interface 0: false'), findsOneWidget);
      expect(enabled(tester, 'claim'), isTrue);
      expect(enabled(tester, 'release'), isTrue);
      connection.claimResult = true;
      await press(tester, 'claim');
      expect(connection.lastInterface, same(first.interfaces[0]));
      expect(connection.lastForce, isFalse);
      expect(enabled(tester, 'claim'), isTrue);
      await press(tester, 'claim');
      expect(connection.claims, 3);
      // Selecting an alternate descriptor never performs an implicit USB operation.
      tester
          .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
          .onChanged!(1);
      await tester.pumpAndSettle();
      expect(connection.claims, 3);
      expect(connection.releases, 1);
      await press(tester, 'release');
      expect(enabled(tester, 'claim'), isTrue);
      expect(enabled(tester, 'release'), isTrue);
      await press(tester, 'release');
      expect(connection.releases, 3);
      connection.releaseResult = true;
      await press(tester, 'release');
      expect(connection.lastInterface, same(first.interfaces[1]));
      expect(find.text('Release interface 0: true'), findsOneWidget);
      expect(enabled(tester, 'release'), isTrue);
      await press(tester, 'close');
      expect(connection.closes, 1);
      expect(find.text('Connection: Closed'), findsOneWidget);
      expect(find.text('File descriptor: 42'), findsNothing);
      expect(enabled(tester, 'read'), isFalse);
    },
  );

  testWidgets(
    'Native null and exceptions are visible without a fictitious connection',
    (tester) async {
      manager.permissions['A'] = true;
      manager.onOpen = (_) async => null;
      await launch(tester);
      await select(tester, 'A');
      await press(tester, 'open');
      expect(find.textContaining('Open returned null'), findsOneWidget);
      expect(enabled(tester, 'close'), isFalse);
      manager.onOpen = (_) async => throw StateError('open denied');
      await press(tester, 'open');
      expect(
        find.textContaining('Open failed: Bad state: open denied'),
        findsOneWidget,
      );
      expect(find.text('Connection: Closed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Latest enumeration wins even when an older scan finishes last', (
    tester,
  ) async {
    final oldScan = Completer<Map<String, UsbDevice>>();
    manager.onScan = () => oldScan.future;
    await launch(tester);
    manager.onScan = () async => {'B': second};
    await press(tester, 'refresh');
    oldScan.complete({'A': first});
    await tester.pumpAndSettle();
    expect(deviceChoices(tester), ['', 'B']);
  });

  testWidgets('Late permission checks do not overwrite the next selection', (
    tester,
  ) async {
    final oldCheck = Completer<bool>();
    manager.onCheck = (device) =>
        device == first ? oldCheck.future : Future.value(false);
    await launch(tester);
    await select(tester, 'A');
    await select(tester, 'B');
    oldCheck.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Selected: B'), findsOneWidget);
    expect(find.text('Permission: not granted'), findsOneWidget);
    expect(enabled(tester, 'open'), isFalse);
  });

  testWidgets(
    'A pending permission decision cannot grant access to another selection',
    (tester) async {
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
    },
  );

  testWidgets(
    'Late open is closed and new open stays blocked until cleanup finishes',
    (tester) async {
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
    },
  );

  testWidgets('Selection change closes the previous published connection', (
    tester,
  ) async {
    manager.permissions['A'] = true;
    await launch(tester);
    await select(tester, 'A');
    await press(tester, 'open');
    await select(tester, 'B');
    expect(connection.closes, 1);
    expect(find.text('Connection: Closed'), findsOneWidget);
    expect(enabled(tester, 'release'), isFalse);
  });

  testWidgets(
    'Enumeration absence invalidates selection even without a detach event',
    (tester) async {
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
    },
  );

  testWidgets(
    'Descriptor errors remain visible without hiding VID/PID or crashing',
    (tester) async {
      first.productError = true;
      await launch(tester);
      await select(tester, 'A');
      expect(find.textContaining('VID 0x1111 / PID 0x2222'), findsWidgets);
      expect(find.textContaining('Product name error:'), findsOneWidget);
      expect(find.textContaining('Descriptor error:'), findsOneWidget);
      expect(find.text('Permission: not granted'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Detach discards late Claim results even if the same name returns before completion',
    (tester) async {
      manager.permissions['A'] = true;
      final claimed = Completer<bool>();
      connection.onClaim = () => claimed.future;
      await launch(tester);
      await select(tester, 'A');
      await press(tester, 'open');
      await selectInterface(tester, 0);
      final oldInterfaceChoice = tester
          .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
          .onChanged!;
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
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
            .value,
        -1,
      );
      claimed.complete(true);
      await tester.pumpAndSettle();
      expect(connection.closes, 1);
      expect(find.text('Connection: Closed'), findsOneWidget);
      expect(find.text('Claim interface 0: true'), findsNothing);
      expect(enabled(tester, 'release'), isFalse);
    },
  );

  testWidgets(
    'Late FD read does not invoke another operation on the old connection',
    (tester) async {
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
    },
  );

  testWidgets(
    'Disposal cancels both subscriptions and closes the owned connection',
    (tester) async {
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
    },
  );

  testWidgets('A connection returned after screen disposal is still closed', (
    tester,
  ) async {
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
    expect(
      find.text('Connection: Closed; native cleanup not confirmed'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Close failed: Bad state: close error'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Both selectors start at None and None closes without releasing',
    (tester) async {
      await launch(tester);
      expect(deviceChoices(tester), ['', 'A', 'B']);
      final devices = tester.widget<DropdownButton<String>>(
        find.byKey(const Key('devices')),
      );
      expect(devices.value, '');
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
            .value,
        -1,
      );
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
            .items!
            .length,
        1,
      );
      await select(tester, 'B');
      expect(find.text('No interface selected'), findsOneWidget);
      await press(tester, 'open');
      expect(find.text('No interface selected'), findsOneWidget);
      expect(connection.claims, 0);
      await selectInterface(tester, 0);
      await press(tester, 'claim');
      await selectInterface(tester, -1);
      expect(connection.releases, 0);
      expect(enabled(tester, 'claim'), isFalse);
      expect(enabled(tester, 'release'), isFalse);
      await selectInterface(tester, 1);
      expect(find.text('Interface 0: selected'), findsOneWidget);
      expect(connection.claims, 1);
      expect(connection.releases, 0);
      await select(tester, '');
      expect(find.text('No device selected'), findsOneWidget);
      expect(connection.closes, 1);
      expect(connection.releases, 0);
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
            .value,
        -1,
      );
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('interfaces')))
            .items!
            .length,
        1,
      );
    },
  );

  testWidgets(
    'Force forwards user choice and native results never lock out Claim or Release',
    (tester) async {
      second.interfaces.add(FakeInterface(0, number: 1));
      await launch(tester);
      await select(tester, 'B');
      await press(tester, 'open');
      await selectInterface(tester, 0);
      expect(find.text('Force claim: OFF'), findsOneWidget);
      tester.widget<SwitchListTile>(find.byKey(const Key('force'))).onChanged!(
        true,
      );
      await tester.pumpAndSettle();
      connection.claimResult = false;
      await press(tester, 'claim');
      expect(connection.lastForce, isTrue);
      expect(find.text('Claim interface 0: false'), findsOneWidget);
      expect(enabled(tester, 'release'), isTrue);
      connection.claimResult = true;
      await press(tester, 'claim');
      await selectInterface(tester, 2);
      expect(find.text('Interface 1: selected'), findsOneWidget);
      expect(connection.claims, 2);
      expect(connection.releases, 0);
      await press(tester, 'claim');
      connection.releaseResult = false;
      await press(tester, 'release');
      expect(find.text('Release interface 1: false'), findsOneWidget);
      expect(enabled(tester, 'claim'), isTrue);
      await selectInterface(tester, 1);
      expect(find.text('Interface 0: selected'), findsOneWidget);
      connection.onRelease = () async => throw StateError('release validation');
      await press(tester, 'release');
      expect(enabled(tester, 'claim'), isTrue);
      expect(enabled(tester, 'release'), isTrue);
      expect(
        find.textContaining('Release failed: Bad state: release validation'),
        findsOneWidget,
      );
      connection.onClaim = () async => throw StateError('native claim');
      await press(tester, 'claim');
      expect(
        find.textContaining('Claim failed: Bad state: native claim'),
        findsOneWidget,
      );
      expect(enabled(tester, 'claim'), isTrue);
      expect(enabled(tester, 'release'), isTrue);
      await press(tester, 'close');
      expect(connection.closes, 1);
      await press(tester, 'open');
      expect(find.text('No interface selected'), findsOneWidget);
      await selectInterface(tester, 0);
      expect(find.text('Interface 0: selected'), findsOneWidget);
    },
  );

  testWidgets(
    'Empty selectors keep None visible and USB attach does not select',
    (tester) async {
      manager.devices.clear();
      await launch(tester);
      expect(deviceChoices(tester), ['']);
      expect(find.byKey(const Key('interfaces')), findsOneWidget);
      // Use the actual popup as well as callback-based race fixtures above.
      await tester.tap(find.byKey(const Key('devices')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None').last);
      await tester.pumpAndSettle();
      manager.devices['B'] = second;
      manager.attached.add(second);
      await tester.pumpAndSettle();
      expect(find.text('No device selected'), findsOneWidget);
      expect(manager.opens, 0);
      expect(manager.requests, 0);
      expect(connection.claims, 0);
    },
  );

  testWidgets(
    'Console colors distinguish USB events, results, errors and information',
    (tester) async {
      await launch(tester);

      /// Reads the rendered entry, rather than reproducing the production category map.
      Color? logColor(String message) => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('console')),
              matching: find.text(message),
            ),
          )
          .style!
          .color;

      manager.attached.add(first);
      manager.detached.add(second);
      await tester.pumpAndSettle();
      expect(logColor('Attached: A'), const Color(0xFF55D9EF));
      expect(logColor('Detached: B'), const Color(0xFF55D9EF));

      await select(tester, 'A');
      await press(tester, 'permission');
      expect(
        logColor('Request Permission: not granted (denied or detached)'),
        const Color(0xFFF6BE55),
      );
      manager.requestResult = true;
      await press(tester, 'permission');
      expect(logColor('Request Permission: granted'), const Color(0xFF45D483));

      manager.onOpen = (_) async => null;
      await press(tester, 'open');
      expect(
        logColor('Open returned null; no connection was created'),
        const Color(0xFFF6BE55),
      );
      manager.onOpen = (_) async => connection;
      await press(tester, 'open');
      expect(logColor('Open: connected'), const Color(0xFF45D483));
      await press(tester, 'read');
      expect(
        logColor('Read connection: fd=42, raw=3'),
        const Color(0xFF45D483),
      );
      connection.onFileDescriptor = () async => -1;
      await press(tester, 'read');
      expect(
        logColor('Read connection: fd=-1, raw=3'),
        const Color(0xFFF6BE55),
      );

      await selectInterface(tester, 0);
      connection.claimResult = false;
      await press(tester, 'claim');
      expect(logColor('Claim interface 0: false'), const Color(0xFFF6BE55));
      connection.claimResult = true;
      await press(tester, 'claim');
      expect(logColor('Claim interface 0: true'), const Color(0xFF45D483));
      connection.releaseResult = false;
      await press(tester, 'release');
      expect(logColor('Release interface 0: false'), const Color(0xFFF6BE55));
      connection.releaseResult = true;
      await press(tester, 'release');
      expect(logColor('Release interface 0: true'), const Color(0xFF45D483));

      // Words resembling other categories do not override the explicit error category.
      connection.onClaim = () async => throw StateError('Attached: true');
      await press(tester, 'claim');
      expect(
        logColor('Claim failed: Bad state: Attached: true'),
        const Color(0xFFFF7070),
      );
      await press(tester, 'close');
      expect(logColor('Close: closed'), const Color(0xFF45D483));

      manager.devices.remove('A');
      await press(tester, 'refresh');
      expect(
        logColor('Selected device is no longer present'),
        const Color(0xFFAAAAAA),
      );
    },
  );

  testWidgets('Console is chronological, bounded and follows only its tail', (
    tester,
  ) async {
    await launch(tester);
    await tester.ensureVisible(find.byKey(const Key('console')));
    final console = tester.widget<SingleChildScrollView>(
      find.byKey(const Key('console')),
    );
    final scroll = console.controller!;
    for (var i = 0; i < 25; i++) {
      manager.attached.add(FakeDevice('event-$i'));
      await tester.pump();
      await tester.pump();
    }
    final lines = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const Key('console')),
            matching: find.byType(Text),
          ),
        )
        .toList();
    expect(lines.first.data, 'Attached: event-0');
    expect(lines.last.data, 'Attached: event-24');
    expect(lines.first.style!.fontFamily, 'monospace');
    expect(lines.first.style!.color, const Color(0xFF55D9EF));
    expect(scroll.position.extentAfter, closeTo(0, 0.1));
    scroll.jumpTo(0);
    await tester.pump();
    manager.attached.add(FakeDevice('older-reading'));
    await tester.pump();
    await tester.pump();
    expect(scroll.offset, 0);
    expect(scroll.position.extentAfter, greaterThan(0));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    for (var i = 25; i < 45; i++) {
      manager.attached.add(FakeDevice('event-$i'));
      await tester.pump();
      await tester.pump();
    }
    final retained = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const Key('console')),
            matching: find.byType(Text),
          ),
        )
        .toList();
    expect(retained.length, 40);
    expect(retained.first.data, 'Attached: event-6');
    expect(retained.last.data, 'Attached: event-44');
    expect(scroll.position.extentAfter, closeTo(0, 0.1));
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
      onCheck?.call(device) ??
      Future.value(permissions[device.getDeviceName()] ?? false);
  @override
  Future<bool> requestPermission(UsbDevice device) async {
    requests++;
    final allowed =
        await (onRequest?.call(device) ?? Future.value(requestResult));
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

/// Records calls and arguments, without simulating Android's ownership or native queue.
/// Unsupported methods deliberately fail rather than silently simulating transport.
class FakeConnection implements UsbDeviceConnection {
  /// Optional gates keep close/claim/read pending across selection or disposal.
  Future<void> Function()? onClose;
  Future<bool> Function()? onClaim;
  Future<bool> Function()? onRelease;
  Future<int> Function()? onFileDescriptor;
  bool releaseResult = true;
  bool claimResult = true;

  /// Captures original descriptor instances and the user's chosen force value.
  UsbInterface? lastInterface;
  bool? lastForce;

  /// Count attempts, including failures, so repeated cleanup cannot be hidden.
  int closes = 0;
  int claims = 0;
  int releases = 0;
  int rawReads = 0;
  @override
  Future<void> close() async {
    closes++;
    await onClose?.call();
  }

  @override
  Future<int> getFileDescriptor() =>
      onFileDescriptor?.call() ?? Future.value(42);
  @override
  Future<Uint8List?> getRawDescriptors() async {
    rawReads++;
    return Uint8List.fromList([1, 2, 255]);
  }

  @override
  Future<bool> claimInterface(UsbInterface intf, {bool force = false}) {
    claims++;
    lastInterface = intf;
    lastForce = force;
    return onClaim?.call() ?? Future.value(claimResult);
  }

  @override
  Future<bool> releaseInterface(UsbInterface intf) async {
    releases++;
    lastInterface = intf;
    return onRelease?.call() ?? releaseResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected connection call: ${invocation.memberName}',
  );
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
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected device call: ${invocation.memberName}',
  );
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

/// Alternate-setting fixture; the default number is shared, but tests can add others.
class FakeInterface implements UsbInterface {
  FakeInterface(this.alt, {this.number = 0});

  /// Alternate setting selector passed through the original descriptor.
  final int alt;

  /// Interface number; test descriptors may deliberately share it.
  final int number;
  @override
  int getId() => number;
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
