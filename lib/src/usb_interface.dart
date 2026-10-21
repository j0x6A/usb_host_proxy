import 'usb_endpoint.dart';

/// Android USB interface API, excluding Parcelable serialization.
///
/// Each descriptor represents one interface/alternate-setting combination.
/// Reading it neither claims the interface nor selects that alternate setting.
abstract class UsbInterface {
  /// Returns bAlternateSetting.
  int getAlternateSetting();

  /// Returns an endpoint by descriptor index, not endpoint address.
  /// [index] is zero-based and must be less than [getEndpointCount].
  UsbEndpoint getEndpoint(int index);

  /// Returns the number of endpoint descriptors.
  int getEndpointCount();

  /// Returns bInterfaceNumber, not the interface's list index.
  int getId();

  /// Returns bInterfaceClass.
  int getInterfaceClass();

  /// Returns bInterfaceProtocol.
  int getInterfaceProtocol();

  /// Returns bInterfaceSubClass.
  int getInterfaceSubclass();

  /// Returns the interface name, if available.
  String? getName();
}
