package com.airsim.phonecontrol;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * The registration fields the Relay reads (validateRegistration and registerDevice). Nothing else
 * leaves the phone: not the VoWLAN or E2E keys, notification webhooks, or the Android identity.
 */
final class RelayRegistrationPayload {
    static final String[] FIELDS = {
            "device_id", "device_secret", "voip_token", "alert_token", "watch_voip_token", "watch_bundle_id",
            "live_activity_push_to_start_token", "live_activity_presentation", "bundle_id", "environment",
            "media_transport", "app_media_capabilities", "agent_media_capabilities", "force_legacy_pcm"};

    private RelayRegistrationPayload() {}

    /** What one sync covers: the payload and the Relay it went to, so a new Relay URL re-registers at once. */
    static String syncKey(JSONObject stored) throws JSONException {
        return stored.optString("relay_url", "") + "\n" + forRelay(stored);
    }

    static JSONObject forRelay(JSONObject stored) throws JSONException {
        JSONObject payload = new JSONObject();
        for (String field : FIELDS) {
            if (stored.has(field)) payload.put(field, stored.get(field));
        }
        return payload;
    }
}
