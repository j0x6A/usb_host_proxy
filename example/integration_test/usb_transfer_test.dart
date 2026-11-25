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
