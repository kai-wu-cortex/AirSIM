package com.airsim.phonecontrol;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

import java.util.UUID;

/** Executes only call-scoped actions from AirSIM's private call notification. */
public final class CallNotificationActionReceiver extends BroadcastReceiver {
    static final String EXTRA_CALL_ID = "com.airsim.phonecontrol.CALL_ID";
    private static final String ACTION_PREFIX = "com.airsim.phonecontrol.call.";

    static PendingIntent pendingIntent(Context context, String callId, String action) {
        Intent intent = new Intent(context, CallNotificationActionReceiver.class)
                .setAction(ACTION_PREFIX + action)
                .setData(Uri.parse("airsim-call://action/" + Uri.encode(callId) + "/" + action))
                .putExtra(EXTRA_CALL_ID, callId);
        return PendingIntent.getBroadcast(context, 0, intent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    static Intent actionIntent(Context context, String callId, String action) {
        return new Intent(context, CallNotificationActionReceiver.class)
                .setAction(ACTION_PREFIX + action)
                .putExtra(EXTRA_CALL_ID, callId);
    }

    @Override public void onReceive(Context context, Intent intent) {
        String rawAction = intent == null ? "" : intent.getAction();
        String action = rawAction != null && rawAction.startsWith(ACTION_PREFIX)
                ? rawAction.substring(ACTION_PREFIX.length()) : "";
        if (!"answer".equals(action) && !"reject".equals(action) && !"end".equals(action)) return;
        String callId = intent.getStringExtra(EXTRA_CALL_ID);
        if (callId == null || callId.isEmpty() || CallRepository.state(callId) == -1) return;
        PendingResult pending = goAsync();
        Context application = context.getApplicationContext();
        new Thread(() -> {
            try {
                CallRepository.ActionResult result = CallRepository.execute(
                        application, new AgentCommand(UUID.randomUUID().toString(), action, callId, ""));
                if (!result.success) BridgeLog.info("call_notification_action_failed action=" + action
                        + " reason=" + DebugRedactor.sanitize(result.error));
            } finally {
                pending.finish();
            }
        }, "airsim-call-action").start();
    }
}
