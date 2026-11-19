import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy/src/android/android_usb.dart';
import 'package:usb_host_proxy/src/usb_backend.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

void main() {
  group('Unimplemented platform backend', () {
    test(
      'managers preserve empty streams and independent mutable lists',
      () async {
        final first = UsbManager();
        final second = UsbManager();
        expect(await first.deviceAttached.toList(), isEmpty);
        expect(await first.deviceDetached.toList(), isEmpty);
        final devices = await first.getDeviceList();
        devices['local'] = _UnusedDevice();
        expect(await first.getDeviceList(), isEmpty);
        expect(await second.getDeviceList(), isEmpty);
      },
    );

    test(
      'permission and open placeholders do not inspect their argument',
      () async {
        final manager = UsbManager();
        final device = _UnusedDevice();
        expect(await manager.hasPermission(device), isFalse);
        expect(await manager.requestPermission(device), isFalse);
        expect(await manager.openDevice(device), isNull);
      },
    );

    test('name and ID conversions preserve their placeholder values', () async {
      expect(await UsbDevice.getDeviceIdFromName(''), -1);
      expect(await UsbDevice.getDeviceIdFromName('/dev/bus/usb/001/002'), -1);
      expect(await UsbDevice.getDeviceNameFromId(-1), isNull);
      expect(await UsbDevice.getDeviceNameFromId(0), isNull);
    });
  }, skip: Platform.isAndroid);

  test(
    'obtaining the Android backend does not initialise JNI or a session',
    () {
      final UsbBackend backend = AndroidUsb.instance;
      expect(identical(backend, AndroidUsb.instance), isTrue);
    },
  );

  test('Android management keeps root-isolate failures asynchronous', () async {
    final outcomes = await Isolate.run(() async {
      // Construction must succeed even here. Actual USB access still rejects
      // a background isolate before it can create any JNI callback or reference.
      final backend = AndroidUsb.instance;
      final device = _UnusedDevice();
      final operations = <Future<Object?> Function()>[
        backend.getDeviceList,
        () => backend.hasPermission(device),
        () => backend.requestPermission(device),
        () => backend.openDevice(device),
      ];
      final results = <String>[];
      for (final operation in operations) {
        final Future<Object?> result;
        try {
          result = operation();
        } catch (_) {
          results.add('synchronous failure');
          continue;
        }
        try {
          await result;
          results.add('unexpected success');
        } on StateError catch (error) {
          results.add(error.message);
        }
      }
      for (final stream in [
        () => backend.deviceAttached,
        () => backend.deviceDetached,
      ]) {
        try {
          stream();
          results.add('unexpected stream');
        } on StateError catch (error) {
          results.add(error.message);
        }
      }
      return results;
    });
    expect(
      outcomes,
      List.filled(6, 'USB objects must be used in the engine root isolate'),
    );
  });
}

/// Any descriptor access would reveal an unintended change to placeholder routing.
final class _UnusedDevice implements UsbDevice {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected descriptor access: ${invocation.memberName}',
  );
}
