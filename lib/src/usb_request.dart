import 'dart:io';
import 'dart:typed_data';

import 'android/android_usb.dart';
import 'usb_device_connection.dart';
import 'usb_endpoint.dart';

/// A reusable asynchronous request for a bulk or interrupt endpoint.
///
/// Queued requests use Android's USB host API. On other platforms [initialize],
/// [queue], and [cancel] fail with [UnsupportedError].
class UsbRequest {
  /// Creates an uninitialized request, matching Android's public constructor.
  UsbRequest();

  late final _android = Platform.isAndroid ? AndroidUsbRequest(this) : null;
  Object? _clientData;

  /// Byte count of the most recently delivered completion for this object.
  ///
  /// Null until the first completion. Read it when [UsbDeviceConnection.requestWait]
  /// returns, before another completion for this object can be delivered.
  int? get transferredLength => _android?.transferredLength;

  /// Returns the caller's context data.
  Object? getClientData() => _clientData;

  /// Sets the caller's context data.
  ///
  /// On Android this stays in Dart and survives initialization and close.
  void setClientData(Object? data) {
    if (Platform.isAndroid) _clientData = data;
  }

  /// Returns the endpoint associated with this request.
  ///
  /// The plugin returns null when there is no successful live binding, including
  /// after Android returns false from initialization.
  UsbEndpoint? getEndpoint() => _android?.getEndpoint();

  /// Initializes this request for [endpoint] on [connection].
  ///
  /// Rebinding an idle request releases the old handle first. A false result
  /// leaves the request unbound. With an unreceived transfer, this fails with
  /// [StateError] and leaves the binding intact.
  Future<bool> initialize(
    UsbDeviceConnection connection,
    UsbEndpoint endpoint,
  ) async => _requireAndroid().initialize(connection, endpoint);

  /// Queues the specified buffer slice; the future reports acceptance only.
  ///
  /// [offset] is relative to [buffer]; omitted [length] denotes its remainder.
  ///
  /// OUT snapshots the slice at submission. A nonempty IN slice must be writable
  /// and remains reserved until the transfer is delivered or discarded on close.
  /// A null buffer requests a zero-length transfer. Android delivers completion
  /// through [UsbDeviceConnection.requestWait].
  Future<bool> queue(Uint8List? buffer, {int offset = 0, int? length}) async =>
      _requireAndroid().queue(buffer, offset: offset, length: length);

  /// Requests cancellation of a queued operation; returns native acceptance.
  ///
  /// On Android, an unbound request or a released handle returns false.
  /// An accepted cancellation still requires the connection to receive or
  /// discard the completion before the request can be reused or closed.
  Future<bool> cancel() async => _requireAndroid().cancel();

  /// Releases request resources.
  ///
  /// On Android the plugin fails with [StateError] if a queued transfer has not
  /// been received by [UsbDeviceConnection.requestWait], even after [cancel].
  /// Receive the completion before retrying, or close the whole connection.
  /// Closing an unbound or already closed request succeeds.
  Future<void> close() async {
    final android = _android;
    if (android != null) await android.close();
  }

  AndroidUsbRequest _requireAndroid() =>
      _android ??
      (throw UnsupportedError('USB request transport is not implemented'));
}
