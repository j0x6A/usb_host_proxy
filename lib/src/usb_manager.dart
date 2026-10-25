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
/// Managers share an engine session; creating another manager does not create
/// an independent device registry. Use the engine's root Dart isolate.
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
  /// Runtime Activity intents and broadcasts share attachment deduplication.
  /// A stored Activity intent read after recreation is also silent initial state.
  Stream<UsbDevice> get deviceAttached => Platform.isAndroid
      ? AndroidUsb.instance.deviceAttached
      : const Stream<UsbDevice>.empty();

  /// Stream of retired device references, not copies of their descriptor fields.
  ///
  /// Connections are invalidated before notification. The native descriptor
  /// objects remain readable; device operations require a current attachment.
  Stream<UsbDevice> get deviceDetached => Platform.isAndroid
      ? AndroidUsb.instance.deviceDetached
      : const Stream<UsbDevice>.empty();

  /// Returns devices keyed by the name returned by [UsbDevice.getDeviceName].
  ///
  /// Does not open devices or request permission. Enumeration can report detach
  /// for a previously known device that is now absent, but does not emit attach
  /// for every listed device. Repeated enumeration retains native attachment
  /// identity, although Dart adapter objects need not be identical.
  /// Android adapter equality/hash follow the device name, not attachment UUIDs;
  /// equality alone is not proof that an attachment is still current.
  ///
  /// On Android the enumeration itself is synchronous JNI work. Other platforms
  /// currently return an empty map.
  Future<Map<String, UsbDevice>> getDeviceList() async {
    if (Platform.isAndroid) return AndroidUsb.instance.getDeviceList();
    return <String, UsbDevice>{};
  }

  /// Whether the application currently has permission to access [device].
  ///
  /// Android returns false for a retired attachment and rejects objects from
  /// another engine or a foreign implementation. The framework check runs
  /// synchronously despite this method returning a Future. Other platforms
  /// currently return false.
  Future<bool> hasPermission(UsbDevice device) async {
    if (Platform.isAndroid) return AndroidUsb.instance.hasPermission(device);
    return false;
  }

  /// Requests access and waits for the permission decision.
  ///
  /// Concurrent requests for the same attachment share a decision. Denial or
  /// detachment returns false. Session termination completes with an error.
  /// No timeout is imposed and an already-authorized attachment completes true.
  /// Foreign device ownership fails rather than targeting another connection.
  /// Other platforms currently return false without requesting anything.
  Future<bool> requestPermission(UsbDevice device) async {
    if (Platform.isAndroid) {
      return AndroidUsb.instance.requestPermission(device);
    }
    return false;
  }

  /// Opens [device], or returns null if it cannot be opened.
  ///
  /// Does not request permission implicitly. Android exceptions are propagated.
  /// A retired Android attachment fails with [StateError]; a device from another
  /// engine or implementation fails with [ArgumentError]. A connection opened
  /// across retirement is closed before publication. Other platforms return null.
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) async {
    if (Platform.isAndroid) return AndroidUsb.instance.openDevice(device);
    return null;
  }
}
