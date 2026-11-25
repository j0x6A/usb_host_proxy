import 'dart:async';
import 'dart:typed_data';

import 'usb_configuration.dart';
import 'usb_endpoint.dart';
import 'usb_interface.dart';
import 'usb_request.dart';

/// A connection returned by `UsbManager.openDevice`.
///
/// Android implements management, information and transfers through JNI.
/// Windows pipe extensions are unsupported.
/// New implemented operations on a closed/detached Android connection fail with
/// [StateError]. Results already completed by Java are preserved even if their
/// Dart delivery occurs after detach. Unsupported members always fail with
/// [UnsupportedError].
///
/// Transfers and connection changes use the session's shared
/// workers without FIFO ordering. Await results before submitting dependent
/// operations. Interface/configuration arguments
/// must be Android descriptor adapters. Their native references are forwarded
/// without checking whether they occur in this device's descriptor tree;
/// Android decides the result.
abstract class UsbDeviceConnection {
  // Android USB host API.

  /// Returns the borrowed Android file descriptor owned by this connection.
  ///
  /// Leave closing the descriptor to the connection. Explicit close, device
  /// detach, or engine shutdown can close it before the caller uses it or calls
  /// `dup`. The OS can reuse the number after close. The caller owns and closes
  /// any descriptor it successfully duplicates.
  ///
  /// The original descriptor and any `dup` copies share one usbfs completion
  /// queue. Concurrent [UsbRequest] transfers and native asynchronous USB I/O
  /// (such as libusb) require separate opens, each with its own queue.
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
  /// [offset] is relative to the supplied view. Omitting [length] selects its
  /// remainder. A null [buffer] denotes a zero-length transfer at offset zero.
  /// OUT copies the slice at submission. For IN, a non-empty slice must be
  /// writable. A positive result writes only that many bytes before completion.
  /// The result can be shorter than [length]. Zero and negative Android
  /// results leave the caller's buffer untouched.
  /// [timeout] is in milliseconds. Zero permits an indefinite wait and can
  /// delay [close] until Android returns.
  Future<int> bulkTransfer(
    UsbEndpoint endpoint,
    Uint8List? buffer, {
    int offset = 0,
    int? length,
    int timeout = 0,
  });

  /// Transfers a data slice using a setup packet on the default control pipe.
  ///
  /// The direction bit in [requestType] selects IN or OUT. [buffer], [offset],
  /// [length], [timeout] and the returned byte count follow [bulkTransfer].
  /// Pass null for a setup packet with no data stage.
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
  /// [timeout] is in milliseconds. Null waits indefinitely. Zero checks once
  /// and calls Android only if an outstanding transfer is unreserved. A positive
  /// timeout includes waiting for a reservation. The remaining budget is passed
  /// once to Android, which defines the native behavior for very large values.
  /// A timeout throws [TimeoutException] and leaves transfers queued. Android's
  /// null result indicates a native wait error. A successful result is the
  /// original request object with its length and IN bytes updated.
  Future<UsbRequest?> requestWait({int? timeout});

  /// Closes the connection.
  ///
  /// Android close is idempotent. Scheduling it rejects work that has not
  /// passed its final lifecycle check under shared native access.
  /// Close wakes request waiters waiting for a reservation with [StateError]
  /// and attempts to cancel outstanding requests before waiting for admitted
  /// native calls to return. A bulk or control transfer with timeout zero can
  /// still keep close pending indefinitely. Close receives available leftover
  /// completions before releasing the native connection.
  /// This releases the plugin's references. Some Android implementations may
  /// retain framework references for requests that could not be received.
  /// Calls native close once, without separate per-interface release calls;
  /// Android/kernel own resource teardown. Even if native close
  /// throws, this connection is permanently unusable; that error is reported
  /// to the callers awaiting that attempt. Later close calls remain safe.
  /// Detaching the device or ending the engine session also closes it.
  /// Java initiates device/session cleanup even without Dart listeners. The
  /// retained JNI view can remain until GC after Java clears its native connection;
  /// a detach notification does not mean native close has already finished.
  /// Workers check admission when they run. Admitted calls may run concurrently.
  /// Close does not wait for Dart callback delivery. JNI finalization does not
  /// close the connection.
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
