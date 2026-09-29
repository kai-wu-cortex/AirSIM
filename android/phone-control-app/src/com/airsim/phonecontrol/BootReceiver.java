package com.airsim.phonecontrol;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        BridgeLog.initialize(context);
        String action = intent == null ? "" : intent.getAction();
        boolean configured = AppConfig.configured(context);
        BridgeLog.info("boot_receiver action=" + action + " configured=" + configured);
        if (configured) AgentWatchdogService.start(context);
    }
}
