package dev.jarekxxxxx.usb_host_proxy

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.FlutterEngine

/** Android registration entry point. USB interop will use JNI. */
class UsbHostProxyPlugin : FlutterPlugin, FlutterEngine.EngineLifecycleListener {
    private var binding: FlutterPlugin.FlutterPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        UsbHostBridge.attach(binding.applicationContext, binding.flutterEngine.engineId)
        binding.flutterEngine.addEngineLifecycleListener(this)
    }

    override fun onPreEngineRestart() {
        binding?.let { UsbHostBridge.attach(it.applicationContext, it.flutterEngine.engineId) }
    }

    override fun onEngineWillDestroy() {
        binding?.let { UsbHostBridge.detach(it.flutterEngine.engineId) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.flutterEngine.removeEngineLifecycleListener(this)
        UsbHostBridge.detach(binding.flutterEngine.engineId)
        this.binding = null
    }
}
