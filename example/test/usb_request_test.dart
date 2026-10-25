import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

/// Placeholder contracts only: no JNI, native USB or transport simulation.
void main() {
  test('UsbRequest getters and caller data remain unimplemented', () {
    final request = UsbRequest();
    request.setClientData(Object());
    expect(request.getClientData(), isNull);
    request.setClientData(null);
    expect(request.getEndpoint(), isNull);
    expect(request.transferredLength, isNull);
  });

  test(
    'Request placeholders perform no native calls or buffer writes',
    () async {
      final request = UsbRequest();
      final buffer = Uint8List.fromList([9, 128, 255, 8]);
      expect(await request.initialize(_NoConnection(), _NoEndpoint()), isFalse);
      expect(await request.queue(buffer, offset: 1, length: 2), isFalse);
      expect(buffer, [9, 128, 255, 8]);
      expect(await request.cancel(), isFalse);
      await request.close();
      await request.close();
      expect(request.getEndpoint(), isNull);
      expect(request.transferredLength, isNull);
    },
  );

  test(
    'Unimplemented queue neither validates nor accesses supplied slices',
    () async {
      final request = UsbRequest();
      expect(await request.queue(null, offset: -1, length: 2), isFalse);
      expect(await request.queue(Uint8List(0).asUnmodifiableView()), isFalse);
      expect(
        await request.queue(Uint8List.fromList([1]).asUnmodifiableView()),
        isFalse,
      );
    },
  );
}

/// Any accidental forwarding by a placeholder is a test failure.
class _NoConnection implements UsbDeviceConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected connection access: ${invocation.memberName}',
  );
}

class _NoEndpoint implements UsbEndpoint {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected endpoint access: ${invocation.memberName}');
}
