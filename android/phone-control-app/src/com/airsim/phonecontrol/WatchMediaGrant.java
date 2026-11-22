package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.UUID;
import org.json.JSONObject;

/** Immutable issued grant. Never interpret a client supplied grant as authority. */
final class WatchMediaGrant {
    final String owner, agent, call, uuid, instance, encoded;
    final long generation, expiresAt, sessionUntil;
    WatchMediaGrant(String owner, String agent, String call, String uuid, long generation,
                    String instance, long now) throws Exception {
        this.owner = owner; this.agent = agent; this.call = call; this.uuid = uuid;
        this.generation = generation; this.instance = instance;
        expiresAt = now + 60; sessionUntil = now + 14_400;
        encoded = encode(new JSONObject().put("owner", owner).put("agent_id", agent)
                .put("call_id", call).put("call_uuid", uuid).put("generation", generation)
                .put("instance", instance).put("session", UUID.randomUUID().toString())
                .put("expires_at", expiresAt).put("session_until", sessionUntil).toString());
    }
    boolean permits(String owner, String agent, String call, String uuid, long generation,
                    String instance, long now, boolean attaching) {
        return this.owner.equals(owner) && this.agent.equals(agent) && this.call.equals(call)
                && this.uuid.equals(uuid) && this.generation == generation && this.instance.equals(instance)
                && now < sessionUntil && (!attaching || now < expiresAt);
    }
    static byte[] controlKey(byte[] root) { return decode(VoWLANAuth.sign(root, "AirSIM/watch-call-only/v2")); }
    static byte[] mediaKey(byte[] control, String grant) { return decode(VoWLANAuth.sign(control, "watch-media-v2\n" + grant)); }
    static String pcmCanonical(String grant, long timestamp, String nonce) {
        return "watch-pcm-v2\n" + grant + "\n" + timestamp + "\n" + nonce;
    }
    static String responseCanonical(String nonce, int status, String payload) {
        return "watch-response-v2\n" + nonce + "\n" + status + "\n" + payload;
    }
    static String encode(String value) { return Base64.getUrlEncoder().withoutPadding().encodeToString(value.getBytes(StandardCharsets.UTF_8)); }
    static byte[] decode(String value) { return Base64.getUrlDecoder().decode(value); }
}
