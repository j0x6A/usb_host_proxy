import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart'
    show ErrorDescription, FlutterError, FlutterErrorDetails;
import 'package:jni/jni.dart';

import '../usb_configuration.dart';
import '../usb_device.dart';
import '../usb_device_connection.dart';
import '../usb_endpoint.dart';
import '../usb_interface.dart';
import '../usb_request.dart';
import 'bindings.g.dart' as j;
import 'device_lifetime.dart';

// JNI references, not cached USB descriptor fields, are owned by these adapters.
// Temporary references are released eagerly. Device invalidation explicitly
// releases retained references; native finalizers also cover unused adapters.
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

/// Does not publish successful results belonging to a device that has since ended.
Future<T> _deviceCall<T>(
  DeviceLifetime lifetime,
  void Function(j.UsbHostProxy$Completion) start,
  T Function(JObject? value) decode,
) async {
  lifetime.checkAlive();
  return _call(start, (value) {
    lifetime.checkAlive();
    return decode(value);
  });
}

/// Reports automatic cleanup failures through Flutter's existing error handler.
void _cleanupError(Object error, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'usb_host_proxy',
      context: ErrorDescription('while releasing an invalidated USB resource'),
    ),
  );
}

/// One Java validity flag shared by all snapshots and descendants of a device.
/// Its object identity correlates cleanup only; public equality still uses names.
final class _DeviceContext {
  j.UsbHostProxy$Lifetime? _tag;
  late final DeviceLifetime lifetime;

  _DeviceContext(j.UsbHostProxy$Lifetime tag, String name, int hash)
    : _tag = tag {
    lifetime = DeviceLifetime(
      name: name,
      nativeHash: hash,
      nativeIsAlive: () => _java(() => _tag!.isAlive),
      releaseNative: () {
        final reference = _tag;
        _tag = null;
        reference?.release();
      },
      reportError: _cleanupError,
    );
  }
}

/// Internal Android backend, shared by managers in the engine's root isolate.
final class AndroidUsb {
  /// Lazily binds the root isolate to the session already registered by Java.
  static final AndroidUsb instance = AndroidUsb._();

  /// Session JNI reference, released and cleared by the disposed callback.
  j.UsbHostProxy$Session? _reference;

  /// Active resource owners; ended owners are never reused for a new presence.
  final _devices = <String, _DeviceContext>{};

  /// Live attachment notifications, dropped when no Dart listener is present.
  final _attached = StreamController<UsbDevice>.broadcast();

  /// Removal notifications carrying only the device's immutable name/hash.
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
        detached: (device) => _event(_detached, device, detached: true),
        disposed: () {
          for (final context in _devices.values.toList()) {
            context.lifetime.invalidate();
          }
          _devices.clear();
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

  /// Finds the resource owner without confusing a late old event with a new name reuse.
  DeviceLifetime _lifetime(j.UsbHostProxy$Device device) {
    final tag = _java(() => device.lifetime)!;
    late final String name;
    late final int hash;
    late final bool alive;
    _DeviceContext? previous;
    var same = false;
    try {
      name = _java(() => _string(tag.name)!);
      hash = _java(() => tag.deviceHash);
      alive = _java(() => tag.isAlive);
      previous = _devices[name];
      final previousTag = previous?._tag;
      // Lifetime inherits Object.equals: JNI equality here is Java object identity.
      same = previousTag != null && _java(() => previousTag == tag);
    } catch (_) {
      tag.release();
      rethrow;
    }
    if (same) {
      tag.release();
      if (!alive) {
        _devices.remove(name);
        previous!.lifetime.invalidate();
      }
      return previous!.lifetime;
    }
    final context = _DeviceContext(tag, name, hash);
    if (alive && _reference != null) {
      _devices.remove(name)?.lifetime.invalidate();
      _devices[name] = context;
    } else {
      context.lifetime.invalidate();
    }
    return context.lifetime;
  }

  /// Cleanup runs even without public stream subscribers. A detach payload owns no JNI.
  void _event(
    StreamController<UsbDevice> stream,
    j.UsbHostProxy$Device? device, {
    bool detached = false,
  }) {
    if (device == null) return;
    var transferred = false;
    try {
      final lifetime = _lifetime(device);
      if (detached) lifetime.invalidate();
      if (!stream.hasListener || stream.isClosed || _reference == null) return;
      if (detached) {
        stream.add(_AndroidDevice.detached(lifetime));
      } else if (lifetime.isActive) {
        // The factory consumes the handle, including on failure.
        transferred = true;
        stream.add(_AndroidDevice.live(device, lifetime));
      }
    } catch (error, stack) {
      if (!stream.isClosed && stream.hasListener) stream.addError(error, stack);
    } finally {
      if (!transferred) device.release();
    }
  }

  /// Broadcast attach stream; previously observed devices are not replayed.
  Stream<UsbDevice> get deviceAttached => _attached.stream;

  /// Broadcast detach stream after name-based connection/permission cleanup.
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
        var transferred = false;
        try {
          final lifetime = _lifetime(handle);
          if (!lifetime.isActive) continue;
          transferred = true;
          final device = _AndroidDevice.live(handle, lifetime);
          result[device.getDeviceName()] = device;
        } finally {
          if (!transferred) handle.release();
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

  /// Awaits the coalesced native decision for this Android name, without a timeout.
  Future<bool> requestPermission(UsbDevice device) async {
    final selected = _device(device);
    selected.lifetime.checkAlive();
    // An already-pending permission request still resolves false on detach.
    return _call(
      (callback) => _session.requestPermission(selected.handle, callback),
      (value) {
        final granted = _boolean(value);
        if (granted) selected.lifetime.checkAlive();
        return granted;
      },
    );
  }

  /// Wraps a published native connection, preserving null and Android failures.
  Future<UsbDeviceConnection?> openDevice(UsbDevice device) async {
    final selected = _device(device);
    return _deviceCall(
      selected.lifetime,
      (callback) => _session.open(selected.handle, callback),
      (value) => value == null
          ? null
          : _AndroidConnection(
              value.as(j.UsbHostProxy$Connection.type),
              selected.lifetime,
            ),
    );
  }

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

/// Live descriptors use JNI; name/hash alone remain usable after invalidation.
final class _AndroidDevice implements UsbDevice {
  final DeviceLifetime lifetime;
  final DeviceReference<j.UsbHostProxy$Device>? _handle;
  final DeviceReference<j.UsbDevice>? _native;

  j.UsbHostProxy$Device get handle {
    lifetime.checkAlive();
    return _handle!.value;
  }

  j.UsbDevice get native {
    lifetime.checkAlive();
    return _native!.value;
  }

  _AndroidDevice._(this.lifetime, this._handle, this._native);

  /// Takes ownership even on failure, so callers never release a handle twice.
  factory _AndroidDevice.live(
    j.UsbHostProxy$Device handle,
    DeviceLifetime lifetime,
  ) {
    late final j.UsbDevice descriptor;
    try {
      lifetime.checkAlive();
      descriptor = _java(handle.descriptor)!;
    } catch (_) {
      handle.release();
      rethrow;
    }
    return _AndroidDevice._(
      lifetime,
      DeviceReference(lifetime, handle, (value) => value.release()),
      DeviceReference(lifetime, descriptor, (value) => value.release()),
    );
  }

  _AndroidDevice.detached(this.lifetime) : _handle = null, _native = null;

  /// Uses Android's name-based equality, independently of wrapper identity.
  @override
  bool operator ==(Object other) =>
      other is _AndroidDevice && lifetime.name == other.lifetime.name;

  /// Preserves the native hash rather than Dart object/reference identity.
  @override
  int get hashCode => lifetime.nativeHash;

  @override
  UsbConfiguration getConfiguration(int index) => _java(
    () => _AndroidConfiguration(native.getConfiguration(index)!, lifetime),
  );
  @override
  int getConfigurationCount() => _java(() => native.configurationCount);
  @override
  int getDeviceClass() => _java(() => native.deviceClass);
  @override
  int getDeviceId() => _java(() => native.deviceId);
  @override
  String getDeviceName() => lifetime.name;
  @override
  int getDeviceProtocol() => _java(() => native.deviceProtocol);
  @override
  int getDeviceSubclass() => _java(() => native.deviceSubclass);
  @override
  UsbInterface getInterface(int index) =>
      _java(() => _AndroidInterface(native.getInterface(index)!, lifetime));
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
  Future<String?> getSerialNumber() => _deviceCall(
    lifetime,
    (callback) => handle.serial(callback),
    _resultString,
  );
  @override
  int getVendorId() => _java(() => native.vendorId);
  @override
  String getVersion() => _java(() => _string(native.version)!);
}

/// Thin descriptor view; method contracts are inherited from [UsbConfiguration].
final class _AndroidConfiguration implements UsbConfiguration {
  final DeviceLifetime lifetime;
  final DeviceReference<j.UsbConfiguration> _reference;
  j.UsbConfiguration get native => _reference.value;

  _AndroidConfiguration(j.UsbConfiguration native, this.lifetime)
    : _reference = DeviceReference(
        lifetime,
        native,
        (value) => value.release(),
      );
  @override
  int getId() => _java(() => native.id);
  @override
  UsbInterface getInterface(int index) =>
      _java(() => _AndroidInterface(native.getInterface(index)!, lifetime));
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
  final DeviceLifetime lifetime;
  final DeviceReference<j.UsbInterface> _reference;
  j.UsbInterface get native => _reference.value;

  _AndroidInterface(j.UsbInterface native, this.lifetime)
    : _reference = DeviceReference(
        lifetime,
        native,
        (value) => value.release(),
      );
  @override
  int getAlternateSetting() => _java(() => native.alternateSetting);
  @override
  UsbEndpoint getEndpoint(int index) =>
      _java(() => _AndroidEndpoint(native.getEndpoint(index)!, lifetime));
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
  final DeviceReference<j.UsbEndpoint> _reference;
  j.UsbEndpoint get native => _reference.value;

  _AndroidEndpoint(j.UsbEndpoint native, DeviceLifetime lifetime)
    : _reference = DeviceReference(
        lifetime,
        native,
        (value) => value.release(),
      );
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

/// Adapts connection calls and results; Java owns worker dispatch and native close.
///
/// Supported method contracts are documented by [UsbDeviceConnection]. Releasing
/// a JNI reference is not a substitute for explicitly awaiting [close].
final class _AndroidConnection implements UsbDeviceConnection {
  final DeviceLifetime lifetime;
  final DeviceConnectionReference<j.UsbHostProxy$Connection> _reference;
  j.UsbHostProxy$Connection get native => _reference.value;

  /// Invalidation starts close; its completion releases the retained JNI handle.
  _AndroidConnection(j.UsbHostProxy$Connection native, this.lifetime)
    : _reference = DeviceConnectionReference(
        lifetime,
        native,
        closeNative: (value) => _call(value.close, (_) {}),
        release: (value) => value.release(),
      );

  /// Requires an Android descriptor adapter, then forwards its native reference.
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
  Future<String?> getSerial() => _deviceCall(
    lifetime,
    (callback) => native.serial(callback),
    _resultString,
  );
  @override
  Future<bool> claimInterface(UsbInterface intf, {bool force = false}) =>
      _deviceCall(
        lifetime,
        (callback) => native.claim(_interface(intf), force, callback),
        _boolean,
      );
  @override
  Future<bool> releaseInterface(UsbInterface intf) => _deviceCall(
    lifetime,
    (callback) => native.release$1(_interface(intf), callback),
    _boolean,
  );
  @override
  Future<bool> setInterface(UsbInterface intf) => _deviceCall(
    lifetime,
    (callback) => native.selectInterface(_interface(intf), callback),
    _boolean,
  );
  @override
  Future<bool> setConfiguration(UsbConfiguration configuration) =>
      _deviceCall(lifetime, (callback) {
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
  Future<void> close() => _reference.close();

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
