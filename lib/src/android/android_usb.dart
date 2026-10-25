import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:jni/jni.dart';

import '../usb_configuration.dart';
import '../usb_device.dart';
import '../usb_device_connection.dart';
import '../usb_endpoint.dart';
import '../usb_interface.dart';
import '../usb_request.dart';
import 'bindings.g.dart' as j;
import 'transfer_buffer.dart';

// JNI references, not cached USB descriptor fields, are owned by these adapters.
// Temporary references are released eagerly. Escaping references use JNI's native
// finalizer because the public descriptor API has no dispose/release operation.
/// Translates Java state/argument failures; other Java exceptions remain intact.
///
/// The caught exception reference is released here only when it is replaced by a
/// Dart error. A rethrown [JThrowable] remains owned by the receiving caller.
T _java<T>(T Function() operation) {
  try {
    return operation();
  } on JThrowable catch (error) {
    if (error.isA(j.IllegalStateException.type)) {
      final message = error.message;
      error.release();
      throw StateError(message);
    }
    if (error.isA(j.IllegalArgumentException.type)) {
      final message = error.message;
      error.release();
      throw ArgumentError(message);
    }
    rethrow;
  }
}

/// Consumes a temporary Java string reference and preserves native null.
String? _string(JString? value) => value?.toDartString(releaseOriginal: true);

/// Adapts one Java completion listener to a Dart future.
///
/// [start] submits work, while [decode] reads the callback's borrowed result.
/// Callback arguments are released after decoding; any escaping object must
/// retain its own JNI reference, as the connection cast below does. Java keeps
/// the listener alive until completion, so Dart releases its proxy after start.
Future<T> _call<T>(
  void Function(j.UsbHostProxy$Completion) start,
  T Function(JObject?) decode,
) {
  final result = Completer<T>();
  final callback = j.UsbHostProxy$Completion.implement(
    j.$UsbHostProxy$Completion(
      success$async: true,
      failure$async: true,
      success: (value) {
        try {
          if (!result.isCompleted) result.complete(decode(value));
        } catch (error, stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        } finally {
          value?.release();
        }
      },
      failure: (error) {
        try {
          // Throw on the JNI thread so JNIgen preserves the original Java
          // exception type, message and stack trace, just like direct calls.
          _java(() => j.UsbHostProxy.rethrowError(error));
          if (!result.isCompleted) {
            result.completeError(StateError('Missing Android error'));
          }
        } catch (failure, stack) {
          if (!result.isCompleted) result.completeError(failure, stack);
        } finally {
          error?.release();
        }
      },
    ),
  );
  try {
    _java(() => start(callback));
  } catch (error, stack) {
    if (!result.isCompleted) result.completeError(error, stack);
  } finally {
    // Android now owns the proxy until the operation finishes. Keeping a Dart
    // JNI reference here would create a Java -> closure -> JNI reference cycle.
    callback.release();
  }
  return result.future;
}

/// Decodes a non-null boxed Boolean without retaining its temporary typed view.
bool _boolean(JObject? value) =>
    value!.as(JBoolean.type).use((v) => v.booleanValue());

/// Decodes an optional callback string; [_call] releases the incoming reference.
String? _resultString(JObject? value) =>
    value?.as(JString.type).use((v) => v.toDartString());

/// Internal Android backend, shared by managers in the engine's root isolate.
final class AndroidUsb {
  /// Weak keys preserve the existing generative UsbRequest constructor/subclasses.
  /// An initialized connection retains requests until explicit or connection close.
  static final _requests = Expando<UsbRequest>();

  static UsbRequest request(UsbRequest original) =>
      _requests[original] ??= _AndroidRequest(original);

  /// Lazily binds the root isolate to the session already registered by Java.
  static final AndroidUsb instance = AndroidUsb._();

  /// Session JNI reference, released and cleared by the disposed callback.
  j.UsbHostProxy$Session? _reference;

  /// Live attachment notifications, dropped when no Dart listener is present.
  final _attached = StreamController<UsbDevice>.broadcast();

  /// Retired attachment notifications; descriptor references remain readable.
  final _detached = StreamController<UsbDevice>.broadcast();

  /// Installs one asynchronous JNIgen event listener; does not enumerate devices.
  AndroidUsb._() {
    if (RootIsolateToken.instance == null) {
      throw StateError('USB objects must be used in the engine root isolate');
    }
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) throw StateError('No Flutter engine is attached');
    _reference = _java(() => j.UsbHostProxy.session(engineId))!;
    final listener = j.UsbHostProxy$Events.implement(
      j.$UsbHostProxy$Events(
        attached$async: true,
        detached$async: true,
        disposed$async: true,
        attached: (device) => _event(_attached, device),
        detached: (device) => _event(_detached, device),
        disposed: () {
          _reference?.release();
          _reference = null;
          unawaited(_attached.close());
          unawaited(_detached.close());
        },
      ),
    );
    try {
      _java(() => _session.listen(listener));
    } catch (_) {
      _reference?.release();
      _reference = null;
      rethrow;
    } finally {
      listener.release();
    }
  }

  /// Requires an active binding rather than silently recreating an ended session.
  j.UsbHostProxy$Session get _session =>
      _reference ?? (throw StateError('USB session has ended'));

  /// Transfers an incoming device handle into an adapter, or releases it if unused.
  void _event(
    StreamController<UsbDevice> stream,
    j.UsbHostProxy$Device? device,
  ) {
    if (device == null) return;
    if (!stream.hasListener || stream.isClosed) {
      device.release();
      return;
    }
    try {
      stream.add(_AndroidDevice(device));
    } catch (error, stack) {
      device.release();
      stream.addError(error, stack);
    }
  }

  /// Broadcast attach stream; previously observed devices are not replayed.
  Stream<UsbDevice> get deviceAttached => _attached.stream;

  /// Broadcast detach stream for invalidated attachment wrappers.
  Stream<UsbDevice> get deviceDetached => _detached.stream;

  /// Enumerates synchronously via JNI, retaining device handles but not the array.
  ///
  /// Public keys remain Android names. Java may emit detach while reconciling
  /// missing devices; it does not synthesize attach merely from enumeration.
  Map<String, UsbDevice> getDeviceList() => _java(() {
    final array = _session.deviceList()!;
    try {
      final result = <String, UsbDevice>{};
      for (var i = 0; i < array.length; i++) {
        final handle = array[i]!;
        try {
          final device = _AndroidDevice(handle);
          result[device.getDeviceName()] = device;
        } catch (_) {
          handle.release();
          rethrow;
        }
      }
      return result;
    } finally {
      array.release();
    }
  });

  /// Rejects foreign Dart implementations; Java then validates engine ownership.
  _AndroidDevice _device(UsbDevice device) {
    if (device is! _AndroidDevice) {
      throw ArgumentError.value(
        device,
        'device',
        'Expected an Android USB device',
      );
    }
    return device;
  }

  /// Direct JNI permission check; the Future-shaped public API does not offload it.
  bool hasPermission(UsbDevice device) =>
      _java(() => _session.hasPermission(_device(device).handle));

  /// Awaits the coalesced native decision for this attachment, without a timeout.
  Future<bool> requestPermission(UsbDevice device) => _call(
    (callback) => _session.requestPermission(_device(device).handle, callback),
    _boolean,
  );

  /// Wraps a published native connection, preserving null and Android failures.
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) => _call(
    (callback) => _session.open(_device(device).handle, callback),
    (value) => value == null
        ? null
        : _AndroidConnection(value.as(j.UsbHostProxy$Connection.type)),
  );

  /// Uses Android's name-to-ID conversion and releases the temporary Java input.
  static int deviceId(String name) => _java(() {
    final string = name.toJString();
    try {
      return j.UsbDevice.getDeviceId(string);
    } finally {
      string.release();
    }
  });

  /// Uses Android's ID-to-name conversion; this is not an attachment lookup.
  static String? deviceName(int id) =>
      _java(() => _string(j.UsbDevice.getDeviceName(id)));
}

/// Device adapter: lifecycle operations use [handle], descriptors use [native].
///
/// Getter contracts are documented by [UsbDevice]. No descriptor fields are
/// cached in Dart; both escaping JNI references use native finalizers.
final class _AndroidDevice implements UsbDevice {
  /// Canonical Java attachment wrapper, including its private UUID and owner.
  final j.UsbHostProxy$Device handle;

  /// Original Android descriptor object, not a copy of its fields.
  final j.UsbDevice native;

  /// Takes the escaping wrapper reference and obtains its descriptor reference.
  _AndroidDevice(this.handle) : native = _java(() => handle.usbDevice)!;

  @override
  UsbConfiguration getConfiguration(int index) =>
      _java(() => _AndroidConfiguration(native.getConfiguration(index)!));
  @override
  int getConfigurationCount() => _java(() => native.configurationCount);
  @override
  int getDeviceClass() => _java(() => native.deviceClass);
  @override
  int getDeviceId() => _java(() => native.deviceId);
  @override
  String getDeviceName() => _java(() => _string(native.deviceName)!);
  @override
  int getDeviceProtocol() => _java(() => native.deviceProtocol);
  @override
  int getDeviceSubclass() => _java(() => native.deviceSubclass);
  @override
  UsbInterface getInterface(int index) =>
      _java(() => _AndroidInterface(native.getInterface(index)!));
  @override
  int getInterfaceCount() => _java(() => native.interfaceCount);
  @override
  String? getManufacturerName() =>
      _java(() => _string(native.manufacturerName));
  @override
  int getProductId() => _java(() => native.productId);
  @override
  String? getProductName() => _java(() => _string(native.productName));
  @override
  Future<String?> getSerialNumber() => _call(handle.serial, _resultString);
  @override
  int getVendorId() => _java(() => native.vendorId);
  @override
  String getVersion() => _java(() => _string(native.version)!);
}

/// Thin descriptor view; method contracts are inherited from [UsbConfiguration].
final class _AndroidConfiguration implements UsbConfiguration {
  /// Escaping framework configuration reference, managed by the native finalizer.
  final j.UsbConfiguration native;

  /// Retains the supplied reference without copying descriptor values.
  _AndroidConfiguration(this.native);
  @override
  int getId() => _java(() => native.id);
  @override
  UsbInterface getInterface(int index) =>
      _java(() => _AndroidInterface(native.getInterface(index)!));
  @override
  int getInterfaceCount() => _java(() => native.interfaceCount);
  @override
  int getMaxPower() => _java(() => native.maxPower);
  @override
  String? getName() => _java(() => _string(native.name));
  @override
  bool isRemoteWakeup() => _java(() => native.isRemoteWakeup);
  @override
  bool isSelfPowered() => _java(() => native.isSelfPowered);
}

/// Thin descriptor view; method contracts are inherited from [UsbInterface].
final class _AndroidInterface implements UsbInterface {
  /// Original interface reference, also used for native ownership validation.
  final j.UsbInterface native;

  /// Retains the supplied reference without copying descriptor values.
  _AndroidInterface(this.native);
  @override
  int getAlternateSetting() => _java(() => native.alternateSetting);
  @override
  UsbEndpoint getEndpoint(int index) =>
      _java(() => _AndroidEndpoint(native.getEndpoint(index)!));
  @override
  int getEndpointCount() => _java(() => native.endpointCount);
  @override
  int getId() => _java(() => native.id);
  @override
  int getInterfaceClass() => _java(() => native.interfaceClass);
  @override
  int getInterfaceProtocol() => _java(() => native.interfaceProtocol);
  @override
  int getInterfaceSubclass() => _java(() => native.interfaceSubclass);
  @override
  String? getName() => _java(() => _string(native.name));
}

/// Thin descriptor view; method contracts are inherited from [UsbEndpoint].
final class _AndroidEndpoint implements UsbEndpoint {
  /// Escaping framework endpoint reference, managed by the native finalizer.
  final j.UsbEndpoint native;

  /// Retains the supplied reference without copying descriptor values.
  _AndroidEndpoint(this.native);
  @override
  int getAddress() => _java(() => native.address);
  @override
  int getAttributes() => _java(() => native.attributes);
  @override
  int getDirection() => _java(() => native.direction);
  @override
  int getEndpointNumber() => _java(() => native.endpointNumber);
  @override
  int getInterval() => _java(() => native.interval);
  @override
  int getMaxPacketSize() => _java(() => native.maxPacketSize);
  @override
  int getType() => _java(() => native.type$1);
}

/// Adapts connection calls and results; Java owns the queue and native close.
///
/// Supported method contracts are documented by [UsbDeviceConnection]. Releasing
/// a JNI reference is not a substitute for explicitly awaiting [close].
final class _AndroidConnection implements UsbDeviceConnection {
  /// Java connection owner; not a raw file descriptor or descriptor snapshot.
  final j.UsbHostProxy$Connection native;

  /// Restores the exact public request (and its opaque Dart client data) on wait.
  final Map<int, _AndroidRequest> _requests = {};

  /// Retains the reference produced by casting a Java completion result.
  _AndroidConnection(this.native) {
    // No close is requested here. The same Completion mechanism reports native
    // close/detach or session disposal even if the caller never calls close().
    unawaited(
      _call(native.whenClosed, (_) {}).then<void>(
        (_) => _forgetRequests(),
        onError: (Object error, StackTrace stack) => _forgetRequests(),
      ),
    );
  }

  void _forgetRequests() {
    for (final request in _requests.values.toList()) {
      request._forget();
    }
    _requests.clear();
  }

  /// Unwraps an Android interface; Java verifies it belongs to this attachment.
  j.UsbInterface _interface(UsbInterface intf) {
    if (intf is! _AndroidInterface) {
      throw ArgumentError.value(
        intf,
        'intf',
        'Expected an Android USB interface',
      );
    }
    return intf.native;
  }

  @override
  Future<int> getFileDescriptor() async => _java(native.fileDescriptor);

  /// Copies the returned Java byte array into Dart memory, then releases it.
  /// This does not perform an extra USB control transfer.
  @override
  Future<Uint8List?> getRawDescriptors() async => _java(() {
    final array = native.rawDescriptors();
    if (array == null) return null;
    try {
      final bytes = array.getRange(0, array.length);
      return Uint8List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
    } finally {
      array.release();
    }
  });
  @override
  Future<String?> getSerial() => _call(native.serial, _resultString);
  @override
  Future<bool> claimInterface(UsbInterface intf, {bool force = false}) => _call(
    (callback) => native.claim(_interface(intf), force, callback),
    _boolean,
  );
  @override
  Future<bool> releaseInterface(UsbInterface intf) => _call(
    (callback) => native.release$1(_interface(intf), callback),
    _boolean,
  );
  @override
  Future<bool> setInterface(UsbInterface intf) => _call(
    (callback) => native.selectInterface(_interface(intf), callback),
    _boolean,
  );
  @override
  Future<bool> setConfiguration(UsbConfiguration configuration) =>
      _call((callback) {
        if (configuration is! _AndroidConfiguration) {
          throw ArgumentError.value(
            configuration,
            'configuration',
            'Expected an Android USB configuration',
          );
        }
        native.selectConfiguration(configuration.native, callback);
      }, _boolean);
  @override
  Future<void> close() async {
    try {
      await _call(native.close, (_) {});
    } finally {
      _forgetRequests();
    }
  }

  /// Owns a separate Java array across the callback; workers never pin Dart data.
  Future<int> _transfer(
    Uint8List? buffer,
    int offset,
    int? length,
    bool input,
    void Function(JByteArray?, int, j.UsbHostProxy$Completion) start,
  ) async {
    final count = transferLength(buffer, offset, length);
    if (input) checkInputBuffer(buffer, offset, count);
    final bytes = buffer == null ? null : JByteArray(count);
    try {
      if (!input && count != 0) bytes!.setRange(0, count, buffer!, offset);
      final transferred = await _call(
        (completion) => start(bytes, count, completion),
        (value) => value!.as(JInteger.type).use((n) => n.intValue()),
      );
      if (input && transferred > 0) {
        receiveBytes(
          buffer,
          offset,
          bytes!.getRange(0, transferred),
          transferred,
        );
      }
      return transferred;
    } finally {
      bytes?.release();
    }
  }

  @override
  Future<int> bulkTransfer(
    UsbEndpoint endpoint,
    Uint8List? buffer, {
    int offset = 0,
    int? length,
    int timeout = 0,
  }) async {
    if (endpoint is! _AndroidEndpoint) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Expected an Android USB endpoint',
      );
    }
    jniInt(timeout, 'timeout');
    return _transfer(
      buffer,
      offset,
      length,
      endpoint.getDirection() == 0x80,
      (bytes, count, completion) =>
          native.bulk(endpoint.native, bytes, 0, count, timeout, completion),
    );
  }

  @override
  Future<int> controlTransfer(
    int requestType,
    int request,
    int value,
    int index,
    Uint8List? buffer, {
    int offset = 0,
    int? length,
    int timeout = 0,
  }) async {
    jniInt(requestType, 'requestType');
    jniInt(request, 'request');
    jniInt(value, 'value');
    jniInt(index, 'index');
    jniInt(timeout, 'timeout');
    return _transfer(
      buffer,
      offset,
      length,
      requestType & 0x80 != 0,
      (bytes, count, completion) => native.control(
        requestType,
        request,
        value,
        index,
        bytes,
        0,
        count,
        timeout,
        completion,
      ),
    );
  }

  @override
  Future<UsbRequest?> requestWait({int? timeout}) => _call(
    (completion) =>
        native.waitRequest(timeout != null, timeout ?? 0, completion),
    (value) {
      if (value == null) return null;
      return value.as(j.UsbHostProxy$RequestResult.type).use((result) {
        final id = result.request!.use((request) => request.id);
        final request = _requests[id];
        if (request == null) {
          throw StateError('USB request closed while waiting');
        }
        request._complete(result);
        return request.original;
      });
    },
  );

  // Windows-only extensions remain outside the Android implementation.
  @override
  Future<bool> resetPipe(UsbInterface intf, UsbEndpoint endpoint) async =>
      throw UnsupportedError('WinUSB is not available on Android');
  @override
  Future<bool> abortPipe(UsbInterface intf, UsbEndpoint endpoint) async =>
      throw UnsupportedError('WinUSB is not available on Android');
  @override
  Future<bool> flushPipe(UsbInterface intf, UsbEndpoint endpoint) async =>
      throw UnsupportedError('WinUSB is not available on Android');
  @override
  Future<bool> setPipePolicy(
    UsbInterface intf,
    UsbEndpoint endpoint,
    int policyType,
    Uint8List value,
  ) async => throw UnsupportedError('WinUSB is not available on Android');
  @override
  Future<Uint8List?> getPipePolicy(
    UsbInterface intf,
    UsbEndpoint endpoint,
    int policyType,
  ) async => throw UnsupportedError('WinUSB is not available on Android');
}

/// Owns only a request's JNI handles, buffer lease and opaque Dart client data.
/// Android queues the USB work; this adapter does not schedule or poll it.
final class _AndroidRequest implements UsbRequest {
  /// Keeps the caller's existing generative UsbRequest object as completion identity.
  _AndroidRequest(this.original);

  /// Returned by requestWait; never replaced by a newly constructed Dart wrapper.
  final UsbRequest original;

  /// Owns the lookup entry while this request is initialized.
  _AndroidConnection? _connection;

  /// Escaping JNI reference; cleared on request/connection close or session end.
  j.UsbHostProxy$Request? _native;

  /// Caller-owned IN destination retained until completion; OUT needs no Dart lease.
  Uint8List? _target;

  /// Offset in the caller's Uint8List view, not in its underlying allocation.
  int _offset = 0;

  /// Prevents reuse before Dart receives the native completion and copies IN bytes.
  bool _pending = false;

  /// Direction of the accepted submission, used only for completion copy-back.
  bool _input = false;

  /// Last delivered byte count; accepted queue and successful initialize reset it.
  int? _transferred;

  /// Opaque Dart context, intentionally separate from Java's internal clientData.
  Object? _clientData;

  @override
  int? get transferredLength => _transferred;
  @override
  Object? getClientData() => _clientData;
  @override
  void setClientData(Object? data) => _clientData = data;
  @override
  UsbEndpoint? getEndpoint() => _java(() {
    final endpoint = _native?.endpoint();
    return endpoint == null ? null : _AndroidEndpoint(endpoint);
  });

  @override
  Future<bool> initialize(
    UsbDeviceConnection connection,
    UsbEndpoint endpoint,
  ) async {
    if (_native != null) {
      throw StateError(
        'Close the initialized USB request before reinitializing',
      );
    }
    if (connection is! _AndroidConnection || endpoint is! _AndroidEndpoint) {
      throw ArgumentError('Expected an Android connection and endpoint');
    }
    final native = _java(
      () => connection.native.initializeRequest(endpoint.native),
    );
    if (native == null) return false;
    _native = native;
    _connection = connection;
    connection._requests[native.id] = this;
    _transferred = null;
    return true;
  }

  @override
  Future<bool> queue(Uint8List? buffer, {int offset = 0, int? length}) async {
    final native = _native;
    if (native == null) throw StateError('USB request is not initialized');
    if (_pending) throw StateError('USB request is still pending completion');
    final count = transferLength(buffer, offset, length);
    final endpoint = getEndpoint();
    if (endpoint == null) throw StateError('USB request is closed');
    final input = endpoint.getDirection() == 0x80;
    if (input) checkInputBuffer(buffer, offset, count);
    final bytes = buffer == null ? null : JByteBuffer.allocateDirect(count);
    try {
      if (!input && count != 0) {
        bytes!.asUint8List().setRange(0, count, buffer!, offset);
      }
      final accepted = _java(() => native.queue(bytes));
      if (accepted) {
        // The native request now retains the Java buffer; no Dart pointer escapes.
        _target = input ? buffer : null;
        _offset = offset;
        _input = input;
        _pending = true;
        _transferred = null;
      }
      return accepted;
    } finally {
      bytes?.release();
    }
  }

  /// Consumes the completion's borrowed Java buffer before releasing its JNI view.
  void _complete(j.UsbHostProxy$RequestResult result) {
    final count = result.length;
    try {
      final bytes = result.buffer;
      try {
        if (_input && count > 0) {
          receiveBytes(_target, _offset, bytes!.asUint8List(), count);
        }
      } finally {
        bytes?.release();
      }
      _transferred = count;
    } finally {
      _target = null;
      _pending = false;
    }
  }

  @override
  Future<bool> cancel() async =>
      _native == null ? false : _java(_native!.cancel);

  /// Drops ownership, not the caller's client data or last delivered byte count.
  /// Java handles native teardown; repeating this Dart cleanup is harmless.
  void _forget() {
    _native?.release();
    _native = null;
    _connection = null;
    _target = null;
    _pending = false;
  }

  @override
  Future<void> close() async {
    final native = _native;
    if (native == null) return;
    try {
      _java(native.close);
    } finally {
      _connection?._requests.remove(native.id);
      _forget();
    }
  }
}
