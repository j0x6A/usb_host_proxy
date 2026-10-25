/// USB Host device discovery, information and management for Android.
///
/// Android management and device events use JNI. USB transport, [UsbRequest]
/// and the Windows backend are not implemented; their declarations remain for
/// future work. Import this library to access the public classes and constants.
///
/// Android USB Host classes and protocol constants are represented without
/// UsbAccessory. Management workers handle opening, serial reads, interface and
/// configuration changes, and close. Enumeration, permission checks, descriptor
/// getters and FD/raw reads still call JNI synchronously. Events use streams;
/// requestPermission returns the decision instead of exposing a PendingIntent.
///
/// Observed device removal invalidates all related descriptor views and starts
/// connection cleanup. Only a removed device's name, equality and hash remain
/// available through inert Java views. JNI references to these views may remain
/// until Dart GC. The manager and event receivers stay active until
/// the engine session ends, including while the device list is empty.
///
/// Java overloads share one Dart method with named optional arguments. Static
/// UsbDevice name/ID conversions use getDeviceIdFromName/getDeviceNameFromId
/// because their Android names are already used by instance methods in Dart.
/// Transport declarations reserve Uint8List slices and transferredLength instead
/// of Java ByteBuffer position/limit state. They do not currently submit data,
/// advance buffers or initialize native requests.
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
