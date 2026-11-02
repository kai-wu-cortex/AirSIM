package com.airsim.phonecontrol;

import java.security.GeneralSecurityException;
import java.util.Base64;

import org.json.JSONException;
import org.json.JSONObject;

/** The iPhone's E2E SMS key travels only inside the sealed pairing claim (issue #24). */
final class E2EPairingKey {
    private E2EPairingKey() {}

    /** Always removes e2e_key; returns it only to the Standalone Agent, the one that can use it. */
    static byte[] take(JSONObject registration, boolean standalone) throws GeneralSecurityException {
        Object value = registration.remove("e2e_key");
        if (!standalone || value == null) return null;
        if (!(value instanceof String text) || text.isEmpty()) throw new GeneralSecurityException("invalid e2e_key");
        byte[] key;
        try {
            key = Base64.getUrlDecoder().decode(text);
        } catch (IllegalArgumentException malformed) {
            throw new GeneralSecurityException("invalid e2e_key");
        }
        if (key.length != 32) throw new GeneralSecurityException("invalid e2e_key");
        return key;
    }

    /** Advertised in GET /pair/v1/info so the iPhone only sends a key to an Agent that keeps it. */
    static JSONObject capabilities() throws JSONException {
        return new JSONObject().put("e2e_sms", 1);
    }
}
