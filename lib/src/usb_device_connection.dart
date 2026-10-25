import 'dart:async';
import 'dart:typed_data';

import 'usb_configuration.dart';
import 'usb_endpoint.dart';
import 'usb_interface.dart';
import 'usb_request.dart';

/// A connection returned by `UsbManager.openDevice`.
///
/// Android implements management and information operations through JNI.
/// Transport and Windows extensions are not implemented by the Android backend.
/// New implemented operations on a closed/detached Android connection fail with
/// [StateError]. Results already completed by Java are preserved even if their
/// Dart delivery occurs after detach. Unsupported members always fail with
/// [UnsupportedError].
///
/// Android management operations run on the session's shared worker pool without
/// FIFO ordering, including operations on the same connection. Await results
/// before submitting dependent operations. Interface/configuration arguments
/// must be Android descriptor adapters. Their native references are forwarded
/// without checking whether they occur in this device's descriptor tree;
/// Android decides the result.
abstract class UsbDeviceConnection {
  // Android USB host API.

  /// Returns the Android native file descriptor.
  /// Ownership stays with this connection; the integer is invalid after close.
  Future<int> getFileDescriptor();

  /// Returns the raw USB descriptors.
  /// Android's null result is preserved; returned bytes are copied into Dart
  /// memory. Reading does not issue an additional control transfer here.
  Future<Uint8List?> getRawDescriptors();

  /// Returns the device serial string.
  ///
  /// Android reads it on a session worker. Native null is preserved;
  /// permission or framework failures remain errors.
  Future<String?> getSerial();

  /// Claims [intf] before transferring on its non-control endpoints.
  /// Android decides whether the claim is allowed, including repeated calls.
  /// [force] is forwarded unchanged, not a guarantee of success. Native booleans
  /// and exceptions are preserved through the existing error translation.
  Future<bool> claimInterface(UsbInterface intf, {bool force = false});

  /// Releases this connection's interface claim according to OS access rules.
  /// Forwarded to Android even without a previous claim. The native boolean is
  /// returned unchanged; exceptions remain errors, never synthetic false results.
  /// There is no local claim history or release-specific admission barrier.
  Future<bool> releaseInterface(UsbInterface intf);

  /// Selects the interface's alternate setting.
  /// Forwarded to Android without requiring a recorded claim or caching the
  /// selected setting. Returns the native boolean and preserves exceptions.
  Future<bool> setInterface(UsbInterface intf);

  /// Selects the configuration; returns whether the OS accepted selection.
  /// Forwarded to Android independently of previous claim/release results.
  /// Exceptions remain errors; no local interface ownership rules are applied.
  Future<bool> setConfiguration(UsbConfiguration configuration);

  /// Transfers a slice on a bulk endpoint, in the endpoint's direction.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  /// [timeout] is in milliseconds, with zero denoting an indefinite wait.
  /// Currently unsupported on Android: the returned future fails with
  /// [UnsupportedError] without inspecting the endpoint or buffer.
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
  /// Currently unsupported on Android: the returned future fails with
  /// [UnsupportedError] without inspecting the arguments or buffer.
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
  /// Currently unsupported on Android: the returned future fails with
  /// [UnsupportedError] without waiting or inspecting [timeout].
  Future<UsbRequest?> requestWait({int? timeout});

  /// Closes the connection.
  ///
  /// Android close is idempotent and waits for admitted native calls, including
  /// direct file-descriptor and raw-descriptor reads.
  /// Scheduling it immediately rejects new work on the entire connection.
  /// Calls native close once, without separate per-interface release calls;
  /// Android/kernel own resource teardown. Even if native close
  /// throws, this connection is permanently unusable; that error is reported
  /// to the callers awaiting that attempt. Later close calls remain safe.
  /// Detaching the device or ending the engine session also closes it.
  /// The retained JNI connection reference is released after the close future
  /// settles. Device invalidation initiates this cleanup even without listeners;
  /// a detach notification does not mean native close has already finished.
  /// Close, detach and session end reject work not yet admitted to native access,
  /// even if it has already been submitted to a worker. Close runs on a session
  /// worker without FIFO; lifetime protection waits only for admitted native
  /// calls to return. Those calls may run concurrently and are not forcibly
  /// interrupted. Callbacks have no completion-order guarantee. JNI finalization
  /// alone does not close the connection.
  ///
  /// Admission is the last lifecycle check while holding shared native access.
  /// Invalidating pending work prevents native entry; it does not guarantee
  /// immediate completion of its future. If an admitted native call does not
  /// return, close cannot finish. No timeout or forced interruption is added.
  Future<void> close();

  // Windows USB pipe extensions. Every method in this group currently fails
  // with UnsupportedError on Android; there is no Windows backend yet.

  /// Clears the pipe stall and resets its data toggle; returns success.
  /// The Android backend currently fails with UnsupportedError.
  Future<bool> resetPipe(UsbInterface intf, UsbEndpoint endpoint);

  /// Aborts all pending transfers on the interface's endpoint pipe.
  /// The Android backend currently fails with UnsupportedError.
  Future<bool> abortPipe(UsbInterface intf, UsbEndpoint endpoint);

  /// Discards data cached for the interface's endpoint pipe; returns success.
  /// The Android backend currently fails with UnsupportedError.
  Future<bool> flushPipe(UsbInterface intf, UsbEndpoint endpoint);

  /// Sets a WinUSB pipe policy; returns whether the OS accepted it.
  /// The Android backend currently fails with UnsupportedError.
  Future<bool> setPipePolicy(
    UsbInterface intf,
    UsbEndpoint endpoint,
    int policyType,
    Uint8List value,
  );

  /// Returns a WinUSB pipe policy value, or null if unavailable.
  /// The Android backend currently fails with UnsupportedError.
  Future<Uint8List?> getPipePolicy(
    UsbInterface intf,
    UsbEndpoint endpoint,
    int policyType,
  );
}
