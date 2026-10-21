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

// JNI references, not cached USB descriptor fields, are owned by these adapters.
// Temporary references are released eagerly. Escaping references use JNI's native
// finalizer because the public descriptor API has no dispose/release operation.
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

String? _string(JString? value) => value?.toDartString(releaseOriginal: true);

Future<T> _call<T>(
  void Function(j.UsbHostBridge$Completion) start,
  T Function(JObject?) decode,
) {
  final result = Completer<T>();
  final callback = j.UsbHostBridge$Completion.implement(
    j.$UsbHostBridge$Completion(
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
          _java(() => j.UsbHostBridge.rethrowError(error));
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

bool _boolean(JObject? value) =>
    value!.as(JBoolean.type).use((v) => v.booleanValue());
String? _resultString(JObject? value) =>
    value?.as(JString.type).use((v) => v.toDartString());

/// Internal Android backend, shared by managers in the engine's root isolate.
final class AndroidUsb {
  static final AndroidUsb instance = AndroidUsb._();

  j.UsbHostBridge$Session? _reference;
  final _attached = StreamController<UsbDevice>.broadcast();
  final _detached = StreamController<UsbDevice>.broadcast();

  AndroidUsb._() {
    if (RootIsolateToken.instance == null) {
      throw StateError('USB objects must be used in the engine root isolate');
    }
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) throw StateError('No Flutter engine is attached');
    _reference = _java(() => j.UsbHostBridge.session(engineId))!;
    final listener = j.UsbHostBridge$Events.implement(
      j.$UsbHostBridge$Events(
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

  j.UsbHostBridge$Session get _session =>
      _reference ?? (throw StateError('USB session has ended'));

  void _event(
    StreamController<UsbDevice> stream,
    j.UsbHostBridge$Device? device,
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

  Stream<UsbDevice> get deviceAttached => _attached.stream;
  Stream<UsbDevice> get deviceDetached => _detached.stream;

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

  bool hasPermission(UsbDevice device) =>
      _java(() => _session.hasPermission(_device(device).handle));

  Future<bool> requestPermission(UsbDevice device) => _call(
    (callback) => _session.requestPermission(_device(device).handle, callback),
    _boolean,
  );

  Future<UsbDeviceConnection?> openDevice(UsbDevice device) => _call(
    (callback) => _session.open(_device(device).handle, callback),
    (value) => value == null
        ? null
        : _AndroidConnection(value.as(j.UsbHostBridge$Connection.type)),
  );

  static int deviceId(String name) => _java(() {
    final string = name.toJString();
    try {
      return j.UsbDevice.getDeviceId(string);
    } finally {
      string.release();
    }
  });

  static String? deviceName(int id) =>
      _java(() => _string(j.UsbDevice.getDeviceName(id)));
}

final class _AndroidDevice implements UsbDevice {
  final j.UsbHostBridge$Device handle;
  final j.UsbDevice native;

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

final class _AndroidConfiguration implements UsbConfiguration {
  final j.UsbConfiguration native;
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
  final j.UsbInterface native;
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
  final j.UsbEndpoint native;
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

final class _AndroidConnection implements UsbDeviceConnection {
  final j.UsbHostBridge$Connection native;
  _AndroidConnection(this.native);

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
