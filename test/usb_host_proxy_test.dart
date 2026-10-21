import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy/usb_host_proxy.dart';
import 'package:usb_host_proxy/usb_host_proxy_platform_interface.dart';
import 'package:usb_host_proxy/usb_host_proxy_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockUsbHostProxyPlatform
    with MockPlatformInterfaceMixin
    implements UsbHostProxyPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final UsbHostProxyPlatform initialPlatform = UsbHostProxyPlatform.instance;

  test('$MethodChannelUsbHostProxy is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelUsbHostProxy>());
  });

  test('getPlatformVersion', () async {
    UsbHostProxy usbHostProxyPlugin = UsbHostProxy();
    MockUsbHostProxyPlatform fakePlatform = MockUsbHostProxyPlatform();
    UsbHostProxyPlatform.instance = fakePlatform;

    expect(await usbHostProxyPlugin.getPlatformVersion(), '42');
  });
}
