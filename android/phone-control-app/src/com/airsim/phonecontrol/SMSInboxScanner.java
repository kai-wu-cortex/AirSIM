package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.provider.BaseColumns;
import android.provider.Telephony;
import android.telephony.SubscriptionManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.time.Instant;
import java.util.UUID;

/** Optional READ_SMS fallback; never imports messages present before the first authorized scan. */
final class SMSInboxScanner {
    private static final String PREFS = "sms_inbox_fallback";
    private static final String LAST_ID = "last_inbox_id";
    private static final String SCANNER_VERSION = "scanner_version";
    private static final int CURRENT_SCANNER_VERSION = 3;
    private static final long INTERVAL_MS = 30_000;
    private static final int BATCH_SIZE = 100;
    private static final String SHIZUKU_CAUGHT_UP = "shizuku_caught_up_v1";
    private static final String SHIZUKU_CUTOFF = "shizuku_catch_up_cutoff_v1";
    private static long lastScanTime;

    private SMSInboxScanner() {}

    static synchronized void scanIfDue(Context context) {
        if (context.checkSelfPermission(Manifest.permission.READ_SMS)
                != PackageManager.PERMISSION_GRANTED) return;
        long now = System.currentTimeMillis();
        if (now - lastScanTime < INTERVAL_MS) return;
        lastScanTime = now;
        try {
            scan(context.getApplicationContext());
        } catch (Exception error) {
            BridgeLog.error("sms_inbox_scan_failed", error);
        }
    }

    private static void scan(Context context) throws Exception {
        SharedPreferences preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (preferences.getInt(SCANNER_VERSION, 0) < CURRENT_SCANNER_VERSION) {
            // One-time migration: older builds skipped the whole inbox on first
            // scan, dropping messages received while AirSIM was stopped.
            preferences.edit().remove(LAST_ID)
                    .putInt(SCANNER_VERSION, CURRENT_SCANNER_VERSION).commit();
        }
        SMSInboxCursor progress = new SMSInboxCursor(preferences.getLong(LAST_ID, -1));
        long cutoff = System.currentTimeMillis() - 15L * 60L * 1_000L;
        boolean firstScan = !progress.initialized();
        SMSInboxCatchUp catchUp = new SMSInboxCatchUp(
                preferences.getBoolean(SHIZUKU_CAUGHT_UP, false),
                preferences.getLong(SHIZUKU_CUTOFF, 0), System.currentTimeMillis());
        // MIUI filters content://sms for non-default SMS apps, so the local
        // provider may only expose an old cursor. Prefer the authenticated
        // Shizuku shell view, which has READ_SMS and sees the real inbox.
        String privileged = ShizukuBridgeManager.get(context).recentSms(
                firstScan ? -1 : progress.value(), catchUp.completed() ? cutoff : catchUp.cutoff(), BATCH_SIZE);
        if (privileged != null && privileged.startsWith("[")) {
            try {
                JSONArray rows = new JSONArray(privileged);
                // Freeze the cutoff across batches/restarts, including a failed delivery.
                if (!catchUp.completed() && !preferences.edit()
                        .putLong(SHIZUKU_CUTOFF, catchUp.cutoff()).commit()) {
                    throw new IllegalStateException("SMS catch-up cutoff could not be saved");
                }
                int recent = 0;
                for (int index = 0; index < rows.length(); index++) {
                    JSONObject row = rows.getJSONObject(index);
                    long rowID = row.optLong("id", -1);
                    if (rowID < 0) continue;
                    String sender = row.optString("address", "");
                    String content = row.optString("body", "");
                    long receivedAt = row.optLong("date", 0);
                    long sentAt = row.optLong("date_sent", 0);
                    long timestamp = SMSDeliveryIdentity.providerTimestamp(sentAt, receivedAt);
                    if (timestamp <= 0) timestamp = System.currentTimeMillis();
                    if (!content.isEmpty() && catchUp.shouldForward(receivedAt, sentAt)) {
                        queueIncoming(context, sender, content, timestamp, row.optInt("sub_id", -1));
                        recent++;
                    }
                    progress.processed(rowID);
                }
                persist(preferences, progress);
                boolean finished = !catchUp.completed() && catchUp.drained(rows.length(), BATCH_SIZE);
                if (finished && !preferences.edit().putBoolean(SHIZUKU_CAUGHT_UP, true).commit()) {
                    throw new IllegalStateException("SMS catch-up completion could not be saved");
                }
                if (recent > 0 || finished) BridgeLog.info("sms_inbox_scan"
                        + " source=shizuku recent=" + recent + " latest=" + progress.value()
                        + " catch_up_complete=" + (catchUp.completed() || finished));
                return;
            } catch (Exception error) {
                BridgeLog.error("sms_inbox_privileged_parse_failed", error);
            }
        }
        if (!progress.initialized()) {
            // First authorized scan: import a short recent window instead of
            // treating every existing row as history. MIUI does not reliably
            // deliver SMS_RECEIVED to a non-default SMS app while AirSIM is
            // stopped, so messages received just before launch were lost.
            String[] projection = {BaseColumns._ID, Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.DATE_SENT, "sub_id"};
            int recent = 0;
            try (Cursor cursor = context.getContentResolver().query(Telephony.Sms.Inbox.CONTENT_URI,
                    projection, Telephony.Sms.DATE + " >= ?",
                    new String[]{Long.toString(cutoff)}, BaseColumns._ID + " ASC")) {
                if (cursor == null) throw new IllegalStateException("SMS inbox provider unavailable");
                while (cursor.moveToNext()) {
                    long rowID = cursor.getLong(0);
                    String sender = cursor.getString(1);
                    String content = cursor.getString(2);
                    if (content != null && !content.isEmpty()) {
                        long receivedAt = cursor.getLong(3);
                        long sentAt = cursor.getLong(4);
                        long timestamp = SMSDeliveryIdentity.providerTimestamp(sentAt, receivedAt);
                        if (timestamp <= 0) timestamp = System.currentTimeMillis();
                        queueIncoming(context, sender, content, timestamp, cursor.getInt(5));
                        recent++;
                    }
                    progress.processed(rowID);
                }
            }
            String[] idProjection = {BaseColumns._ID};
            try (Cursor cursor = context.getContentResolver().query(Telephony.Sms.Inbox.CONTENT_URI,
                    idProjection, null, null, BaseColumns._ID + " DESC")) {
                if (cursor != null && cursor.moveToFirst()) progress.processed(cursor.getLong(0));
            }
            persist(preferences, progress);
            BridgeLog.info("sms_inbox_baseline_initialized recent=" + recent
                    + " latest=" + progress.value());
            return;
        }

        String[] projection = {BaseColumns._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
                Telephony.Sms.DATE, Telephony.Sms.DATE_SENT, "sub_id"};
        try (Cursor cursor = context.getContentResolver().query(Telephony.Sms.Inbox.CONTENT_URI,
                projection, BaseColumns._ID + " > ?",
                new String[]{Long.toString(progress.value())}, BaseColumns._ID + " ASC")) {
            if (cursor == null) throw new IllegalStateException("SMS inbox provider unavailable");
            int scanned = 0;
            int nonempty = 0;
            long startingID = progress.value();
            while (scanned < BATCH_SIZE && cursor.moveToNext()) {
                scanned++;
                long rowID = cursor.getLong(0);
                if (!progress.shouldQueue(rowID)) continue;
                String sender = cursor.getString(1);
                String content = cursor.getString(2);
                if (content != null && !content.isEmpty()) {
                    nonempty++;
                    long receivedAt = cursor.getLong(3);
                    long sentAt = cursor.getLong(4);
                    long timestamp = SMSDeliveryIdentity.providerTimestamp(sentAt, receivedAt);
                    if (timestamp <= 0) timestamp = System.currentTimeMillis();
                    queueIncoming(context, sender, content, timestamp, cursor.getInt(5));
                }
                progress.processed(rowID);
                persist(preferences, progress);
            }
            if (scanned > 0) BridgeLog.info("sms_inbox_scan rows=" + scanned
                    + " nonempty=" + nonempty + " cursor_before=" + startingID
                    + " cursor_after=" + progress.value());
        }
    }

    private static void queueIncoming(
            Context context, String sender, String content, long timestamp,
            int subscriptionID) throws Exception {
        String deliveryID = SMSDeliveryIdentity.id(sender, content, timestamp);
        JSONObject event = new JSONObject(WireJson.smsEvent(UUID.randomUUID().toString(),
                deliveryID, sender == null ? "" : sender, content,
                Instant.ofEpochMilli(timestamp).toString(), simSlot(context, subscriptionID)));
        if (RuntimeMode.isStandalone(context)) {
            StandaloneAgentGateway.get(context).sendSMSEvent(event.toString());
        } else {
            new StandaloneSMSStore(context).add(event, true);
        }
    }

    private static String simSlot(Context context, int subscriptionID) {
        if (subscriptionID <= 0) return "";
        try {
            SubscriptionManager manager = context.getSystemService(SubscriptionManager.class);
            int slot = manager == null ? -1 : manager.getSlotIndex(subscriptionID);
            return slot >= 0 ? "SIM " + (slot + 1) : "";
        } catch (RuntimeException ignored) {
            return "";
        }
    }

    private static void persist(SharedPreferences preferences, SMSInboxCursor progress) {
        if (!preferences.edit().putLong(LAST_ID, progress.value()).commit()) {
            throw new IllegalStateException("SMS inbox cursor could not be saved");
        }
    }
}
