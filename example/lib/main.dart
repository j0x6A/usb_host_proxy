import 'package:flutter/widgets.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

// Reference every public class. This example does not perform USB operations.
void main() {
  final api = <Type>[
    UsbManager,
    UsbDevice,
    UsbConfiguration,
    UsbInterface,
    UsbEndpoint,
    UsbDeviceConnection,
    UsbRequest,
    UsbConstants,
  ];

  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Text('usb_host_proxy API compiles.\n${api.join(', ')}'),
      ),
    ),
  );
}
