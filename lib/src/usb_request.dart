import 'dart:typed_data';

import 'usb_device_connection.dart';
import 'usb_endpoint.dart';

/// A reusable asynchronous request for a bulk or interrupt endpoint.
///
/// This class currently contains placeholders on every platform; no requests
/// are submitted. Arguments and buffers are not inspected or retained, and
/// calling [close] does not change subsequent placeholder results.
class UsbRequest {
  /// Creates an uninitialized request, matching Android's public constructor.
  UsbRequest();

  /// Completed byte count, replacing Java ByteBuffer position advancement.
  ///
  /// NOT IMPLEMENTED YET: always returns null.
  int? get transferredLength => null;

  /// Returns the caller's context data.
  ///
  /// NOT IMPLEMENTED YET: always returns null.
  Object? getClientData() => null;

  /// Sets the caller's context data.
  ///
  /// NOT IMPLEMENTED YET: does not store the supplied data.
  void setClientData(Object? data) {}

  /// Returns the endpoint associated with this request.
  ///
  /// NOT IMPLEMENTED YET: always returns null.
  UsbEndpoint? getEndpoint() => null;

  /// Initializes this request for [endpoint] on [connection].
  ///
  /// NOT IMPLEMENTED YET: returns false without initializing the request.
  Future<bool> initialize(
    UsbDeviceConnection connection,
    UsbEndpoint endpoint,
  ) async {
    return false;
  }

  /// Queues the specified buffer slice; the future reports acceptance only.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  ///
  /// NOT IMPLEMENTED YET: returns false without queuing or accessing the buffer.
  Future<bool> queue(Uint8List? buffer, {int offset = 0, int? length}) async {
    return false;
  }

  /// Requests cancellation of a queued operation; returns native acceptance.
  ///
  /// NOT IMPLEMENTED YET: returns false without requesting cancellation.
  Future<bool> cancel() async {
    return false;
  }

  /// Releases request resources.
  ///
  /// NOT IMPLEMENTED YET: does nothing.
  Future<void> close() async {}
}
