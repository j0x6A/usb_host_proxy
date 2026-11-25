import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

/// Contracts for unsupported queued requests without native USB access.
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
    'Unsupported operations perform no native calls or buffer writes',
    () async {
      final request = UsbRequest();
      final buffer = Uint8List.fromList([9, 128, 255, 8]);
      await expectLater(
        request.initialize(_NoConnection(), _NoEndpoint()),
        throwsUnsupportedError,
      );
      await expectLater(
        request.queue(buffer, offset: 1, length: 2),
        throwsUnsupportedError,
      );
      expect(buffer, [9, 128, 255, 8]);
      await expectLater(request.cancel(), throwsUnsupportedError);
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
      await expectLater(
        request.queue(null, offset: -1, length: 2),
        throwsUnsupportedError,
      );
      await expectLater(
        request.queue(Uint8List(0).asUnmodifiableView()),
        throwsUnsupportedError,
      );
      await expectLater(
        request.queue(Uint8List.fromList([1]).asUnmodifiableView()),
        throwsUnsupportedError,
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
