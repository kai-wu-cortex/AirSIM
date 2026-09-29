package com.airsim.phonecontrol;

import android.content.Context;
final class LocalCallAudioController {
    private final ShizukuBridgeManager privilegedBridge;
    private boolean silencing;

    LocalCallAudioController(Context context) {
        privilegedBridge = ShizukuBridgeManager.get(context);
    }

    synchronized void update(boolean shouldSilence) {
        if (shouldSilence == silencing) return;
        silencing = shouldSilence;
        privilegedBridge.setLocalOutputMuted(shouldSilence);
        BridgeLog.info("local_call_output_requested target_silent=" + shouldSilence
                + " backend=shizuku");
    }
}
