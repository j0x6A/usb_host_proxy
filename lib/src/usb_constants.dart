// Preserve the identifiers used by Android and the Windows SDK.
// ignore_for_file: constant_identifier_names

/// Android USB protocol constants and WinUSB pipe policy identifiers.
///
/// All 33 Android constants keep their original names and numeric values.
/// WinUSB policies are used by `UsbDeviceConnection.setPipePolicy` and
/// `UsbDeviceConnection.getPipePolicy`. Boolean policies use one byte (zero is
/// false; nonzero is true). Unsigned 32-bit policies use four little-endian bytes.
///
/// References:
/// https://developer.android.com/reference/android/hardware/usb/UsbConstants
/// https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/winusb-functions-for-pipe-policy-modification
class UsbConstants {
  /// Matches Android's public no-argument constructor.
  const UsbConstants();

  // Android: USB device and interface classes.

  /// Class information is specified by each interface.
  static const int USB_CLASS_PER_INTERFACE = 0x00;

  /// Audio device class.
  static const int USB_CLASS_AUDIO = 0x01;

  /// Communications device class.
  static const int USB_CLASS_COMM = 0x02;

  /// Human interface device class.
  static const int USB_CLASS_HID = 0x03;

  /// Physical device class; Android's PHYSICA spelling is intentional.
  static const int USB_CLASS_PHYSICA = 0x05;

  /// Still image device class.
  static const int USB_CLASS_STILL_IMAGE = 0x06;

  /// Printer device class.
  static const int USB_CLASS_PRINTER = 0x07;

  /// Mass storage device class.
  static const int USB_CLASS_MASS_STORAGE = 0x08;

  /// USB hub device class.
  static const int USB_CLASS_HUB = 0x09;

  /// Communications data device class.
  static const int USB_CLASS_CDC_DATA = 0x0a;

  /// Smart card device class; Android's CSCID spelling is intentional.
  static const int USB_CLASS_CSCID = 0x0b;

  /// Content security device class.
  static const int USB_CLASS_CONTENT_SEC = 0x0d;

  /// Video device class.
  static const int USB_CLASS_VIDEO = 0x0e;

  /// Wireless controller device class.
  static const int USB_CLASS_WIRELESS_CONTROLLER = 0xe0;

  /// Miscellaneous device class.
  static const int USB_CLASS_MISC = 0xef;

  /// Application-specific device class.
  static const int USB_CLASS_APP_SPEC = 0xfe;

  /// Vendor-specific device class.
  static const int USB_CLASS_VENDOR_SPEC = 0xff;

  // Android: transfer direction and endpoint fields.

  /// Data flows from the host to the device.
  static const int USB_DIR_OUT = 0x00;

  /// Data flows from the device to the host.
  static const int USB_DIR_IN = 0x80;

  /// Direction bit in an endpoint address or control request type.
  static const int USB_ENDPOINT_DIR_MASK = 0x80;

  /// Endpoint number bits in an endpoint address.
  static const int USB_ENDPOINT_NUMBER_MASK = 0x0f;

  /// Transfer type bits in endpoint attributes.
  static const int USB_ENDPOINT_XFERTYPE_MASK = 0x03;

  /// Control transfer type.
  static const int USB_ENDPOINT_XFER_CONTROL = 0x00;

  /// Isochronous transfer type (not supported by Android UsbRequest).
  static const int USB_ENDPOINT_XFER_ISOC = 0x01;

  /// Bulk transfer type.
  static const int USB_ENDPOINT_XFER_BULK = 0x02;

  /// Interrupt transfer type.
  static const int USB_ENDPOINT_XFER_INT = 0x03;

  // Android: interface subclasses.

  /// HID boot interface subclass.
  static const int USB_INTERFACE_SUBCLASS_BOOT = 0x01;

  /// Vendor-specific subclass.
  static const int USB_SUBCLASS_VENDOR_SPEC = 0xff;

  // Android: control request types.

  /// Type bits in a control request's bmRequestType.
  static const int USB_TYPE_MASK = 0x60;

  /// Standard control request.
  static const int USB_TYPE_STANDARD = 0x00;

  /// Class control request.
  static const int USB_TYPE_CLASS = 0x20;

  /// Vendor control request.
  static const int USB_TYPE_VENDOR = 0x40;

  /// Reserved control request type.
  static const int USB_TYPE_RESERVED = 0x60;

  // Windows: WinUSB pipe policies.

  /// WinUSB boolean policy: append a zero-length packet to a full OUT packet.
  static const int SHORT_PACKET_TERMINATE = 0x01;

  /// WinUSB boolean policy: automatically recover a stalled IN pipe.
  static const int AUTO_CLEAR_STALL = 0x02;

  /// WinUSB uint32 policy: transfer timeout in milliseconds; zero is infinite.
  static const int PIPE_TRANSFER_TIMEOUT = 0x03;

  /// WinUSB boolean policy: continue reading past short packets.
  static const int IGNORE_SHORT_PACKETS = 0x04;

  /// WinUSB boolean policy: allow a read smaller than the received data.
  static const int ALLOW_PARTIAL_READS = 0x05;

  /// WinUSB boolean policy: discard excess bytes instead of caching them.
  static const int AUTO_FLUSH = 0x06;

  /// WinUSB boolean policy: bypass normal IN pipe queuing and recovery.
  static const int RAW_IO = 0x07;

  /// WinUSB read-only uint32 policy: maximum transfer size in bytes.
  static const int MAXIMUM_TRANSFER_SIZE = 0x08;

  /// WinUSB boolean policy: reset the pipe when resuming from suspend.
  static const int RESET_PIPE_ON_RESUME = 0x09;
}
