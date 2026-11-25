import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:jni/jni.dart';

import '../usb_backend.dart';
import '../usb_configuration.dart';
import '../usb_device.dart';
import '../usb_device_connection.dart';
import '../usb_endpoint.dart';
import '../usb_interface.dart';
import '../usb_request.dart';
import 'bindings.g.dart' as j;

// Java owns USB resources and validity. Dart owns only JNI references to Java
// views: temporaries are released eagerly, escaping views use native finalizers.
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

/// Engine-root proxy. Java owns discovery, event admission and all USB lifecycle.
final class AndroidUsb implements UsbBackend {
  static final AndroidUsb instance = AndroidUsb._();

  /// Initialised once by management/events; conversions never read this field.
  /// Disposal sets it to null without permitting a new binding in the old isolate.
  late j.UsbHostProxy$Session? _reference = _bind();
  final _attached = StreamController<UsbDevice>.broadcast();
  final _detached = StreamController<UsbDevice>.broadcast();

  AndroidUsb._();

  j.UsbHostProxy$Session _bind() {
    if (RootIsolateToken.instance == null) {
      throw StateError('USB objects must be used in the engine root isolate');
    }
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) throw StateError('No Flutter engine is attached');
    final reference = _java(() => j.UsbHostProxy.session(engineId))!;
    final listener = j.UsbHostProxy$Events.implement(
      j.$UsbHostProxy$Events(
        attached$async: true,
        detached$async: true,
        disposed$async: true,
        attached: (device) => _event(_attached, device, false),
        detached: (device) => _event(_detached, device, true),
        disposed: () {
          _reference?.release();
          _reference = null;
          unawaited(_attached.close());
          unawaited(_detached.close());
        },
      ),
    );
    try {
      _java(() => reference.listen(listener));
      return reference;
    } catch (_) {
      reference.release();
      rethrow;
    } finally {
      listener.release();
    }
  }

  j.UsbHostProxy$Session get _session =>
      _reference ?? (throw StateError('USB session has ended'));

  /// Java resolves delayed delivery. Dart only manages the callback references
  /// and forwards the accepted payload to its public stream subscribers.
  void _event(
    StreamController<UsbDevice> stream,
    j.UsbHostProxy$Device? device,
    bool detached,
  ) {
    if (device == null) return;
    try {
      if (!stream.hasListener || stream.isClosed || _reference == null) return;
      final accepted = _java(() => _session.eventDevice(device, detached));
      if (accepted != null) stream.add(_AndroidDevice(accepted));
    } catch (error, stack) {
      if (!stream.isClosed && stream.hasListener) stream.addError(error, stack);
    } finally {
      device.release();
    }
  }

  @override
  Stream<UsbDevice> get deviceAttached {
    // Bind on first event access; an ended stream stays closed.
    final _ = _reference;
    return _attached.stream;
  }

  @override
  Stream<UsbDevice> get deviceDetached {
    final _ = _reference;
    return _detached.stream;
  }

  /// Keeps the returned Java views, releasing only the temporary JNI array.
  @override
  Future<Map<String, UsbDevice>> getDeviceList() async => _java(() {
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

  @override
  Future<bool> hasPermission(UsbDevice device) async =>
      _java(() => _session.hasPermission(_device(device).native));

  @override
  Future<bool> requestPermission(UsbDevice device) async {
    final session = _session;
    return _call(
      (callback) => session.requestPermission(_device(device).native, callback),
      _boolean,
    );
  }

  @override
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) async {
    final session = _session;
    return _call((callback) => session.open(_device(device).native, callback), (
      value,
    ) {
      if (value == null) return null;
      final native = value.as(j.UsbHostProxy$Connection.type);
      try {
        _java(native.checkResult);
        return _AndroidConnection(native);
      } catch (_) {
        native.release();
        rethrow;
      }
    });
  }

  @override
  Future<int> deviceId(String name) async => _java(() {
    final string = name.toJString();
    try {
      return j.UsbDevice.getDeviceId(string);
    } finally {
      string.release();
    }
  });

  @override
  Future<String?> deviceName(int id) async =>
      _java(() => _string(j.UsbDevice.getDeviceName(id)));
}

/// Retains a Java view, which stays inert after Java clears its USB descriptor.
final class _AndroidDevice implements UsbDevice {
  final j.UsbHostProxy$Device native;
  _AndroidDevice(this.native);

  @override
  bool operator ==(Object other) =>
      other is _AndroidDevice && _java(() => native.equals(other.native));
  @override
  int get hashCode => _java(native.hashCode$1);
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
  Future<String?> getSerialNumber() => _call(native.serial, _resultString);
  @override
  int getVendorId() => _java(() => native.vendorId);
  @override
  String getVersion() => _java(() => _string(native.version)!);
}

/// Descriptor reads and validity checks are both performed by the Java view.
final class _AndroidConfiguration implements UsbConfiguration {
  final j.UsbHostProxy$Configuration native;
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

final class _AndroidInterface implements UsbInterface {
  final j.UsbHostProxy$Interface native;
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

final class _AndroidEndpoint implements UsbEndpoint {
  final j.UsbHostProxy$Endpoint native;
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

/// Only explicit API calls reach close. Java owns detach/session cleanup and
/// rejects closed connections; the retained JNI view is finalized independently.
final class _AndroidConnection implements UsbDeviceConnection {
  final j.UsbHostProxy$Connection native;
  _AndroidConnection(this.native);

  j.UsbHostProxy$Interface _interface(UsbInterface intf) {
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

  /// The copied bytes belong to Dart; Java owns the native connection and array.
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
    (callback) => native.claimInterface(_interface(intf), force, callback),
    _boolean,
  );
  @override
  Future<bool> releaseInterface(UsbInterface intf) => _call(
    (callback) => native.releaseInterface(_interface(intf), callback),
    _boolean,
  );
  @override
  Future<bool> setInterface(UsbInterface intf) => _call(
    (callback) => native.setInterface(_interface(intf), callback),
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
        native.setConfiguration(configuration.native, callback);
      }, _boolean);
  @override
  Future<void> close() => _call(native.close, (_) {});

  // These existing API members are deliberately outside this implementation.
  @override
  Future<int> bulkTransfer(
    UsbEndpoint endpoint,
    Uint8List? buffer, {
    int offset = 0,
    int? length,
    int timeout = 0,
  }) async => throw UnsupportedError('USB data transport is not implemented');
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
  }) async => throw UnsupportedError('USB data transport is not implemented');
  @override
  Future<UsbRequest?> requestWait({int? timeout}) async =>
      throw UnsupportedError('USB request transport is not implemented');
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
