package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.Base64;

import org.json.JSONObject;

/** E2E SMS key of each cloud registration (iPhone device id + Relay); written only by a sealed pairing claim. */
final class E2EKeyStore {
    private static final String FILE = "e2e_sms_keys";

    private E2EKeyStore() {}

    // Persist a fail-closed marker before publishing a first encrypted registration.
    // A background flush must never observe a new registration with no key and send plaintext.
    static void prepareEncryptedPairing(Context context, String deviceID, String relayURL) {
        prepareEncryptedPairing(preferences(context), deviceID, relayURL);
    }

    static void prepareEncryptedPairing(SharedPreferences preferences, String deviceID, String relayURL) {
        String entry = entry(deviceID, relayURL);
        if (preferences.getString(entry, null) == null
                && !preferences.edit().putString(entry, "pending-encrypted-pairing").commit()) {
            throw new IllegalStateException("E2E pairing marker could not be saved");
        }
    }

    static void save(Context context, String deviceID, String relayURL, byte[] key) {
        save(preferences(context), deviceID, relayURL, key);
    }

    static byte[] forRegistration(Context context, JSONObject registration) {
        return forRegistration(preferences(context), registration);
    }

    static boolean remove(Context context, String deviceID, String relayURL) {
        return remove(preferences(context), deviceID, relayURL);
    }

    /** Re-pairing without a key: the old one would seal SMS this iPhone no longer opens. */
    static boolean remove(SharedPreferences preferences, String deviceID, String relayURL) {
        if (deviceID == null || deviceID.trim().isEmpty()) return false;
        String entry = entry(deviceID, relayURL);
        if (preferences.getString(entry, null) == null) return false;
        if (!preferences.edit().remove(entry).commit()) throw new IllegalStateException("E2E key could not be removed");
        return true;
    }

    static void save(SharedPreferences preferences, String deviceID, String relayURL, byte[] key) {
        if (key == null || key.length != 32 || deviceID == null || deviceID.trim().isEmpty()) {
            throw new IllegalArgumentException("invalid E2E key entry");
        }
        String encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(key);
        if (!preferences.edit().putString(entry(deviceID, relayURL), encoded).commit()) {
            throw new IllegalStateException("E2E key could not be saved");
        }
    }

    static byte[] key(SharedPreferences preferences, String deviceID, String relayURL) {
        String stored = preferences.getString(entry(deviceID, relayURL), null);
        if (stored == null) return null;
        try {
            byte[] key = Base64.getUrlDecoder().decode(stored);
            if (key.length != 32) throw new IllegalArgumentException("invalid key length");
            return key;
        } catch (IllegalArgumentException corrupt) {
            throw new IllegalStateException("Stored SMS encryption key is invalid; re-pair before uploading", corrupt);
        }
    }

    /** Null for a local-mode or incomplete registration: its SMS never reach the Relay encrypted. */
    static byte[] forRegistration(SharedPreferences preferences, JSONObject registration) {
        if (registration == null || registration.optBoolean("local_mode", false)) return null;
        String deviceID = registration.optString("device_id", "").trim();
        return deviceID.isEmpty() ? null : key(preferences, deviceID, registration.optString("relay_url", ""));
    }

    private static String entry(String deviceID, String relayURL) {
        String relay = relayURL == null ? "" : relayURL.trim();
        while (relay.endsWith("/")) relay = relay.substring(0, relay.length() - 1);
        return deviceID.trim() + "|" + relay;
    }

    private static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }
}
