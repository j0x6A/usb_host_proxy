import 'dart:async';

// Named constructor arguments stay public; mutable cleanup callbacks stay private.
// ignore_for_file: prefer_initializing_formals

/// A resource whose native ownership ends with one observed device lifetime.
abstract interface class DeviceResource {
  /// Rejects further use and releases ownership, or starts asynchronous close.
  void invalidate();
}

/// Shares invalidation across device views and their descendant descriptors.
///
/// Descriptor references are released on invalidation; connection references
/// remain owned by their close attempt until it settles. Name/hash remain
/// readable without native access. Weak registrations let unused adapters be
/// collected normally while the device is connected.
final class DeviceLifetime {
  /// Original Android list key; retained for detach events and equality.
  final String name;

  /// Java name hash, so invalidation does not change a Map/Set key's hash.
  final int nativeHash;
  bool _active = true;
  bool Function()? _nativeIsAlive;
  void Function()? _releaseNative;

  /// Reports cleanup errors after all registered resources have been attempted.
  final void Function(Object, StackTrace) reportError;

  /// Does not keep every descriptor obtained by repeated enumeration alive.
  final _resources = <WeakReference<DeviceResource>>[];

  /// Takes the native validity probe and its reference-release callback.
  /// Both callbacks are cleared on invalidation to sever native ownership.
  DeviceLifetime({
    required this.name,
    required this.nativeHash,
    required bool Function() nativeIsAlive,
    required void Function() releaseNative,
    required this.reportError,
  }) : _nativeIsAlive = nativeIsAlive,
       _releaseNative = releaseNative;

  /// Local status only; [checkAlive] also consults Java before allowing access.
  bool get isActive => _active;

  /// Checks Java's authoritative flag before allowing another JNI operation.
  void checkAlive() {
    if (_active && !_nativeIsAlive!()) invalidate();
    if (!_active) throw StateError('USB device is detached: $name');
  }

  /// Validates submission, not later delivery of a result already produced by Java.
  /// Scalar results do not grant native access and remain valid after removal.
  Future<T> run<T>(Future<T> Function() operation) async {
    checkAlive();
    return operation();
  }

  /// An old removal must not be applied to a newer owner already exposed to Dart.
  /// This compares resource owners, not Android names or USB hardware identity.
  bool isSupersededBy(DeviceLifetime? current) =>
      current != null && !identical(this, current) && current.isActive;

  /// Late resources are invalidated immediately rather than reviving this owner.
  void register(DeviceResource resource) {
    if (!_active) {
      resource.invalidate();
      return;
    }
    _resources.removeWhere((reference) => reference.target == null);
    _resources.add(WeakReference(resource));
  }

  /// Rejects access first, then releases handles and starts connection cleanup.
  void invalidate() {
    if (!_active) return;
    _active = false;
    final release = _releaseNative;
    _releaseNative = null;
    _nativeIsAlive = null;
    final resources = List.of(_resources);
    _resources.clear();
    final failures = <(Object, StackTrace)>[];
    for (final reference in resources) {
      try {
        reference.target?.invalidate();
      } catch (error, stack) {
        failures.add((error, stack));
      }
    }
    try {
      release?.call();
    } catch (error, stack) {
      failures.add((error, stack));
    }
    for (final (error, stack) in failures) {
      reportError(error, stack);
    }
  }
}

/// Owns one JNI reference; the lifetime holds only a weak registration of it.
final class DeviceReference<T extends Object> implements DeviceResource {
  /// Shared with the parent device and all descriptor descendants.
  final DeviceLifetime lifetime;
  T? _value;
  void Function(T)? _release;

  DeviceReference(this.lifetime, T value, void Function(T) release)
    : _value = value,
      _release = release {
    lifetime.register(this);
  }

  /// Checks validity before exposing a reference that JNI could dereference.
  T get value {
    lifetime.checkAlive();
    return _value ?? (throw StateError('USB reference has been released'));
  }

  @override
  void invalidate() {
    // Clear ownership first: even a failing release must not be attempted twice.
    final value = _value;
    final release = _release;
    _value = null;
    _release = null;
    if (value != null) release!(value);
  }
}

/// Keeps a connection reference only until its native close attempt completes.
final class DeviceConnectionReference<T extends Object>
    implements DeviceResource {
  final DeviceLifetime lifetime;
  T? _value;
  Future<void> Function(T)? _closeNative;
  void Function(T)? _release;
  Future<void>? _closing;

  DeviceConnectionReference(
    this.lifetime,
    T value, {
    required Future<void> Function(T) closeNative,
    required void Function(T) release,
  }) : _value = value,
       _closeNative = closeNative,
       _release = release {
    lifetime.register(this);
  }

  T get value {
    lifetime.checkAlive();
    if (_closing != null || _value == null) {
      throw StateError('USB connection is closed');
    }
    return _value!;
  }

  /// Concurrent callers share one attempt. Once settled, later closes succeed
  /// without repeating native close or replaying its earlier failure.
  Future<void> close() {
    if (_closing != null) return _closing!;
    final value = _value;
    if (value == null) return Future.value();
    _closing = Future.sync(() => _closeNative!(value)).whenComplete(() {
      final release = _release;
      _value = null;
      _closeNative = null;
      _release = null;
      _closing = null;
      try {
        release!(value);
      } catch (error, stack) {
        lifetime.reportError(error, stack);
      }
    });
    return _closing!;
  }

  @override
  void invalidate() {
    // Cleanup is independent of the caller awaiting close or subscribing to USB events.
    unawaited(close().catchError(lifetime.reportError));
  }
}
