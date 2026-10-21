import 'dart:io';

import 'package:jnigen/jnigen.dart';

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
        'dev.jarekxxxxx.usb_host_proxy.UsbHostProxy',
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
          if (method.isConstructor ||
              {
                'describeContents',
                'writeToParcel',
              }.contains(method.originalName)) {
            method.isIncluded = false;
          }
        },
        field: (field) {
          if (field.originalName == 'CREATOR') field.isIncluded = false;
        },
      ),
    ],
  ).generate();
}
