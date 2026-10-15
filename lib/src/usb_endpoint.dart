/// Android USB endpoint API, excluding Parcelable serialization.
abstract class UsbEndpoint {
  /// Returns bEndpointAddress, including its direction bit.
  int getAddress();

  /// Returns bmAttributes.
  int getAttributes();

  /// Returns USB_DIR_IN or USB_DIR_OUT.
  int getDirection();

  /// Returns the endpoint number without its direction bit.
  int getEndpointNumber();

  /// Returns the raw bInterval value.
  int getInterval();

  /// Returns wMaxPacketSize.
  int getMaxPacketSize();

  /// Returns the transfer type encoded in bmAttributes.
  int getType();
}
