import 'dart:async';
import 'dart:typed_data';

import 'usb_configuration.dart';
import 'usb_endpoint.dart';
import 'usb_interface.dart';
import 'usb_request.dart';

/// A connection returned by `UsbManager.openDevice`.
///
/// Platform operations are declarations without an implementation.
abstract class UsbDeviceConnection {
  // Android USB host API.

  /// Returns the Android native file descriptor.
  Future<int> getFileDescriptor();

  /// Returns the raw USB descriptors.
  Future<Uint8List?> getRawDescriptors();

  /// Returns the device serial string.
  Future<String?> getSerial();

  /// Claims [intf] before transferring on its non-control endpoints.
  Future<bool> claimInterface(UsbInterface intf, {bool force = false});

  /// Releases this connection's interface claim according to OS access rules.
  Future<bool> releaseInterface(UsbInterface intf);

  /// Selects the interface's alternate setting.
  Future<bool> setInterface(UsbInterface intf);

  /// Selects the configuration; returns whether the OS accepted selection.
  Future<bool> setConfiguration(UsbConfiguration configuration);

  /// Transfers a slice on a bulk endpoint, in the endpoint's direction.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  /// [timeout] is in milliseconds, with zero denoting an indefinite wait.
  Future<int> bulkTransfer(
    UsbEndpoint endpoint,
    Uint8List? buffer, {
    int offset = 0,
    int? length,
    int timeout = 0,
  });

  /// Transfers a data slice using a setup packet on the default control pipe.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  /// [timeout] is in milliseconds, with zero denoting an indefinite wait.
  Future<int> controlTransfer(
    int requestType,
    int request,
    int value,
    int index,
    Uint8List? buffer, {
    int offset = 0,
    int? length,
    int timeout = 0,
  });

  /// Waits for a completed request queued on any endpoint of this connection.
  ///
  /// [timeout] is in milliseconds. Null denotes an indefinite wait; zero polls.
  Future<UsbRequest?> requestWait({int? timeout});

  /// Closes the connection.
  Future<void> close();

  // Windows USB pipe extensions.

  /// Clears the pipe stall and resets its data toggle; returns success.
  Future<bool> resetPipe(UsbInterface intf, UsbEndpoint endpoint);

  /// Aborts all pending transfers on the interface's endpoint pipe.
  Future<bool> abortPipe(UsbInterface intf, UsbEndpoint endpoint);

  /// Discards data cached for the interface's endpoint pipe; returns success.
  Future<bool> flushPipe(UsbInterface intf, UsbEndpoint endpoint);

  /// Sets a WinUSB pipe policy; returns whether the OS accepted it.
  Future<bool> setPipePolicy(
    UsbInterface intf,
    UsbEndpoint endpoint,
    int policyType,
    Uint8List value,
  );

  /// Returns a WinUSB pipe policy value, or null if unavailable.
  Future<Uint8List?> getPipePolicy(
    UsbInterface intf,
    UsbEndpoint endpoint,
    int policyType,
  );
}
