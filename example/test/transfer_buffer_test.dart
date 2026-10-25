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
