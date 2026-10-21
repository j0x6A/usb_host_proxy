import 'dart:async';
import 'dart:io';

import 'android/android_usb.dart';
import 'usb_device.dart';
import 'usb_device_connection.dart';

// Preserve Android's public constant names.
// ignore_for_file: constant_identifier_names

/// USB host discovery, permissions, connections, and device lifecycle events.
///
/// Android uses JNI references to the original framework objects. Other
/// platforms retain their unimplemented placeholder behavior.
class UsbManager {
  /// Creates a manager without enumerating or opening devices.
  UsbManager();

  /// Android's host device attachment action identifier.
  static const String ACTION_USB_DEVICE_ATTACHED =
      'android.hardware.usb.action.USB_DEVICE_ATTACHED';

  /// Android's host device detachment action identifier.
  static const String ACTION_USB_DEVICE_DETACHED =
      'android.hardware.usb.action.USB_DEVICE_DETACHED';

  /// Android's device extra key; retained for API correspondence.
  static const String EXTRA_DEVICE = 'device';

  /// Android's permission reply extra key; retained for API correspondence.
  static const String EXTRA_PERMISSION_GRANTED = 'permission';

  /// Stream of newly attached devices.
  ///
  /// Broadcast stream without replay. USB attachment that starts the app is
  /// initial state available through [getDeviceList], not a replayed event.
  Stream<UsbDevice> get deviceAttached => Platform.isAndroid
      ? AndroidUsb.instance.deviceAttached
      : const Stream<UsbDevice>.empty();

  /// Stream of detached device snapshots.
  ///
  /// Connections are invalidated before notification. The native descriptor
  /// objects remain readable; device operations require a current attachment.
  Stream<UsbDevice> get deviceDetached => Platform.isAndroid
      ? AndroidUsb.instance.deviceDetached
      : const Stream<UsbDevice>.empty();

  /// Returns devices keyed by the name returned by [UsbDevice.getDeviceName].
  ///
  /// Does not open devices or request permission.
  Future<Map<String, UsbDevice>> getDeviceList() async {
    if (Platform.isAndroid) return AndroidUsb.instance.getDeviceList();
    return <String, UsbDevice>{};
  }

  /// Whether the application currently has permission to access [device].
  Future<bool> hasPermission(UsbDevice device) async {
    if (Platform.isAndroid) return AndroidUsb.instance.hasPermission(device);
    return false;
  }

  /// Requests access and waits for the permission decision.
  ///
  /// Concurrent requests for the same attachment share a decision. Denial or
  /// detachment returns false. Session termination completes with an error.
  Future<bool> requestPermission(UsbDevice device) async {
    if (Platform.isAndroid) {
      return AndroidUsb.instance.requestPermission(device);
    }
    return false;
  }

  /// Opens [device], or returns null if it cannot be opened.
  ///
  /// Does not request permission implicitly. Android exceptions are propagated.
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) async {
    if (Platform.isAndroid) return AndroidUsb.instance.openDevice(device);
    return null;
  }
}
