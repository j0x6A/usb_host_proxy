import 'dart:io';
import 'dart:typed_data';

import 'android/android_usb.dart';
import 'usb_device_connection.dart';
import 'usb_endpoint.dart';

/// A reusable asynchronous request for a bulk or interrupt endpoint.
///
/// Android delegates to a native UsbRequest. Other platforms retain placeholders.
/// On those platforms, getters return null, initialize/queue/cancel return false,
/// and setClientData/close do nothing. Constructing a request does not open USB.
class UsbRequest {
  /// Creates an uninitialized request, matching Android's public constructor.
  UsbRequest();

  /// Completed byte count, replacing Java ByteBuffer position advancement.
  ///
  /// Null before the first completion and while a new accepted queue is pending.
  /// Updated when requestWait delivers this same request object, including cancel.
  int? get transferredLength =>
      Platform.isAndroid ? AndroidUsb.request(this).transferredLength : null;

  /// Returns the caller's context data.
  ///
  /// Android retains this Dart object without trying to serialize it through JNI.
  Object? getClientData() =>
      Platform.isAndroid ? AndroidUsb.request(this).getClientData() : null;

  /// Sets the caller's context data.
  ///
  /// This is opaque caller data, independent of the native completion identity.
  void setClientData(Object? data) {
    if (Platform.isAndroid) AndroidUsb.request(this).setClientData(data);
  }

  /// Returns the endpoint associated with this request.
  ///
  /// Null before successful initialization and after close.
  UsbEndpoint? getEndpoint() =>
      Platform.isAndroid ? AndroidUsb.request(this).getEndpoint() : null;

  /// Initializes this request for [endpoint] on [connection].
  ///
  /// Requires an original endpoint belonging to this connection's device.
  /// Returns native true/false; close an initialized request before reinitializing.
  Future<bool> initialize(
    UsbDeviceConnection connection,
    UsbEndpoint endpoint,
  ) async {
    if (Platform.isAndroid) {
      return AndroidUsb.request(this).initialize(connection, endpoint);
    }
    return false;
  }

  /// Queues the specified buffer slice; the future reports acceptance only.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  ///
  /// OUT bytes are snapshotted at submission. IN bytes are copied back into the
  /// supplied slice only when requestWait delivers completion. Do not modify or
  /// reuse that slice/request until then. Null denotes a zero-length request.
  /// Non-empty IN requires a writable Uint8List; read-only views fail with
  /// ArgumentError before native allocation/queueing. Read-only OUT is supported.
  /// The app's targetSdk <28 makes Android reject buffers above 16,384 bytes,
  /// even on an API 28+ device. The plugin does not add its own size limit.
  /// False and exceptions preserve the previous completion and buffer ownership.
  Future<bool> queue(Uint8List? buffer, {int offset = 0, int? length}) async {
    if (Platform.isAndroid) {
      return AndroidUsb.request(this)
          .queue(buffer, offset: offset, length: length);
    }
    return false;
  }

  /// Requests cancellation of a queued operation; returns native acceptance.
  ///
  /// Cancellation is not completion: drain the request with requestWait before
  /// reuse. No fabricated completion, polling or retry is performed here.
  /// An uninitialized/closed request or closing connection returns false.
  Future<bool> cancel() async {
    if (Platform.isAndroid) return AndroidUsb.request(this).cancel();
    return false;
  }

  /// Releases request resources.
  ///
  /// Android close is idempotent, does not await requestWait and invalidates any
  /// outstanding Dart result. Connection close/detach also closes native requests.
  /// Native close/cancel races retain platform outcomes; no timeout is added.
  /// WARNING: close while a native request is pending or being reaped has an
  /// unresolved native lifetime race; a successful mock test does not establish safety.
  /// Resolution is deferred; close does not add an automatic cancel/drain sequence.
  Future<void> close() async {
    if (Platform.isAndroid) await AndroidUsb.request(this).close();
  }
}
