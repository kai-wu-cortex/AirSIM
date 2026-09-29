package com.airsim.phonecontrol;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class DebugCommandReceiver extends BroadcastReceiver {
    static final String ACTION_SET_LOCAL_OUTPUT =
            "com.airsim.phonecontrol.DEBUG_SET_LOCAL_OUTPUT";

    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !ACTION_SET_LOCAL_OUTPUT.equals(intent.getAction())) return;
        boolean muted = intent.getBooleanExtra("muted", false);
        BridgeLog.initialize(context);
        BridgeLog.info("debug_local_output_requested target_muted=" + muted);
        ShizukuBridgeManager.get(context).setLocalOutputMuted(muted);
    }
}
