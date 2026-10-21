# usb_host_proxy_example

Minimal Android compilation example for the public usb_host_proxy declarations.
It displays the API class names; USB operations and JNI bindings are added later.

From this directory:

```sh
flutter pub get
flutter test
flutter build apk --debug
```

The application ID is `dev.jarekxxxxx.usb_host_proxy`.
The example version currently follows the package version by convention.
The widget test checks the displayed compilation message, not USB behavior.
