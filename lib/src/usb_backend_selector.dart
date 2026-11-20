import 'dart:io';

import 'android/android_usb.dart';
import 'usb_backend.dart';
import 'usb_device.dart';
import 'usb_device_connection.dart';

/// The only platform selection point. Both backend instances are session-free
/// until an operation needs platform resources; constructing UsbManager is inert.
final UsbBackend usbBackend = Platform.isAndroid
    ? AndroidUsb.instance
    : const _UnavailableUsbBackend();

/// Preserves current placeholders for Linux, Windows and other non-Android hosts.
/// Real system adapters can replace this branch when their implementation exists.
final class _UnavailableUsbBackend implements UsbBackend {
  const _UnavailableUsbBackend();

  @override
  Stream<UsbDevice> get deviceAttached => const Stream.empty();
  @override
  Stream<UsbDevice> get deviceDetached => const Stream.empty();
  @override
  Future<Map<String, UsbDevice>> getDeviceList() async => <String, UsbDevice>{};
  @override
  Future<bool> hasPermission(UsbDevice device) async => false;
  @override
  Future<bool> requestPermission(UsbDevice device) async => false;
  @override
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) async => null;
  @override
  Future<int> deviceId(String name) async => -1;
  @override
  Future<String?> deviceName(int id) async => null;
}
