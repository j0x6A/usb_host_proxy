package dev.jarekxxxxx.usb_host_proxy;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class UsbHostProxyPlugin
        implements FlutterPlugin, FlutterEngine.EngineLifecycleListener {
    private FlutterPluginBinding binding;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        this.binding = binding;
        UsbHostProxy.attach(binding.getApplicationContext(), binding.getFlutterEngine().getEngineId());
        binding.getFlutterEngine().addEngineLifecycleListener(this);
    }

    @Override
    public void onPreEngineRestart() {
        FlutterPluginBinding currentBinding = binding;
        if (currentBinding != null) {
            UsbHostProxy.attach(
                    currentBinding.getApplicationContext(),
                    currentBinding.getFlutterEngine().getEngineId());
        }
    }

    @Override
    public void onEngineWillDestroy() {
        FlutterPluginBinding currentBinding = binding;
        if (currentBinding != null) {
            UsbHostProxy.detach(currentBinding.getFlutterEngine().getEngineId());
        }
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        binding.getFlutterEngine().removeEngineLifecycleListener(this);
        UsbHostProxy.detach(binding.getFlutterEngine().getEngineId());
        this.binding = null;
    }
}
