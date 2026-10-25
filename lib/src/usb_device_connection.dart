import 'dart:async';
import 'dart:typed_data';

import 'usb_configuration.dart';
import 'usb_endpoint.dart';
import 'usb_interface.dart';
import 'usb_request.dart';

/// A connection returned by `UsbManager.openDevice`.
///
/// Android implements management, information and USB transport through JNI.
/// Windows extensions are not implemented by the Android backend.
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
  /// OUT bytes are snapshotted before submission; IN copies only the completed
  /// prefix into this slice. Non-empty IN requires writable memory, checked
  /// before native submission; read-only destinations fail with ArgumentError.
  /// Do not modify the slice until the future completes.
  /// Null permits only an empty slice. Native byte counts (including negative
  /// failure results) and exceptions are preserved. The plugin adds no 16 KiB
  /// limit, but Android truncates bulk lengths to 16,384 when the app targets <28.
  /// Runs on a session worker, in parallel with other transfers and management.
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
  /// Direction comes from bit 7 of [requestType]. OUT bytes are snapshotted;
  /// IN copies only the completed prefix. Null permits only an empty slice.
  /// Non-empty IN requires a writable buffer; read-only views fail with
  /// ArgumentError before native submission. Do not modify it until completion.
  /// Native byte counts and exceptions are preserved.
  /// Runs on a session worker, not the management FIFO.
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
  /// Uses the native no-argument or timed overload, respectively. A native timed
  /// wait timeout throws Android's TimeoutException; null is its native error
  /// result, not a synthesized timeout. Negative timed waits are rejected by Android.
  /// Returns the original queued Dart request and updates its transferredLength
  /// and IN slice before completing. Multiple waits may run on session workers.
  Future<UsbRequest?> requestWait({int? timeout});

  /// Closes the connection.
  ///
  /// Android close is idempotent and waits for in-flight management operations.
  /// Scheduling it immediately rejects new work on the entire connection.
  /// Calls native close once, without separate per-interface release calls;
  /// Android/kernel own resource teardown. Even if native close
  /// throws, this connection is permanently unusable; that error is reported
  /// to the callers awaiting that attempt. Later close calls remain safe.
  /// Detaching the device or ending the engine session also closes it.
  /// Explicit close drains already-accepted management work; detach or session
  /// end rejects queued work before native access. A native call already running
  /// is not forcibly interrupted. JNI finalization alone does not close the connection.
  /// Blocking transport is not joined or placed ahead of close in the FIFO.
  /// Native close decides how already-entered transfers/waits terminate; there
  /// is no watchdog, polling or added timeout. Native requests are also closed;
  /// no completion or IN data is fabricated for abandoned requests.
  /// WARNING: concurrent native close and active I/O have an unresolved native
  /// lifetime race. Do not rely on close as a safe transfer interruption mechanism.
  /// Resolution is deferred; no new waiting or cancellation policy is introduced.
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
