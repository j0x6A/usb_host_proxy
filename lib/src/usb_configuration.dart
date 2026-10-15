import 'usb_interface.dart';

/// Android USB configuration API, excluding Parcelable serialization.
abstract class UsbConfiguration {
  /// Returns bConfigurationValue, not the configuration's list index.
  int getId();

  /// Returns an interface by descriptor index.
  UsbInterface getInterface(int index);

  /// Returns the number of interface descriptors, including alternate settings.
  int getInterfaceCount();

  /// Maximum power consumption in milliamps.
  int getMaxPower();

  /// Returns the configuration name, if available.
  String? getName();

  /// Indicates whether remote wakeup is supported.
  bool isRemoteWakeup();

  /// Indicates whether the configuration is self-powered.
  bool isSelfPowered();
}
