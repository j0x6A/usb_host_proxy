import 'dart:io';

import 'android/android_usb.dart';
import 'usb_configuration.dart';
import 'usb_interface.dart';

/// Android USB device API, excluding Parcelable serialization.
///
/// Android adapters retain original descriptor references. Descriptor getters
/// remain readable after detach. An older view is still accepted by its active
/// session: Android decides presence, permissions and operation results. A name
/// or platform ID is not a persistent hardware identity and may be reused.
///
/// Android adapters delegate equality and hashing to the native UsbDevice:
/// adapters with the same Android name compare equal and have the same native
/// hash, including after name reuse or across sessions. Closed connections are
/// never revived by equality or name reuse. Equality is between Android adapters,
/// not between a device and its name string or a custom Dart implementation.
abstract class UsbDevice {
  /// Returns a configuration by descriptor index.
  ///
  /// [index] is zero-based and must be less than [getConfigurationCount]. It is
  /// not the configuration value returned by [UsbConfiguration.getId].
  UsbConfiguration getConfiguration(int index);

  /// Returns the number of configuration descriptors.
  int getConfigurationCount();

  /// Returns bDeviceClass.
  int getDeviceClass();

  /// Returns the platform device ID.
  int getDeviceId();

  /// Returns the platform device name used as the device-list key.
  ///
  /// Android returns its original name without any plugin-specific suffix.
  String getDeviceName();

  /// Returns bDeviceProtocol.
  int getDeviceProtocol();

  /// Returns bDeviceSubClass.
  int getDeviceSubclass();

  /// Returns an interface by index across all configurations.
  ///
  /// [index] is zero-based and less than [getInterfaceCount], not bInterfaceNumber.
  UsbInterface getInterface(int index);

  /// Returns the number of interfaces across all configurations.
  int getInterfaceCount();

  /// Returns the manufacturer name, if available.
  String? getManufacturerName();

  /// Returns idProduct.
  int getProductId();

  /// Returns the product name, if available.
  String? getProductName();

  /// Returns the serial number, if available.
  ///
  /// Android reads the supplied framework object's serial on a worker after
  /// checking session ownership. This does not refresh the descriptor by name.
  /// USB permission may be required; failures remain errors, not synthetic null.
  Future<String?> getSerialNumber();

  /// Returns idVendor.
  int getVendorId();

  /// Returns the device release string derived from bcdDevice, not bcdUSB.
  String getVersion();

  /// Android's static getDeviceId(String), renamed to avoid an instance conflict.
  /// Does not enumerate devices or validate current presence. Non-Android returns -1.
  static Future<int> getDeviceIdFromName(String name) async {
    if (Platform.isAndroid) return AndroidUsb.deviceId(name);
    return -1;
  }

  /// Android's static getDeviceName(int), renamed to avoid an instance conflict.
  /// Does not enumerate devices or validate current presence. Non-Android returns null.
  static Future<String?> getDeviceNameFromId(int id) async {
    if (Platform.isAndroid) return AndroidUsb.deviceName(id);
    return null;
  }
}
