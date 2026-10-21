# usb_host_proxy_example

Minimal Android app displaying the plugin's public API class names. It does not
enumerate devices, request permission or perform USB operations.

Application ID: `dev.jarekxxxxx.usb_host_proxy`. The widget test checks the
displayed compilation message and all eight API class names, not Android USB
or JNI behavior. See the [plugin README](../README.md) for scope, lifecycle
contracts and remaining on-device verification.

The example deliberately has no USB launch filter or `device_filter.xml`.
Applications that need autostart must select their own supported hardware and
follow [USB launch configuration](../README.md#usb-triggered-application-launch).
The example's namespace differs from its application ID; its manifest uses the
fully qualified Java Activity name, so no implicit namespace lookup is required.
