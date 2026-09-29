package com.airsim.phonecontrol;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

public final class BridgeNotification {
    public static final String CHANNEL = "airsim_bridge_status";
    public static final int WATCHDOG_ID = 5071;
    private static final int CALL_ID = 5072;
    public static final int VOWLAN_ID = 5073;
    private BridgeNotification() {}

    public static void createChannel(Context context) {
        NotificationChannel channel = new NotificationChannel(CHANNEL, "AirSIM 通话桥", NotificationManager.IMPORTANCE_LOW);
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

    public static void showCallFallback(Context context, String callId, String direction, String mode) {
        if (!"incoming".equals(direction)) return;
		createChannel(context);
        String text = AppConfig.MODE_REMOTE_SILENT.equals(mode) ? "来电已转送 iOS；点按可在三星处理" : "来电已同步到 iOS";
        Notification notification = new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle("AirSIM 来电")
                .setContentText(text)
                .setContentIntent(PendingIntent.getActivity(context, 1, new Intent(context, MainActivity.class),
                        PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT))
                .setCategory(Notification.CATEGORY_CALL)
                .setOnlyAlertOnce(true)
                .build();
        context.getSystemService(NotificationManager.class).notify(CALL_ID, notification);
    }

    public static void clearCallFallback(Context context) {
        context.getSystemService(NotificationManager.class).cancel(CALL_ID);
    }
}
