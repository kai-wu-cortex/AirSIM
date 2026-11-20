package com.airsim.phonecontrol;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

/** Stores the iPhone-provided forwarding destinations alongside the paired agent. */
final class ForwardingConfigStore {
    private static final String FILE = "notification_forwarding";
    private static final String CONFIG = "config";

    private ForwardingConfigStore() {}

    static synchronized boolean clear(Context context) {
        return context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .edit().remove(CONFIG).commit();
    }

    static synchronized void saveFromRegistration(Context context, JSONObject registration) {
        if (registration == null || !registration.has("notification_forwarding")) return;
        try {
            JSONObject config = registration.optJSONObject("notification_forwarding");
            if (config == null) return;
            context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                    .edit().putString(CONFIG, config.toString()).apply();
            JSONArray destinations = config.optJSONArray("destinations");
            BridgeLog.info("notification_forwarding_saved destinations="
                    + (destinations == null ? 0 : destinations.length()));
        } catch (Exception error) {
            BridgeLog.error("notification_forwarding_save_failed", error);
        }
    }

    static synchronized JSONObject config(Context context) {
        String encoded = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .getString(CONFIG, "");
        if (encoded == null || encoded.isBlank()) return new JSONObject();
        try { return new JSONObject(encoded); }
        catch (Exception error) {
            BridgeLog.error("notification_forwarding_corrupt", error);
            return new JSONObject();
        }
    }
}
