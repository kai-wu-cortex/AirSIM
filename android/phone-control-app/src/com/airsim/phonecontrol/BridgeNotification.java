package com.airsim.phonecontrol;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

public final class BridgeNotification {
    public static final String CHANNEL = "airsim_bridge_status";
    private static final String CALL_CHANNEL = "airsim_incoming_calls_v1";
    public static final int WATCHDOG_ID = 5071;
    public static final int RECOVERY_ID = 5074;
    private static final int CALL_ID = 5072;
    public static final int VOWLAN_ID = 5073;
    private BridgeNotification() {}

    public static void createChannel(Context context) {
        NotificationChannel channel = new NotificationChannel(CHANNEL, "AirSIM 通话桥", NotificationManager.IMPORTANCE_LOW);
        channel.setSound(null, null);
        channel.enableVibration(false);
        context.getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }

    private static void createCallChannel(Context context) {
        NotificationChannel channel = new NotificationChannel(
                CALL_CHANNEL, "AirSIM 来电", NotificationManager.IMPORTANCE_HIGH);
        // The iPhone is the primary ringer in remote_silent mode. Android still
        // needs a visible, actionable call surface when the phone is locked.
        channel.setSound(null, null);
        channel.enableVibration(false);
        context.getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }

    public static Notification status(Context context, String detail) {
        createChannel(context);
        PendingIntent open = PendingIntent.getActivity(context, 0, new Intent(context, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle("AirSIM 通话桥")
                .setContentText(detail)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    public static Notification terminalRecovery(Context context, Intent terminal) {
        createChannel(context);
        PendingIntent open = PendingIntent.getActivity(context, RECOVERY_ID, terminal,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle("AirSIM 需要恢复 Linux VM")
                .setContentText("点按打开 Terminal 恢复连接")
                .setContentIntent(open)
                .addAction(android.R.drawable.ic_menu_view, "打开 Terminal", open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    public static Notification vowlan(Context context, String detail) {
        createChannel(context);
        PendingIntent open = PendingIntent.getActivity(context, 2, new Intent(context, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle("AirSIM VoWLAN")
                .setContentText(detail)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    public static void showCall(Context context, String callId, String direction, String mode, String state) {
        if (callId == null || callId.isEmpty() || "ended".equals(state) || "unknown".equals(state)) return;
        boolean incoming = "incoming".equals(direction) && "incoming".equals(state);
        if (incoming) createCallChannel(context);
        else createChannel(context);
        Intent screenIntent = new Intent(context, CallScreenActivity.class)
                .setData(Uri.parse("airsim-call://screen/" + Uri.encode(callId)))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP
                        | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(CallScreenActivity.EXTRA_CALL_ID, callId);
        PendingIntent screen = PendingIntent.getActivity(context, 1, screenIntent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        String text = incoming
                ? (AppConfig.MODE_REMOTE_SILENT.equals(mode)
                    ? "已转送 iPhone；也可在此处理" : "可在此接听或拒接")
                : "通话进行中 · 点按查看";
        Notification.Builder builder = new Notification.Builder(context, incoming ? CALL_CHANNEL : CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle(incoming ? "AirSIM 来电" : "AirSIM 通话")
                .setContentText(text)
                .setContentIntent(screen)
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setOnlyAlertOnce(true);
        if (incoming) {
            builder.setPriority(Notification.PRIORITY_HIGH)
                    .setFullScreenIntent(screen, true)
                    .addAction(android.R.drawable.sym_action_call, "接听",
                            CallNotificationActionReceiver.pendingIntent(context, callId, "answer"))
                    .addAction(android.R.drawable.ic_menu_close_clear_cancel, "拒接",
                            CallNotificationActionReceiver.pendingIntent(context, callId, "reject"));
        } else {
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "挂断",
                    CallNotificationActionReceiver.pendingIntent(context, callId, "end"));
        }
        context.getSystemService(NotificationManager.class).notify(callId, CALL_ID, builder.build());
    }

    public static void clearCall(Context context, String callId) {
        context.getSystemService(NotificationManager.class).cancel(callId, CALL_ID);
    }
}
