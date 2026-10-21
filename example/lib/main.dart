import 'package:flutter/widgets.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';

/// Displays references to every public API class, without performing USB operations.
void main() {
  // Type references exercise imports without initializing the Android backend.
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
