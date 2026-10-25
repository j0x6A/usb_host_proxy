import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:usb_host_proxy/src/android/device_lifetime.dart';

/// Exercises ownership without a JVM, USB hardware or generated JNI objects.
void main() {
  late bool present;
  late int releasedTag;
  late List<Object> errors;
  late DeviceLifetime lifetime;

  setUp(() {
    present = true;
    releasedTag = 0;
    errors = [];
    lifetime = DeviceLifetime(
      name: '/dev/bus/usb/001/002',
      nativeHash: 123,
      nativeIsAlive: () => present,
      releaseNative: () => releasedTag++,
      reportError: (error, stack) => errors.add(error),
    );
  });

  test(
    'invalidation releases every live descriptor reference exactly once',
    () {
      final released = <String>[];
      final references = [
        for (final name in ['device', 'configuration', 'interface', 'endpoint'])
          DeviceReference(lifetime, name, released.add),
      ];
      expect(references.last.value, 'endpoint');
      lifetime.invalidate();
      lifetime.invalidate();
      expect(released, ['device', 'configuration', 'interface', 'endpoint']);
      expect(releasedTag, 1);
      for (final reference in references) {
        expect(() => reference.value, throwsStateError);
      }
      expect(lifetime.name, '/dev/bus/usb/001/002');
      expect(lifetime.nativeHash, 123);
      expect(errors, isEmpty);
    },
  );

  test(
    'native invalidation is observed before a Dart detach event arrives',
    () {
      var releases = 0;
      final reference = DeviceReference(lifetime, Object(), (_) => releases++);
      present = false;
      expect(() => reference.value, throwsStateError);
      expect(releases, 1);
      expect(releasedTag, 1);
      present = true;
      expect(() => reference.value, throwsStateError);
      expect(releases, 1);
    },
  );

  test(
    'late references are released without making an ended device usable',
    () {
      lifetime.invalidate();
      var releases = 0;
      final reference = DeviceReference(lifetime, Object(), (_) => releases++);
      expect(releases, 1);
      expect(() => reference.value, throwsStateError);
      expect(releasedTag, 1);
    },
  );

  test(
    'cleanup failure does not prevent releasing the remaining resources',
    () {
      final failure = StateError('release failed');
      final first = DeviceReference(lifetime, Object(), (_) => throw failure);
      var released = false;
      final second = DeviceReference(
        lifetime,
        Object(),
        (_) => released = true,
      );
      lifetime.invalidate();
      expect(released, isTrue);
      expect(releasedTag, 1);
      expect(errors, [failure]);
      expect(() => first.value, throwsStateError);
      expect(() => second.value, throwsStateError);
    },
  );

  test(
    'a new presence with the same name/hash never revives old references',
    () {
      final old = DeviceReference(lifetime, 'old', (_) {});
      lifetime.invalidate();
      final replacement = DeviceLifetime(
        name: lifetime.name,
        nativeHash: lifetime.nativeHash,
        nativeIsAlive: () => true,
        releaseNative: () {},
        reportError: (error, stack) => errors.add(error),
      );
      final current = DeviceReference(replacement, 'new', (_) {});
      lifetime.invalidate(); // A late duplicate removal belongs only to the old owner.
      expect(() => old.value, throwsStateError);
      expect(current.value, 'new');
      replacement.invalidate();
    },
  );

  test('invalidating one device leaves another device usable', () {
    final other = DeviceLifetime(
      name: '/dev/bus/usb/001/003',
      nativeHash: 456,
      nativeIsAlive: () => true,
      releaseNative: () {},
      reportError: (error, stack) => errors.add(error),
    );
    var released = 0;
    final reference = DeviceReference(other, 'other device', (_) => released++);
    lifetime.invalidate();
    expect(reference.value, 'other device');
    expect(released, 0);
    other.invalidate();
    expect(released, 1);
  });

  test(
    'a late connection is closed when its device has already ended',
    () async {
      lifetime.invalidate();
      final closed = Completer<void>();
      var closes = 0;
      var releases = 0;
      final connection = DeviceConnectionReference(
        lifetime,
        Object(),
        closeNative: (_) {
          closes++;
          return closed.future;
        },
        release: (_) => releases++,
      );
      expect(closes, 1);
      expect(releases, 0);
      expect(() => connection.value, throwsStateError);
      closed.complete();
      await connection.close();
      expect(releases, 1);
    },
  );

  test(
    'close blocks access immediately and releases after native completion',
    () async {
      final nativeClose = Completer<void>();
      var closes = 0;
      var releases = 0;
      final connection = DeviceConnectionReference(
        lifetime,
        Object(),
        closeNative: (_) {
          closes++;
          return nativeClose.future;
        },
        release: (_) => releases++,
      );
      final closing = connection.close();
      expect(identical(closing, connection.close()), isTrue);
      expect(() => connection.value, throwsStateError);
      expect(closes, 1);
      expect(releases, 0);
      nativeClose.complete();
      await closing;
      expect(releases, 1);
      await connection.close();
      lifetime.invalidate();
      expect(closes, 1);
      expect(releases, 1);
    },
  );

  test(
    'invalidation starts close without any external event listener',
    () async {
      final nativeClose = Completer<void>();
      var closes = 0;
      var releases = 0;
      final connection = DeviceConnectionReference(
        lifetime,
        Object(),
        closeNative: (_) {
          closes++;
          return nativeClose.future;
        },
        release: (_) => releases++,
      );
      lifetime.invalidate();
      expect(closes, 1);
      expect(releases, 0);
      expect(() => connection.value, throwsStateError);
      nativeClose.complete();
      await connection.close();
      expect(releases, 1);
      expect(errors, isEmpty);
    },
  );

  test(
    'failed close releases its reference and is not retried automatically',
    () async {
      final failure = StateError('native close failed');
      var closes = 0;
      var releases = 0;
      final connection = DeviceConnectionReference(
        lifetime,
        Object(),
        closeNative: (_) {
          closes++;
          return Future.error(failure);
        },
        release: (_) => releases++,
      );
      await expectLater(connection.close(), throwsA(same(failure)));
      expect(releases, 1);
      await connection.close();
      expect(closes, 1);
      expect(() => connection.value, throwsStateError);
    },
  );

  test('automatic close errors are reported and other references still release', () async {
    final failure = StateError('automatic close failed');
    final connection = DeviceConnectionReference(
      lifetime,
      Object(),
      closeNative: (_) => Future.error(failure),
      release: (_) {},
    );
    var released = false;
    final descriptor = DeviceReference(
      lifetime,
      Object(),
      (_) => released = true,
    );
    lifetime.invalidate();
    // The explicit waiter sees the same failure; invalidation also reports it.
    await expectLater(connection.close(), throwsA(same(failure)));
    expect(errors, [failure]);
    expect(released, isTrue);
    expect(() => descriptor.value, throwsStateError);
  });
}
