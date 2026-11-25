import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jni/jni.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final manager = UsbManager();
  late JClass fixture;
  late int engineId;
  late UsbDeviceConnection connection;
  late UsbEndpoint input;
  late UsbEndpoint output;
  late UsbEndpoint unsupported;
  const deadline = Duration(seconds: 5);

  void fixtureAction(String method) {
    fixture.staticMethodId(method, '()V').call(fixture, jvoid.type, []);
  }

  Future<int> control(
    int request,
    Uint8List? buffer, {
    int type = 0x40,
    int offset = 0,
    int? length,
    int timeout = 0,
  }) => connection.controlTransfer(
    type,
    request,
    0x1234,
    0x4321,
    buffer,
    offset: offset,
    length: length,
    timeout: timeout,
  );

  Future<void> waitForBulkEntry() async {
    final method = fixture.staticMethodId('transferEntered', '()Z');
    final elapsed = Stopwatch()..start();
    while (!method.call(fixture, jboolean.type, [])) {
      if (elapsed.elapsed >= deadline) {
        fail('Bulk transfer did not reach Android');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUpAll(() {
    fixture = JClass.forName('dev.jx6A78.usb_host_proxy.TransferFixture');
    addTearDown(fixture.release);
    engineId = PlatformDispatcher.instance.engineId!;
    fixture.staticMethodId('install', '(J)V').call(fixture, jvoid.type, [
      engineId,
    ]);
    addTearDown(() {
      fixture.staticMethodId('dispose', '(J)V').call(fixture, jvoid.type, [
        engineId,
      ]);
    });
  });

  setUp(() async {
    fixtureAction('prepare');
    final device = (await manager.getDeviceList()).values.single;
    final intf = device.getInterface(0);
    input = intf.getEndpoint(0);
    output = intf.getEndpoint(1);
    unsupported = intf.getEndpoint(2);
    connection = (await manager.openDevice(device))!;
    addTearDown(() async {
      fixtureAction('resumeTransfer');
      await connection.close().timeout(deadline);
    });
  });

  testWidgets('bulk and control copy only the received prefix of a view', (
    _,
  ) async {
    final bulk = Uint8List.fromList([10, 11, 12, 13, 14, 15, 16]);
    expect(
      await connection.bulkTransfer(
        input,
        Uint8List.sublistView(bulk, 1, 6),
        offset: 1,
        length: 3,
        timeout: 91,
      ),
      2,
    );
    expect(bulk, [10, 11, 0x80, 0xff, 14, 15, 16]);

    final bytes = Uint8List.fromList([20, 21, 22, 23, 24, 25]);
    expect(
      await control(
        1,
        Uint8List.sublistView(bytes, 1, 5),
        type: 0xc0,
        offset: 1,
        timeout: 93,
      ),
      2,
    );
    expect(bytes, [20, 21, 0x80, 0xff, 24, 25]);
  });

  testWidgets('OUT snapshots its slice and accepts read-only sources', (
    _,
  ) async {
    final bulk = Uint8List.fromList([0, 1, 0xfe, 0x51, 0x42, 2, 3]);
    final sent = connection.bulkTransfer(
      output,
      Uint8List.sublistView(bulk, 1, 5),
      offset: 1,
      timeout: 92,
    );
    bulk[2] = 0;
    expect(await sent, 1);

    final bytes = Uint8List.fromList([0, 0xfe, 0x51, 0x42, 2]);
    expect(
      await control(
        2,
        bytes.asUnmodifiableView(),
        offset: 1,
        length: 3,
        timeout: 94,
      ),
      1,
    );
    expect(bytes, [0, 0xfe, 0x51, 0x42, 2]);
  });

  testWidgets('preserves negative and zero results and Android errors', (
    _,
  ) async {
    expect(await control(3, null), 0);
    expect(await control(7, Uint8List(0).asUnmodifiableView(), type: 0xc0), 0);
    final bytes = Uint8List.fromList([1, 2, 3]);
    expect(await control(6, bytes, type: 0xc0, timeout: 95), -7);
    expect(bytes, [1, 2, 3]);
    await expectLater(control(4, null), throwsArgumentError);
    try {
      await control(5, null);
      fail('Expected an Android SecurityException');
    } on JThrowable catch (error) {
      try {
        expect(error.message, contains('USB access denied'));
        JClass.forName('java.lang.SecurityException').use((type) {
          expect(error.isInstanceOf(type), isTrue);
        });
      } finally {
        error.release();
      }
    }
  });

  testWidgets(
    'rejects invalid slices, read-only IN and out-of-range JNI ints',
    (_) async {
      await expectLater(control(3, null, offset: 1), throwsRangeError);
      await expectLater(control(3, null, length: 1), throwsRangeError);
      await expectLater(
        connection.bulkTransfer(input, Uint8List(3), offset: 2, length: 2),
        throwsRangeError,
      );
      await expectLater(
        connection.bulkTransfer(input, Uint8List(3).asUnmodifiableView()),
        throwsArgumentError,
      );
      await expectLater(
        control(3, null, timeout: 0x80000000),
        throwsRangeError,
      );
      await expectLater(control(0x80000000, null), throwsRangeError);
    },
  );

  testWidgets(
    'queued transfers return their original request and buffer slice',
    (_) async {
      final receive = UsbRequest();
      final send = UsbRequest();
      final context = Object();
      receive.setClientData(context);
      expect(await receive.initialize(connection, input), isTrue);
      expect(await send.initialize(connection, output), isTrue);
      expect(receive.getEndpoint(), same(input));
      expect(receive.transferredLength, isNull);
      final target = Uint8List.fromList([10, 11, 12, 13, 14, 15, 16]);
      final source = Uint8List.fromList([0, 0, 0xfe, 0x51, 0x42, 0]);
      expect(
        await receive.queue(
          Uint8List.sublistView(target, 1, 6),
          offset: 1,
          length: 3,
        ),
        isTrue,
      );
      final sent = send.queue(
        Uint8List.sublistView(source, 1, 5).asUnmodifiableView(),
        offset: 1,
      );
      source[2] = 0;
      expect(await sent, isTrue);
      expect(target, [10, 11, 12, 13, 14, 15, 16]);

      expect(await connection.requestWait(timeout: 0), same(send));
      expect(send.transferredLength, 1);
      expect(await connection.requestWait(timeout: 0), same(receive));
      expect(receive.transferredLength, 2);
      expect(target, [10, 11, 0x80, 0xff, 14, 15, 16]);
      expect(receive.getClientData(), same(context));
      await receive.close();
      await send.close();
    },
  );

  testWidgets('failed reinitialization leaves the idle request unbound', (
    _,
  ) async {
    final request = UsbRequest();
    expect(await request.initialize(connection, input), isTrue);
    expect(await request.initialize(connection, unsupported), isFalse);
    expect(request.getEndpoint(), isNull);
    await expectLater(request.queue(null), throwsStateError);
    expect(await request.initialize(connection, output), isTrue);
    expect(request.getEndpoint(), same(output));

    expect(await request.queue(null), isTrue);
    expect(await request.cancel(), isTrue);
    await expectLater(request.close(), throwsStateError);
    await expectLater(request.initialize(connection, input), throwsStateError);
    expect(request.getEndpoint(), same(output));
    expect(await connection.requestWait(timeout: 0), same(request));
    expect(request.transferredLength, 0);
    await Future.wait([request.close(), request.close()]);
    expect(await request.cancel(), isFalse);
    expect(request.getEndpoint(), isNull);
    expect(await request.initialize(connection, input), isTrue);
    await request.close();
  });

  testWidgets('rebinding moves an idle request to the new connection', (
    _,
  ) async {
    final device = (await manager.getDeviceList()).values.single;
    final nextConnection = (await manager.openDevice(device))!;
    addTearDown(nextConnection.close);
    final request = UsbRequest();
    expect(await request.initialize(connection, input), isTrue);
    expect(await request.initialize(nextConnection, output), isTrue);
    await connection.close();
    expect(request.getEndpoint(), same(output));
    expect(await request.queue(null), isTrue);
    expect(await nextConnection.requestWait(timeout: 0), same(request));
    await request.close();
  });

  testWidgets(
    'queued IN validates slices and distinguishes timeout from native null',
    (_) async {
      final request = UsbRequest();
      expect(await request.initialize(connection, input), isTrue);
      await expectLater(request.queue(null, offset: 1), throwsRangeError);
      await expectLater(
        request.queue(Uint8List(1).asUnmodifiableView()),
        throwsArgumentError,
      );
      await expectLater(
        connection.requestWait(timeout: -1),
        throwsArgumentError,
      );
      await expectLater(
        connection.requestWait(timeout: 0),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        connection.requestWait(timeout: 20),
        throwsA(isA<TimeoutException>()),
      );
      expect(await request.queue(Uint8List(0).asUnmodifiableView()), isTrue);
      fixtureAction('failNextWait');
      expect(await connection.requestWait(timeout: 0), isNull);
      expect(await connection.requestWait(timeout: 1000), same(request));
      expect(request.transferredLength, 0);
      await request.close();
    },
  );

  testWidgets('one submission satisfies one waiter and close wakes the other', (
    _,
  ) async {
    final request = UsbRequest();
    expect(await request.initialize(connection, input), isTrue);
    final waits = [
      for (var i = 0; i < 2; i++)
        connection.requestWait().then<Object?>(
          (value) => value,
          onError: (Object error) => error,
        ),
    ];
    expect(await request.queue(null), isTrue);
    expect(await Future.any(waits).timeout(deadline), same(request));
    await connection.close().timeout(deadline);
    expect(
      await Future.wait(waits).timeout(deadline),
      unorderedEquals([same(request), isA<StateError>()]),
    );
    final untimedWaitCount = fixture.staticMethodId('untimedWaitCount', '()I');
    expect(untimedWaitCount.call(fixture, jint.type, []), 1);
    await request.close();
  });

  for (final detach in [false, true]) {
    testWidgets(
      'queued requests are discarded by ${detach ? 'detach' : 'close'} without a wait',
      (_) async {
        final request = UsbRequest();
        final target = Uint8List.fromList([1, 2, 3]);
        expect(await request.initialize(connection, input), isTrue);
        expect(await request.queue(target), isTrue);
        if (detach) {
          fixtureAction('removeDevice');
          expect(await manager.getDeviceList(), isEmpty);
        }
        await connection.close().timeout(deadline);
        expect(target, [1, 2, 3]);
        expect(request.transferredLength, isNull);
        expect(request.getEndpoint(), isNull);
        expect(await request.cancel(), isFalse);
        await request.close();
      },
    );
  }

  for (final detach in [false, true]) {
    testWidgets('admitted bulk outlives ${detach ? 'detach' : 'close'}', (
      _,
    ) async {
      final bulk = connection.bulkTransfer(input, null);
      // Attach a handler before awaiting anything else so early JNI failures
      // are attributed to this transfer.
      final bulkCheck = expectLater(bulk, completion(0));
      try {
        await waitForBulkEntry();
        expect(await control(3, null).timeout(deadline), 0);

        if (detach) {
          fixtureAction('removeDevice');
          expect(await manager.getDeviceList(), isEmpty);
          await expectLater(
            connection.bulkTransfer(input, null),
            throwsStateError,
          );
        }
        var closeCompleted = false;
        final closed = connection.close().then((_) => closeCompleted = true);
        await expectLater(control(3, null), throwsStateError);
        expect(closeCompleted, isFalse);
        fixtureAction('resumeTransfer');
        await bulkCheck.timeout(deadline);
        await closed.timeout(deadline);
      } finally {
        fixtureAction('resumeTransfer');
      }
    });
  }
}
