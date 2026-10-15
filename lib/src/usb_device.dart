import 'usb_configuration.dart';
import 'usb_interface.dart';

/// Android USB device API, excluding Parcelable serialization.
abstract class UsbDevice {
  /// Returns a configuration by descriptor index.
  UsbConfiguration getConfiguration(int index);

  /// Returns the number of configuration descriptors.
  int getConfigurationCount();

  /// Returns bDeviceClass.
  int getDeviceClass();

  /// Returns the platform device ID.
  int getDeviceId();

  /// Returns the platform device name used as the device-list key.
  String getDeviceName();

  /// Returns bDeviceProtocol.
  int getDeviceProtocol();

  /// Returns bDeviceSubClass.
  int getDeviceSubclass();

  /// Returns an interface by index across all configurations.
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
  Future<String?> getSerialNumber();

  /// Returns idVendor.
  int getVendorId();

  /// Returns the device release string derived from bcdDevice, not bcdUSB.
  String getVersion();

  /// Android's static getDeviceId(String), renamed to avoid an instance conflict.
  ///
  /// NOT IMPLEMENTED YET: returns -1 without resolving the name.
  static Future<int> getDeviceIdFromName(String name) async {
    return -1;
  }

  /// Android's static getDeviceName(int), renamed to avoid an instance conflict.
  ///
  /// NOT IMPLEMENTED YET: returns null without resolving the ID.
  static Future<String?> getDeviceNameFromId(int id) async {
    return null;
  }
}
