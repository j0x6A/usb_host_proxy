import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'usb_host_proxy_platform_interface.dart';

/// An implementation of [UsbHostProxyPlatform] that uses method channels.
class MethodChannelUsbHostProxy extends UsbHostProxyPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('usb_host_proxy');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
