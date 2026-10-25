import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy/src/android/transfer_buffer.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

/// Pure Dart buffer contracts; these do not load JNI or simulate native USB.
void main() {
  test('Slices use the Uint8List view, not its backing allocation', () {
    final backing = Uint8List.fromList([99, 1, 2, 3, 4, 88]);
    final view = Uint8List.sublistView(backing, 1, 5);
    expect(transferLength(view, 1, null), 3);
    receiveBytes(view, 1, [-128, -1], 2);
    expect(backing, [99, 1, 128, 255, 4, 88]);
  });

  test('Null and empty buffers permit only an empty slice', () {
    expect(transferLength(null, 0, null), 0);
    expect(transferLength(null, 0, 0), 0);
    expect(transferLength(Uint8List(0), 0, null), 0);
    expect(() => transferLength(null, 1, 0), throwsRangeError);
    expect(() => transferLength(null, 0, 1), throwsRangeError);
  });

  test('Offset and length fail before allocation or JNI', () {
    final bytes = Uint8List(4);
    expect(transferLength(bytes, 4, null), 0);
    expect(() => transferLength(bytes, -1, 1), throwsRangeError);
    expect(() => transferLength(bytes, 5, 0), throwsRangeError);
    expect(() => transferLength(bytes, 1, -1), throwsRangeError);
    expect(() => transferLength(bytes, 2, 3), throwsRangeError);
    expect(() => transferLength(bytes, 0, 1 << 40), throwsRangeError);
  });

  test('JNI integer conversion never silently truncates arguments', () {
    expect(jniInt(-0x80000000, 'value'), -0x80000000);
    expect(jniInt(0x7fffffff, 'value'), 0x7fffffff);
    expect(() => jniInt(0x80000000, 'value'), throwsRangeError);
    expect(() => jniInt(-0x80000001, 'value'), throwsRangeError);
  });

  test(
    'Non-empty read-only IN slices fail before submission, without mutation',
    () {
      final storage = Uint8List.fromList([9, 1, 128, 255, 8]);
      final readOnly = storage.asUnmodifiableView();
      final destinations = [
        readOnly,
        Uint8List.sublistView(readOnly, 1, 4),
        readOnly.buffer.asUint8List(1, 3),
      ];
      // A sentinel for reaching the next step, not a mocked or real JNI submission.
      var submitted = false;
      for (final destination in destinations) {
        expect(() {
          final count = transferLength(destination, 1, 1);
          checkInputBuffer(destination, 1, count);
          submitted = true;
        }, throwsArgumentError);
      }
      expect(submitted, isFalse);
      expect(storage, [9, 1, 128, 255, 8]);
    },
  );

  test('Writable IN views are checked without changing any bytes', () {
    final storage = Uint8List.fromList([9, 1, 128, 255, 8]);
    final destination = Uint8List.sublistView(storage, 1, 4);
    checkInputBuffer(destination, 1, transferLength(destination, 1, 2));
    expect(storage, [9, 1, 128, 255, 8]);
    receiveBytes(destination, 1, [7], 1);
    expect(storage, [9, 1, 7, 255, 8]);
  });

  test(
    'Read-only OUT sources and zero-length IN slices retain their contract',
    () {
      final source = Uint8List.fromList([128, 255]).asUnmodifiableView();
      // OUT only validates bounds and snapshots the source; it needs no write probe.
      expect(transferLength(source, 0, null), 2);
      expect(Uint8List.fromList(source), [128, 255]);
      checkInputBuffer(source, 1, transferLength(source, 1, 0));
      final empty = Uint8List(0).asUnmodifiableView();
      checkInputBuffer(empty, 0, transferLength(empty, 0, null));
      checkInputBuffer(null, 0, transferLength(null, 0, null));
      expect(source, [128, 255]);
    },
  );

  test(
    'Only the completed IN prefix changes; negative and zero results do not',
    () {
      final target = Uint8List.fromList([9, 9, 9, 9, 9]);
      receiveBytes(target, 1, [128, 255, 3], 2);
      expect(target, [9, 128, 255, 9, 9]);
      receiveBytes(target, 0, [1, 2, 3], -1);
      receiveBytes(target, 0, [], 0);
      expect(target, [9, 128, 255, 9, 9]);
      expect(() => receiveBytes(target, 4, [1, 2], 2), throwsStateError);
      expect(() => receiveBytes(target, 0, [1], 2), throwsStateError);
      expect(target, [9, 128, 255, 9, 9]);
    },
  );

  test('Non-Android UsbRequest placeholders remain unchanged', () async {
    final request = UsbRequest();
    request.setClientData(Object());
    expect(request.getClientData(), isNull);
    expect(request.getEndpoint(), isNull);
    expect(request.transferredLength, isNull);
    expect(await request.queue(Uint8List(0)), isFalse);
    expect(await request.cancel(), isFalse);
    await request.close();
    await request.close();
  });
}
