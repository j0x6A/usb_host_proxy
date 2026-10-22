package dev.jx6A78.usb_host_proxy;

import android.content.Intent;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.PluginRegistry.NewIntentListener;

/**
 * Connects Flutter engine/Activity lifecycle and USB intents to the existing JNI session.
 *
 * <p>The engine owns the session; an Activity owns only its intent-listener registration.
 * Configuration changes therefore replace Activity references without replacing USB
 * attachments. No Activity is required for discovery or broadcast handling.
 */
public final class UsbHostProxyPlugin
        implements FlutterPlugin, FlutterEngine.EngineLifecycleListener, ActivityAware {
    /** Engine resources retained until plugin detach; null makes later callbacks no-ops. */
    private FlutterPluginBinding binding;
    /** Optional binding, valid only until Activity detach; never passed into the session. */
    private ActivityPluginBinding activityBinding;
    /** Registration identity also rejects old callbacks if the same binding object is reused. */
    private NewIntentListener newIntentListener;

    /** Creates the engine's session and registers for restart/destruction notifications. */
    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        this.binding = binding;
        UsbHostProxy.attach(binding.getApplicationContext(), binding.getFlutterEngine().getEngineId());
        binding.getFlutterEngine().addEngineLifecycleListener(this);
    }

    /**
     * Replaces the session before Dart restarts so old wrappers and pending work expire.
     * Keeps the existing Activity listener, but treats its stored intent as initial state
     * for the new session. Subsequent callbacks look up that new session by engine ID.
     */
    @Override
    public void onPreEngineRestart() {
        FlutterPluginBinding currentBinding = binding;
        if (currentBinding != null) {
            UsbHostProxy.attach(
                    currentBinding.getApplicationContext(),
                    currentBinding.getFlutterEngine().getEngineId());
            if (activityBinding != null) {
                handleActivityIntent(activityBinding.getActivity().getIntent(), true);
            }
        }
    }

    /** Disposes the session before engine destruction; later plugin detach is idempotent. */
    @Override
    public void onEngineWillDestroy() {
        detachActivity();
        FlutterPluginBinding currentBinding = binding;
        if (currentBinding != null) {
            UsbHostProxy.detach(currentBinding.getFlutterEngine().getEngineId());
        }
    }

    /** Removes the lifecycle listener, ends the session and releases the engine binding. */
    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        detachActivity();
        binding.getFlutterEngine().removeEngineLifecycleListener(this);
        UsbHostProxy.detach(binding.getFlutterEngine().getEngineId());
        this.binding = null;
    }

    /**
     * Installs one listener and reads the Activity's current intent as silent initial state.
     * Replaces any previous registration. Both binding and listener identities must match
     * before a callback can enter the session; this is not a second device registry.
     */
    @Override
    public void onAttachedToActivity(ActivityPluginBinding activity) {
        if (binding == null) return;
        detachActivity();
        activityBinding = activity;
        newIntentListener = new NewIntentListener() {
            @Override
            public boolean onNewIntent(Intent intent) {
                return activityBinding == activity && newIntentListener == this
                        && handleActivityIntent(intent, false);
            }
        };
        activity.addOnNewIntentListener(newIntentListener);
        handleActivityIntent(activity.getActivity().getIntent(), true);
    }

    /** Removes Activity references, keeping USB resources alive across configuration changes. */
    @Override
    public void onDetachedFromActivityForConfigChanges() {
        detachActivity();
    }

    /** A recreated Activity's saved intent is initial state, not a new USB attach event. */
    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding activity) {
        onAttachedToActivity(activity);
    }

    /** Stops Activity delivery without ending the engine's headless-capable session. */
    @Override
    public void onDetachedFromActivity() {
        detachActivity();
    }

    /**
     * Uses current engine lookup so restart cannot route intents to an obsolete session.
     * initial distinguishes stored Activity state from a newly delivered runtime intent.
     * True means a valid USB payload was recognized, not that an attach event was emitted.
     */
    private boolean handleActivityIntent(Intent intent, boolean initial) {
        FlutterPluginBinding currentBinding = binding;
        return currentBinding != null && activityBinding != null
                && UsbHostProxy.handleActivityIntent(
                        currentBinding.getFlutterEngine().getEngineId(), intent, initial);
    }

    /**
     * Clears both references before removing this exact listener from its original binding.
     * Repeated calls are harmless and late callbacks become no-ops. Does not dispose USB.
     */
    private void detachActivity() {
        ActivityPluginBinding previous = activityBinding;
        NewIntentListener previousListener = newIntentListener;
        activityBinding = null;
        newIntentListener = null;
        if (previous != null) previous.removeOnNewIntentListener(previousListener);
    }
}
