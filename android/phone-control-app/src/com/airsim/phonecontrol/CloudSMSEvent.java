package com.airsim.phonecontrol;

import org.json.JSONObject;

/** One /v1/events/sms body: today's plaintext without an E2E key, an envelope only with one (issue #24). */
final class CloudSMSEvent {
    private CloudSMSEvent() {}

    /** With keys, a failure to seal throws: an SMS of a keyed registration is never uploaded in plaintext. */
    static JSONObject body(JSONObject identity, JSONObject source, String timestamp, E2ESMSCrypto.Keys keys)
            throws Exception {
        String deliveryID = source.optString("delivery_id");
        JSONObject body = identity.put("event", "incoming_sms").put("delivery_id", deliveryID);
        if (keys == null) {
            return body.put("sender", source.optString("sender")).put("content", source.optString("content"))
                    .put("sim_slot", source.optString("sim_slot")).put("timestamp", timestamp);
        }
        // The receiving SIM goes inside the envelope too: the Relay learns nothing about the SMS.
        String plaintext = E2ESMSCrypto.plaintext(source.optString("sender"), source.optString("content"), timestamp,
                source.optString("sim_slot"));
        E2ESMSCrypto.Envelope envelope = keys.seal(plaintext, identity.getString("device_id"),
                identity.getString("agent_id"), deliveryID);
        return body.put("timestamp", timestamp).put("e2e", new JSONObject().put("v", 1)
                .put("kid", envelope.kid()).put("n", envelope.nonce()).put("ct", envelope.ciphertext()));
    }
}
