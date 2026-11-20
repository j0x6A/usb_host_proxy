plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle Plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val usbJniTest = providers.environmentVariable("USB_HOST_PROXY_JNI_TEST").orNull == "true"

android {
    namespace = "dev.jx6A78.usb_host_proxy_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.jx6A78.usb_host_proxy"
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // This local example uses debug signing for release as well.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    if (usbJniTest) {
        sourceSets.getByName("debug").java.srcDir("src/jniTest/java")
        packaging.jniLibs.useLegacyPackaging = true
    }
}

if (usbJniTest) {
    dependencies.add("debugImplementation", "org.mockito:mockito-android:5.24.0")
}

flutter {
    source = "../.."
}
