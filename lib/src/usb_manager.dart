import 'dart:async';

import 'usb_backend_selector.dart';
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
  Stream<UsbDevice> get deviceAttached => usbBackend.deviceAttached;

  /// Stream of device views for names removed from the observed device list.
  ///
  /// Device views and all their descendants are invalidated before notification;
  /// connection cleanup has started but may still be finishing admitted calls.
  /// The payload refers to an inert Java view: only its name, equality and hash
  /// remain usable. Technical JNI references may stay until Dart GC.
  /// Cleanup does not require a subscriber. The manager remains usable when the
  /// device list becomes empty.
  /// Java rejects an old queued detach after a newer same-name device view
  /// has already been exposed to Dart through enumeration or an attach event.
  Stream<UsbDevice> get deviceDetached => usbBackend.deviceDetached;

  /// Returns devices keyed by the name returned by [UsbDevice.getDeviceName].
  ///
  /// Does not open devices or request permission. Enumeration can report detach
  /// for a previously known device that is now absent, but does not emit attach
  /// for every listed device. Returns current framework views without copying
  /// descriptor fields. Older views stay valid only until observed removal or
  /// session termination; they cannot access a later device with the same name.
  /// Android adapter equality and hashing follow the device name, independently
  /// of wrapper identity.
  ///
  /// On Android the enumeration itself is synchronous JNI work. Other platforms
  /// currently return an empty map.
  Future<Map<String, UsbDevice>> getDeviceList() async =>
      usbBackend.getDeviceList();

  /// Whether the application currently has permission to access [device].
  ///
  /// Android's result is returned for a still-valid descriptor view. Objects
  /// from another engine or implementation are rejected. The framework check runs
  /// synchronously despite this method returning a Future. Other platforms
  /// currently return false. Invalidated Android views fail with [StateError].
  Future<bool> hasPermission(UsbDevice device) async =>
      usbBackend.hasPermission(device);

  /// Requests access and waits for the permission decision.
  ///
  /// Concurrent requests for the same Android name share a decision. Denial or
  /// detachment returns false. Session termination completes with an error.
  /// No timeout is imposed and an already-authorized attachment completes true.
  /// Another engine's device or a foreign implementation fails before native access.
  /// Starting a new request with an invalidated device fails with [StateError].
  /// A decision already completed by Java is preserved despite delayed delivery;
  /// it does not guarantee the device is still present. A pending request cancelled
  /// by detach resolves false.
  /// Other platforms currently return false without requesting anything.
  Future<bool> requestPermission(UsbDevice device) async =>
      usbBackend.requestPermission(device);

  /// Opens [device], or returns null if it cannot be opened.
  ///
  /// Does not request permission implicitly. Android exceptions are propagated.
  /// A view from an ended device lifetime fails with [StateError], even if Android
  /// reuses its name. Another engine/implementation fails with [ArgumentError].
  /// An open attempt invalidated by observed detach closes any late native result
  /// and fails with [StateError]. Session termination also fails pending opens.
  /// A closed connection is never reused. Other platforms return null.
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) async =>
      usbBackend.openDevice(device);
}
