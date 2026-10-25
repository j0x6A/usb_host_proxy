/// The shared USB host API for Android and Windows.
///
/// Android management, device events and USB transport use JNI. The Windows
/// backend is not implemented; non-Android placeholders retain their behavior.
///
/// Android USB Host classes and protocol constants are represented without
/// UsbAccessory. Potentially blocking operations execute outside the Dart
/// isolate; descriptor getters directly read the original objects. Device events
/// use streams; requestPermission returns the decision instead of PendingIntent.
///
/// Java overloads share one Dart method with named optional arguments. Static
/// UsbDevice name/ID conversions use getDeviceIdFromName/getDeviceNameFromId
/// because their Android names are already used by instance methods in Dart.
/// Uint8List slices and UsbRequest.transferredLength replace Java ByteBuffer's
/// position/limit state; deprecated queue behavior is not reproduced.
///
/// Android Parcelable members (CREATOR, describeContents, writeToParcel and
/// inherited parcel flags) are not part of this cross-platform API.
///
/// References:
/// https://developer.android.com/reference/android/hardware/usb/package-summary
/// https://learn.microsoft.com/en-us/windows/win32/api/winusb/
library;

export 'src/usb_configuration.dart' show UsbConfiguration;
export 'src/usb_constants.dart' show UsbConstants;
export 'src/usb_device.dart' show UsbDevice;
export 'src/usb_device_connection.dart' show UsbDeviceConnection;
export 'src/usb_endpoint.dart' show UsbEndpoint;
export 'src/usb_interface.dart' show UsbInterface;
export 'src/usb_manager.dart' show UsbManager;
export 'src/usb_request.dart' show UsbRequest;
