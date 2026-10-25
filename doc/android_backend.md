# Android backend: a maintainer's guide

Start with the [public usage guide](../README.md). This document explains how an
operation crosses the Dart/Java boundary and who cleans up its resources.
The backend implements management/information calls; transport remains outside
its implemented scope.

## Source map

| File | Responsibility |
| --- | --- |
| `lib/usb_host_proxy.dart`, `lib/src/usb_*.dart` | Exported classes, contracts, descriptor meanings, constants and placeholders. |
| `lib/src/android/android_usb.dart` | JNI references, Java-to-Dart errors, completion-to-Future conversion and event streams. |
| `lib/src/android/bindings.g.dart` | Generated Java bindings; do not edit by hand. |
| `android/src/main/java/dev/jx6A78/usb_host_proxy/UsbHostProxy.java` | Sessions, discovery, permissions, workers and native connection lifetime. |
| `android/src/main/java/dev/jx6A78/usb_host_proxy/UsbHostProxyPlugin.java` | Flutter Engine/Activity callbacks and intent-listener registration. |
| `tool/jnigen.dart` | Regenerates committed private bindings. |
| `android/src/test/java` | Robolectric backend/plugin tests with mocked USB objects. |
| `example/lib/main.dart`, `example/test` | Diagnostic screen and fake-backed widget/placeholder tests. |

For a descriptor read, follow `UsbDevice.getProductName()` to `_AndroidDevice`
and the generated getter. It reads the original Android object directly, without
a worker or an open connection.

For management, follow `claimInterface()` through `_AndroidConnection`, `_call`,
Java `Connection.claim()` and `Connection.submit()`. A worker calls Android;
`Completion` delivers the result/error and `_call` completes the Dart Future.
`openDevice()` has a separate path because a late result may need cleanup before
it can be given to Dart.

## Objects and owners

| Object | What it retains | How its lifetime ends |
| --- | --- | --- |
| `Session` | Application context, receivers, workers, pending work and connections for one engine. | Engine restart/shutdown ends it permanently. |
| `Device` | A native descriptor and owning session. Its notification flag deduplicates events only. | Detach does not blacklist the view. Operations require an active owning session, then follow Android's result. |
| `Connection` | One native connection; its name matches detach cleanup. | Close/detach/session end permanently blocks new native access. |
| `Permission` | A PendingIntent and callers awaiting the same device-name decision. | Reply, detach or session end settles callers and cancels the PendingIntent. |
| `Call` | A callback that a worker or cleanup may finish, at most once. | The callback is cleared before delivery, so late workers cannot deliver again. |

There is no private device identifier. The `devices` map keeps the latest
observed framework view and notification flag by name. `remember()` reuses a
wrapper if it holds the same Java reference; this saves an allocation and never
decides validity. New framework views inherit the name's notification flag
without mutating old views.

Resources can exist before rediscovery. Enumeration therefore checks names from
connections, permissions and pending opens as well as the event registry. Session
disposal closes every owned connection, independently of that registry.

## Permission replies and open attempts

Permission requests for the same name share one decision. Request codes identify
pending decisions. A unique permission-action UUID separates callback routes
between sessions; it is not a USB identity. A reply must match the route/request,
carry the expected name and report access that Android still confirms.

`Call.openingName` is set for a pending open. Detach clears it under the session
monitor, cancelling that attempt rather than future uses of the saved descriptor.
A worker not yet in Android fails before opening. A worker already in Android
closes any returned connection instead of publishing it. A cleanup failure is
reported to the waiting caller and logged, not converted to null.

Session shutdown settles callbacks immediately. An already-running open remains
responsible for closing its late result, even after its caller receives an error.
There is no extra polling, timeout or retry.

## Concurrency and close

The session has one cached worker pool and no per-connection queues or FIFO
promise. Open, serial reads, permission submission, interface/configuration calls
and close use it. No worker waits for a permission dialog. Enumeration, permission
checks, descriptor getters and FD/raw reads call JNI on the caller's thread.

Three synchronization boundaries have separate jobs:

1. The `UsbHostProxy` class monitor protects the engine-to-session registry.
2. The session monitor protects lifecycle state, resource sets, pending callbacks
   and event bookkeeping. Native management calls run outside it.
3. A connection's `nativeLifetime` read/write lock prevents native close from
   freeing an object still in use. Ordinary calls take shared read access and may
   run concurrently; close alone needs exclusive write access.

An operation is **admitted** when it passes its final lifecycle check while
holding shared native access. Pending work can be rejected; admitted work must
return before native close proceeds.

Close sets the volatile `closing` flag under the session monitor before dispatch.
The close worker waits for exclusive access without holding that monitor, calls
native close once and clears the reference even if close throws. It releases
native access before taking the session monitor for bookkeeping and callbacks.

Management workers briefly take the session monitor while holding shared native
access for validation. They release native access before delivering callbacks.
Code holding the session monitor must not wait for the lifetime lock: reversing
this order could deadlock.

Close does not release interfaces individually, interrupt native calls or wait
for their Dart callbacks. A native call that does not return can prevent close
from finishing. Concurrent close callers share the pending result; after that
attempt finishes, later close calls succeed without replaying its error.

This protection covers implemented management/information calls only. It does
not establish a safe close/cancel policy for future transfers or UsbRequest.
The earlier transport-lifetime investigation must be revisited before restoring
transport.

## JNI references and errors

Adapters retain original Java descriptors. Temporary strings, arrays and callback
arguments are released after decoding. Returned adapters use native finalizers
for retained references because descriptors have no public dispose method.
Native connection close is separate from releasing its Java wrapper reference.

`_call` supplies a nonblocking asynchronous JNIgen listener. Java retains the
proxy while work is pending, so Dart releases its temporary proxy reference after
submission. A result kept beyond a callback must retain its own reference before
the incoming callback argument is released.

`_java` replaces Java argument/state exceptions with Dart `ArgumentError` and
`StateError`, releasing the replaced throwable. Other Java failures retain their
details. `Call.finish()` settles a callback once, whether the worker or session
cleanup wins the race; exceptions never become fabricated false results.

## Engine and Activity lifecycle

The root Dart isolate binds through Flutter's `engineId` and installs one event
listener. Managers share that binding; additional Dart isolates are unsupported.
Headless engines retain discovery and broadcast handling without an Activity.

| Callback/delivery | Effect |
| --- | --- |
| Engine attach | Register a session using application context; the session does not retain an Activity. |
| Initial Activity intent/recreation | Check live presence and consume attach silently; enumerate for initial state. |
| `onNewIntent()` or USB attach broadcast | Share name-based notification state; notify once until removal. |
| USB detach | Close/cancel resources by name, then notify if the name was known. Do not ignore detach merely because the name is present again. |
| Activity detach/configuration change | Remove the exact old listener; preserve session resources. |
| Engine restart | End the old session, register a new one and treat the stored Activity intent as initial state; retain Activity registration. |
| Engine/plugin shutdown | Remove listeners, unregister receivers, fail pending calls and schedule close before worker shutdown. |

`handleActivityIntent()` returning true means a readable USB attach payload was
recognized, not that a device was found or an event emitted. Unrelated actions
and unreadable/missing payloads are not handled. A saved intent cannot restore a
device absent from Android's list.

## Configuration and binding generation

The library sets `minSdk = 28`, `compileSdk = 36` and Java 17 source/bytecode
compatibility. The example also sets minimum API 28; compile/target SDK values
come from Flutter. Consuming applications choose their own target SDK.

Android sources are Java; Gradle files remain Kotlin DSL. The example resolves
KGP tooling 2.4.0 with `apply false` for Flutter's version validation. Its
`android.newDsl=false` and `android.builtInKotlin=false` settings preserve current
toolchain compatibility. Their deprecation warnings require a future toolchain
migration, not a change of source language.

Bindings are committed. Regenerate after changing the Java surface or exported
comments, using Android SDK platform 36:

```sh
dart run tool/jnigen.dart /path/to/Android/Sdk
```

The SDK directory can instead come from `ANDROID_SDK_ROOT`.
`JNIGEN_SUMMARIZER` optionally selects a prebuilt ApiSummarizer command. `jni` is
the runtime dependency; `jnigen` is a development tool. Constructors and Parcelable
members are deliberately excluded by the generator configuration.

Test commands and limits: [main README](../README.md#tests-and-verification-limits).
