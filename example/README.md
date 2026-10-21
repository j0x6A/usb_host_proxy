# usb_host_proxy_example

Minimal Android app displaying the plugin's public API class names. It does not
enumerate devices, request permission or perform USB operations.

Application ID: `dev.jarekxxxxx.usb_host_proxy`. The widget test checks the
displayed compilation message and all eight API class names, not Android USB
or JNI behavior. See the [plugin README](../README.md) for scope, lifecycle
contracts and remaining on-device verification.
