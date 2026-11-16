package com.airsim.phonecontrol;

import org.json.JSONObject;

/** The E2E SMS key only arrives in the sealed pairing claim; a stored registration never keeps it. */
public final class RegistrationE2EKeyTests {
    public static void main(String[] args) throws Exception {
        String key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
        JSONObject local = new JSONObject().put("local_mode", true).put("e2e_key", key);
        StandaloneAgentStore.validateRegistration(local);
        if (local.has("e2e_key")) throw new AssertionError("local registration from /api/push/register keeps e2e_key");
        JSONObject cloud = new JSONObject().put("device_id", "iphone-air").put("device_secret", "s".repeat(32))
                .put("bundle_id", "com.example.airsim").put("environment", "production")
                .put("relay_url", "https://relay.example").put("alert_token", "ab".repeat(32))
                .put("e2e_key", key);
        StandaloneAgentStore.validateRegistration(cloud);
        if (cloud.has("e2e_key")) throw new AssertionError("cloud registration from /api/push/register keeps e2e_key");
        System.out.println("RegistrationE2EKeyTests passed");
    }
}
