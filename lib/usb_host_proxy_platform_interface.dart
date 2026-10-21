import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'usb_host_proxy_method_channel.dart';

abstract class UsbHostProxyPlatform extends PlatformInterface {
  /// Constructs a UsbHostProxyPlatform.
  UsbHostProxyPlatform() : super(token: _token);

  static final Object _token = Object();

  static UsbHostProxyPlatform _instance = MethodChannelUsbHostProxy();

  /// The default instance of [UsbHostProxyPlatform] to use.
  ///
  /// Defaults to [MethodChannelUsbHostProxy].
  static UsbHostProxyPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [UsbHostProxyPlatform] when
  /// they register themselves.
  static set instance(UsbHostProxyPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
