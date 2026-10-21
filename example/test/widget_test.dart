import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy_example/main.dart' as example;

void main() {
  testWidgets('Displays the public API compilation message', (tester) async {
    example.main();
    await tester.pump();

    expect(
      find.textContaining('usb_host_proxy API compiles.'),
      findsOneWidget,
    );
    for (final name in [
      'UsbManager',
      'UsbDevice',
      'UsbConfiguration',
      'UsbInterface',
      'UsbEndpoint',
      'UsbDeviceConnection',
      'UsbRequest',
      'UsbConstants',
    ]) {
      expect(find.textContaining(RegExp('\\b$name\\b')), findsOneWidget);
    }
  });
}
