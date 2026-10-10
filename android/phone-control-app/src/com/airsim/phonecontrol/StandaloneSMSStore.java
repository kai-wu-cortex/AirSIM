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
    private static final int MAX_RECORDS = 512;
    private static final Object LOCK = new Object();
    private final SharedPreferences preferences;

    StandaloneSMSStore(Context context) {
        preferences = context.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    boolean add(JSONObject event, boolean cloudEnabled) throws Exception {
        synchronized (LOCK) {
            String id = event.getString("delivery_id");
            JSONArray records = records();
            for (int i = 0; i < records.length(); i++) {
                if (id.equals(records.getJSONObject(i).optString("delivery_id"))) return false;
            }
            JSONObject record = new JSONObject(event.toString())
                    .put("local_ack", false).put("cloud_sent", !cloudEnabled);
            records.put(record);
            while (records.length() > MAX_RECORDS) records.remove(0);
            persist(records, true);
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

    JSONArray cloudPending() throws Exception {
        synchronized (LOCK) {
            JSONArray pending = new JSONArray();
            JSONArray records = records();
            for (int i = 0; i < records.length(); i++) {
                JSONObject record = records.getJSONObject(i);
                if (!record.optBoolean("cloud_sent")) pending.put(publicMessage(record));
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

    int pendingCount() throws Exception { return localMessages().length(); }
    long revision() { synchronized (LOCK) { return preferences.getLong(REVISION, 0); } }

    private void mutate(Set<String> ids, String flag) throws Exception {
        JSONArray source = records();
        JSONArray updated = new JSONArray();
        boolean changed = false;
        for (int i = 0; i < source.length(); i++) {
            JSONObject record = source.getJSONObject(i);
            if (ids.contains(record.optString("delivery_id")) && !record.optBoolean(flag)) {
                record.put(flag, true);
                changed = true;
            }
            if (!record.optBoolean("local_ack") || !record.optBoolean("cloud_sent")) updated.put(record);
        }
        if (changed) persist(updated, "local_ack".equals(flag));
    }

    private JSONArray records() throws Exception {
        return new JSONArray(preferences.getString(RECORDS, "[]"));
    }

    private JSONObject publicMessage(JSONObject record) throws Exception {
        return new JSONObject().put("delivery_id", record.getString("delivery_id"))
                .put("sender", record.optString("sender"))
                .put("content", record.optString("content"))
                .put("timestamp", record.optString("timestamp"));
    }

    private void persist(JSONArray records, boolean advanceRevision) {
        SharedPreferences.Editor editor = preferences.edit().putString(RECORDS, records.toString());
        if (advanceRevision) editor.putLong(REVISION, revision() + 1);
        if (!editor.commit()) throw new IllegalStateException("无法保存接收短信");
    }
}
