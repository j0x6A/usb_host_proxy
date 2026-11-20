import 'dart:typed_data';

import 'usb_device_connection.dart';
import 'usb_endpoint.dart';

/// A reusable asynchronous request for a bulk or interrupt endpoint.
///
/// Queued requests are unsupported on every platform. [initialize], [queue],
/// and [cancel] return futures that fail with [UnsupportedError].
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
  /// The returned future fails with [UnsupportedError].
  Future<bool> initialize(
    UsbDeviceConnection connection,
    UsbEndpoint endpoint,
  ) async => throw UnsupportedError('USB request transport is not implemented');

  /// Queues the specified buffer slice; the future reports acceptance only.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  ///
  /// The returned future fails with [UnsupportedError] without accessing the
  /// buffer.
  Future<bool> queue(Uint8List? buffer, {int offset = 0, int? length}) async =>
      throw UnsupportedError('USB request transport is not implemented');

  /// Requests cancellation of a queued operation; returns native acceptance.
  ///
  /// The returned future fails with [UnsupportedError].
  Future<bool> cancel() async =>
      throw UnsupportedError('USB request transport is not implemented');

  /// Releases request resources.
  ///
  /// NOT IMPLEMENTED YET: does nothing.
  Future<void> close() async {}
}
