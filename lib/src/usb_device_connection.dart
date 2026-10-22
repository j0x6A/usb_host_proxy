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
/// Operations on a closed/detached Android connection fail with StateError.
///
/// Each Android connection has an independent ordered queue for management
/// operations. Interface/configuration arguments must be original descriptors
/// from the same attachment; matching numeric IDs alone do not establish ownership.
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
  Future<String?> getSerial();

  /// Claims [intf] before transferring on its non-control endpoints.
  /// On Android this connection must record UNCLAIMED (the initial state).
  /// Native true records CLAIMED; false leaves UNCLAIMED. CLAIMED, UNKNOWN or
  /// a pending release reject claim with StateError before native access.
  /// Alternate settings share state by interface number, independently per
  /// connection. [force] is forwarded unchanged, not a guarantee of success.
  Future<bool> claimInterface(UsbInterface intf, {bool force = false});

  /// Releases this connection's interface claim according to OS access rules.
  /// Android rejects UNCLAIMED with StateError. From CLAIMED or UNKNOWN, native
  /// true records UNCLAIMED; false records UNKNOWN and is returned unchanged.
  /// UNKNOWN permits another release or close, not claim/setInterface; no
  /// recovery is automatic. Admission of further claim/setInterface calls is
  /// blocked from release submission until it settles. Earlier accepted work
  /// retains FIFO ordering. Validation errors do not change claim state or
  /// become false results. Exceptions propagate as errors, not false, and retain
  /// the last observation; it is not proof that an exceptional call had no effects.
  Future<bool> releaseInterface(UsbInterface intf);

  /// Selects the interface's alternate setting.
  /// On Android requires CLAIMED and no pending release of this interface.
  Future<bool> setInterface(UsbInterface intf);

  /// Selects the configuration; returns whether the OS accepted selection.
  /// Android success invalidates all recorded claims on this connection;
  /// false or argument validation failure preserves them. UNKNOWN interfaces
  /// must be released (or the connection closed) before configuration selection.
  Future<bool> setConfiguration(UsbConfiguration configuration);

  /// Transfers a slice on a bulk endpoint, in the endpoint's direction.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  /// [timeout] is in milliseconds, with zero denoting an indefinite wait.
  /// Currently unsupported on Android: the returned future fails with UnsupportedError.
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
  /// Currently unsupported on Android: the returned future fails with UnsupportedError.
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
  /// Currently unsupported on Android: the returned future fails with UnsupportedError.
  Future<UsbRequest?> requestWait({int? timeout});

  /// Closes the connection.
  ///
  /// Android close is idempotent and waits for in-flight management operations.
  /// Scheduling it immediately rejects new work on the entire connection.
  /// Calls native close once, without separate per-interface release calls;
  /// Android/kernel own resource teardown. Interface observations are discarded,
  /// never changed to UNKNOWN on a closed connection. Even if native close
  /// throws, this connection is permanently unusable; that error is reported
  /// to the callers awaiting that attempt. Later close calls remain safe.
  /// Detaching the device or ending the engine session also closes it.
  /// Explicit close drains already-accepted work; detach or session end rejects
  /// queued work before native access. A native call already running is not
  /// forcibly interrupted. JNI finalization alone does not close the connection.
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
