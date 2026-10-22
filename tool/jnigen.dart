import 'dart:io';

import 'package:jnigen/jnigen.dart';

/// Regenerates private bindings from Android SDK 36 and the local Java sources.
///
/// Accepts one optional SDK directory argument, otherwise uses ANDROID_SDK_ROOT.
/// JNIGEN_SUMMARIZER may point to a prebuilt summarizer command. Running this
/// explicitly overwrites bindings.g.dart; it is not part of normal API calls.
Future<void> main(List<String> args) async {
  final root = Platform.script.resolve('../');
  final sdk = args.isNotEmpty
      ? args.single
      : Platform.environment['ANDROID_SDK_ROOT'];
  if (sdk == null) {
    throw ArgumentError(
      'Pass the Android SDK directory or set ANDROID_SDK_ROOT.',
    );
  }
  await JniGenerator(
    input: Input(
      classes: [
        'android.hardware.usb.UsbDevice',
        'android.hardware.usb.UsbConfiguration',
        'android.hardware.usb.UsbInterface',
        'android.hardware.usb.UsbEndpoint',
        'java.lang.IllegalStateException',
        'java.lang.IllegalArgumentException',
        'dev.jx6A78.usb_host_proxy.UsbHostProxy',
      ],
      sourcePath: [root.resolve('android/src/main/java')],
      androidSdk: AndroidSdk(versions: [36], sdkRoot: Directory(sdk).uri),
      summarizerCommand: Platform.environment['JNIGEN_SUMMARIZER'],
    ),
    output: Output(
      preamble: '// ignore_for_file: prefer_initializing_formals\n',
      dart: DartOutput(
        path: root.resolve('lib/src/android/bindings.g.dart'),
        structure: OutputStructure.singleFile,
      ),
    ),
    visitors: [
      Visitor(
        method: (method) {
          // Java lifecycle creates backend objects; Dart receives references.
          // Parcelable serialization is outside the public cross-platform API.
          if (method.isConstructor ||
              {
                'describeContents',
                'writeToParcel',
              }.contains(method.originalName)) {
            method.isIncluded = false;
          }
        },
        field: (field) {
          // Parcelable creators are not useful without parcel serialization.
          if (field.originalName == 'CREATOR') field.isIncluded = false;
        },
      ),
    ],
  ).generate();
}
