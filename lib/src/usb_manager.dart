import 'dart:async';

import 'usb_device.dart';
import 'usb_device_connection.dart';

// Preserve Android's public constant names.
// ignore_for_file: constant_identifier_names

/// USB host discovery, permissions, connections, and device lifecycle events.
///
/// This class currently contains placeholders only; no USB operations occur.
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
  /// NOT IMPLEMENTED YET: returns an empty stream that immediately completes.
  Stream<UsbDevice> get deviceAttached => const Stream<UsbDevice>.empty();

  /// Stream of detached device snapshots.
  ///
  /// NOT IMPLEMENTED YET: returns an empty stream that immediately completes.
  Stream<UsbDevice> get deviceDetached => const Stream<UsbDevice>.empty();

  /// Returns devices keyed by the name returned by [UsbDevice.getDeviceName].
  ///
  /// NOT IMPLEMENTED YET: returns an empty map without enumerating devices.
  Future<Map<String, UsbDevice>> getDeviceList() async {
    return <String, UsbDevice>{};
  }

  /// Whether the application currently has permission to access [device].
  ///
  /// NOT IMPLEMENTED YET: returns false without checking permissions.
  Future<bool> hasPermission(UsbDevice device) async {
    return false;
  }

  /// Requests access and waits for the permission decision.
  ///
  /// NOT IMPLEMENTED YET: returns false without requesting permission.
  Future<bool> requestPermission(UsbDevice device) async {
    return false;
  }

  /// Opens [device], or returns null if it cannot be opened.
  ///
  /// NOT IMPLEMENTED YET: returns null without opening the device.
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) async {
    return null;
  }
}
