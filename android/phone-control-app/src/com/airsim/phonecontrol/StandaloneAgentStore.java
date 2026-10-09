package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.util.Locale;

/** Private persistent state for the Agent embedded in the standalone APK. */
final class StandaloneAgentStore {
    private static final String FILE = "standalone_agent";
    private static final String REGISTRATION = "registration";
    private static final String LAST_ERROR = "last_error";
    private static final String LAST_HEARTBEAT = "last_heartbeat";
    private static final String LAST_SEEN = "last_seen";

    private final SharedPreferences preferences;

    StandaloneAgentStore(Context context) {
        preferences = context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    synchronized JSONObject registration() {
        String encoded = preferences.getString(REGISTRATION, "");
        if (encoded == null || encoded.isBlank()) return null;
        try { return new JSONObject(encoded); }
        catch (Exception error) {
            BridgeLog.error("standalone_registration_corrupt", error);
            return null;
        }
    }

    synchronized JSONObject saveRegistration(String encoded) throws Exception {
        JSONObject value = new JSONObject(encoded);
        validateRegistration(value);
        value.put("device_id", value.getString("device_id").trim());
        value.put("relay_url", trimTrailingSlash(value.optString("relay_url", "").trim()));
        for (String key : new String[]{"voip_token", "alert_token", "watch_voip_token",
                "live_activity_push_to_start_token"}) {
            if (value.has(key)) value.put(key, value.optString(key, "").toLowerCase(Locale.ROOT));
        }
        preferences.edit().putString(REGISTRATION, value.toString()).remove(LAST_ERROR).apply();
        return value;
    }

    boolean configured() {
        JSONObject value = registration();
        return value != null && !value.optString("device_id", "").isBlank()
                && !value.optString("device_secret", "").isBlank()
                && !value.optString("relay_url", "").isBlank();
    }

    boolean cloudEnabled() {
        JSONObject value = registration();
        return value != null && value.optBoolean("cloud_enabled", true);
    }

    void recordSuccess() {
        preferences.edit().putLong(LAST_SEEN, System.currentTimeMillis()).remove(LAST_ERROR).apply();
    }

    void recordHeartbeat() {
        preferences.edit().putLong(LAST_HEARTBEAT, System.currentTimeMillis())
                .putLong(LAST_SEEN, System.currentTimeMillis()).remove(LAST_ERROR).apply();
    }

    void recordError(String error) {
        preferences.edit().putString(LAST_ERROR, DebugRedactor.sanitize(error)).apply();
    }

    String lastError() { return preferences.getString(LAST_ERROR, ""); }
    long lastSeen() { return preferences.getLong(LAST_SEEN, 0L); }
    long lastHeartbeat() { return preferences.getLong(LAST_HEARTBEAT, 0L); }

    JSONObject pushStatus() throws Exception {
        JSONObject registration = registration();
        boolean configured = registration != null;
        JSONObject result = new JSONObject()
                .put("cloud_enabled", configured && registration.optBoolean("cloud_enabled", true))
                .put("configured", configured)
                .put("call_push_ready", configured && (!registration.optString("voip_token", "").isEmpty()
                        || !registration.optString("watch_voip_token", "").isEmpty()))
                .put("message_push_ready", configured && !registration.optString("alert_token", "").isEmpty())
                .put("last_error", lastError())
                .put("wan_interface", "android-default");
        if (configured) {
            result.put("device_id", registration.optString("device_id", ""));
            result.put("environment", registration.optString("environment", ""));
            result.put("relay_url", registration.optString("relay_url", ""));
        }
        return result;
    }

    static void validateRegistration(JSONObject value) throws Exception {
        String deviceID = value.optString("device_id", "").trim();
        String secret = value.optString("device_secret", "");
        String bundleID = value.optString("bundle_id", "").trim();
        String environment = value.optString("environment", "");
        String relayURL = value.optString("relay_url", "").trim();
        if (deviceID.isEmpty() || deviceID.length() > 128) throw new IllegalArgumentException("device_id 无效");
        if (secret.length() < 16 || secret.length() > 512) throw new IllegalArgumentException("device_secret 无效");
        if (bundleID.isEmpty() || bundleID.length() > 255) throw new IllegalArgumentException("bundle_id 无效");
        if (!"sandbox".equals(environment) && !"production".equals(environment)) {
            throw new IllegalArgumentException("environment 必须是 sandbox 或 production");
        }
        URI relay = URI.create(relayURL);
        if (!"https".equalsIgnoreCase(relay.getScheme()) || relay.getHost() == null
                || relay.getRawUserInfo() != null) {
            throw new IllegalArgumentException("relay_url 必须是无凭据的 HTTPS 地址");
        }
        boolean hasToken = false;
        for (String key : new String[]{"voip_token", "alert_token", "watch_voip_token",
                "live_activity_push_to_start_token"}) {
            String token = value.optString(key, "");
            if (!token.isEmpty()) {
                hasToken = true;
                if ((token.length() & 1) != 0 || !token.matches("[0-9a-fA-F]{16,512}")) {
                    throw new IllegalArgumentException(key + " 无效");
                }
            }
        }
        if (!hasToken) throw new IllegalArgumentException("至少需要一个 APNs token");
        String watchToken = value.optString("watch_voip_token", "");
        if (!watchToken.isEmpty() && !(bundleID + ".watchkitapp").equals(value.optString("watch_bundle_id", ""))) {
            throw new IllegalArgumentException("watch_bundle_id 与主应用不匹配");
        }
        JSONArray capabilities = value.optJSONArray("agent_media_capabilities");
        if (capabilities == null) {
            value.put("agent_media_capabilities", new JSONArray().put("legacy_pcm"));
        }
    }

    private static String trimTrailingSlash(String value) {
        while (value.endsWith("/")) value = value.substring(0, value.length() - 1);
        return value;
    }
}
