import 'usb_interface.dart';

/// Android USB configuration API, excluding Parcelable serialization.
///
/// This is descriptor information, not the connection's selected configuration.
/// The Dart adapter reads the original Android object through JNI.
/// Device removal or session termination releases that reference; subsequent
/// reads fail with [StateError], including reads through saved child objects.
abstract class UsbConfiguration {
  /// Returns bConfigurationValue, not the configuration's list index.
  int getId();

  /// Returns an interface by descriptor index.
  /// [index] is zero-based and less than [getInterfaceCount], not an interface ID.
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
