import 'usb_device.dart';
import 'usb_device_connection.dart';

/// Internal platform boundary; not exported by usb_host_proxy.dart.
///
/// Each backend's system adapter owns platform resources and lifecycle (Java on
/// Android). This contract only routes public operations; it introduces no shared
/// USB state or queue.
abstract interface class UsbBackend {
  Stream<UsbDevice> get deviceAttached;
  Stream<UsbDevice> get deviceDetached;
  Future<Map<String, UsbDevice>> getDeviceList();
  Future<bool> hasPermission(UsbDevice device);
  Future<bool> requestPermission(UsbDevice device);
  Future<UsbDeviceConnection?> openDevice(UsbDevice device);

  /// Platform name/ID conversions must not initialise a management session.
  Future<int> deviceId(String name);
  Future<String?> deviceName(int id);
}
