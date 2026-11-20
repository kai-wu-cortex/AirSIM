package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashSet;
import java.util.Set;

/** Durable incoming-SMS delivery queue. Acknowledging locally never discards an unsent cloud event. */
final class StandaloneSMSStore {
    private static final String FILE = "standalone_sms";
    private static final String RECORDS = "records";
    private static final String REVISION = "revision";
    private static final String RECENT_IDS = "recent_delivery_ids";
    private static final String WATCH_HISTORY = "watch_history";
    private static final int WATCH_LIMIT = 60;
    private static final int MAX_RECORDS = 512;
    private static final Object LOCK = new Object();
    private final SharedPreferences preferences;

    StandaloneSMSStore(Context context) {
        preferences = context.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    boolean add(JSONObject event, boolean cloudEnabled) throws Exception {
        synchronized (LOCK) {
            String id = event.getString("delivery_id");
            SMSRecentDeliveryIDs recent = recentIDs();
            if (recent.contains(id)) return false;
            JSONArray records = records();
            for (int i = 0; i < records.length(); i++) {
                if (id.equals(records.getJSONObject(i).optString("delivery_id"))) return false;
            }
            JSONObject record = new JSONObject(event.toString())
                    .put("local_ack", false).put("cloud_sent", !cloudEnabled || RelayEgressGate.shared.isBlocked());
            records.put(record);
            while (records.length() > MAX_RECORDS) {
                recent.remember(records.getJSONObject(0).optString("delivery_id"));
                records.remove(0);
            }
            persist(records, recent, true, appendWatchMessage(publicMessage(record)));
            return true;
        }
    }

    JSONArray localMessages() throws Exception {
        synchronized (LOCK) {
            JSONArray visible = new JSONArray();
            JSONArray records = records();
            for (int i = 0; i < records.length(); i++) {
                JSONObject record = records.getJSONObject(i);
                if (!record.optBoolean("local_ack")) visible.put(publicMessage(record));
            }
            return visible;
        }
    }

    JSONArray watchMessages() throws Exception {
        synchronized (LOCK) {
            var messages = new java.util.LinkedHashMap<String, JSONObject>();
            JSONArray existing = records();
            for (int i = 0; i < existing.length(); i++) {
                JSONObject row = publicMessage(existing.getJSONObject(i));
                messages.put(row.getString("delivery_id"), row);
            }
            JSONArray history = watchHistory();
            for (int i = 0; i < history.length(); i++) {
                JSONObject row = history.getJSONObject(i);
                messages.put(row.getString("delivery_id"), row);
            }
            var sorted = new java.util.ArrayList<>(messages.values());
            sorted.sort(java.util.Comparator.comparing((JSONObject row) -> row.optString("timestamp")).reversed());
            return new JSONArray(sorted.subList(0, Math.min(WATCH_LIMIT, sorted.size())));
        }
    }

    void rememberWatchSent(String number, String body, String sim, String operationID) throws Exception {
        synchronized (LOCK) {
            JSONObject row = new JSONObject().put("delivery_id", operationID.isEmpty() ? java.util.UUID.randomUUID().toString() : operationID)
                    .put("sender", number).put("content", body).put("sim_slot", sim)
                    .put("timestamp", java.time.Instant.now().toString()).put("direction", "outgoing");
            if (!preferences.edit().putString(WATCH_HISTORY, appendWatchMessage(row).toString()).commit()) {
                throw new IllegalStateException("无法保存手表短信记录");
            }
        }
    }

    private JSONArray watchHistory() throws Exception {
        return new JSONArray(preferences.getString(WATCH_HISTORY, "[]"));
    }

    private JSONArray appendWatchMessage(JSONObject row) throws Exception {
        JSONArray history = watchHistory();
        history.put(row);
        while (history.length() > WATCH_LIMIT) history.remove(0);
        return history;
    }

    JSONArray cloudPending() throws Exception {
        synchronized (LOCK) {
            JSONArray pending = new JSONArray();
            if (RelayEgressGate.shared.isBlocked()) return pending;
            JSONArray records = records();
            for (int i = 0; i < records.length(); i++) {
                JSONObject record = records.getJSONObject(i);
                if (!record.optBoolean("cloud_sent") && !record.optBoolean("cloud_rejected")) pending.put(publicMessage(record));
            }
            return pending;
        }
    }

    void acknowledge(JSONArray ids) throws Exception {
        synchronized (LOCK) {
            Set<String> accepted = new HashSet<>();
            for (int i = 0; i < ids.length(); i++) accepted.add(ids.optString(i));
            mutate(accepted, "local_ack");
        }
    }

    void markCloudSent(String id) throws Exception {
        synchronized (LOCK) {
            mutate(Set.of(id), "cloud_sent");
        }
    }

    /** Remove only the cloud delivery obligation; keep unread local messages and dedup IDs. */
    void discardCloudBacklog() throws Exception {
        synchronized (LOCK) {
            Set<String> all = new HashSet<>();
            JSONArray records = records();
            for (int index = 0; index < records.length(); index++) {
                all.add(records.getJSONObject(index).optString("delivery_id"));
            }
            mutate(all, "cloud_sent");
        }
    }

    void markCloudRejected(String id) throws Exception {
        synchronized (LOCK) { mutate(Set.of(id), "cloud_rejected"); }
    }

    int pendingCount() throws Exception { return localMessages().length(); }
    long revision() { synchronized (LOCK) { return preferences.getLong(REVISION, 0); } }

    private void mutate(Set<String> ids, String flag) throws Exception {
        JSONArray source = records();
        JSONArray updated = new JSONArray();
        SMSRecentDeliveryIDs recent = recentIDs();
        boolean changed = false;
        for (int i = 0; i < source.length(); i++) {
            JSONObject record = source.getJSONObject(i);
            if (ids.contains(record.optString("delivery_id")) && !record.optBoolean(flag)) {
                record.put(flag, true);
                changed = true;
            }
            if (!record.optBoolean("local_ack")
                    || (!record.optBoolean("cloud_sent") && !record.optBoolean("cloud_rejected"))) updated.put(record);
            else recent.remember(record.optString("delivery_id"));
        }
        if (changed) persist(updated, recent, "local_ack".equals(flag), null);
    }

    private JSONArray records() throws Exception {
        return new JSONArray(preferences.getString(RECORDS, "[]"));
    }

    private SMSRecentDeliveryIDs recentIDs() throws Exception {
        JSONArray encoded = new JSONArray(preferences.getString(RECENT_IDS, "[]"));
        java.util.ArrayList<String> values = new java.util.ArrayList<>();
        for (int index = 0; index < encoded.length(); index++) values.add(encoded.optString(index));
        return new SMSRecentDeliveryIDs(values);
    }

    private JSONObject publicMessage(JSONObject record) throws Exception {
        return new JSONObject().put("delivery_id", record.getString("delivery_id"))
                .put("sender", record.optString("sender"))
                .put("content", record.optString("content"))
                .put("sim_slot", record.optString("sim_slot"))
                .put("android_received_at", record.optString("android_received_at"))
                .put("timestamp", record.optString("timestamp"));
    }

    private void persist(JSONArray records, SMSRecentDeliveryIDs recent, boolean advanceRevision, JSONArray watchHistory) {
        JSONArray tombstones = new JSONArray();
        for (String id : recent.snapshot()) tombstones.put(id);
        SharedPreferences.Editor editor = preferences.edit().putString(RECORDS, records.toString())
                .putString(RECENT_IDS, tombstones.toString());
        if (advanceRevision) editor.putLong(REVISION, revision() + 1);
        if (watchHistory != null) editor.putString(WATCH_HISTORY, watchHistory.toString());
        if (!editor.commit()) throw new IllegalStateException("无法保存接收短信");
    }
}
