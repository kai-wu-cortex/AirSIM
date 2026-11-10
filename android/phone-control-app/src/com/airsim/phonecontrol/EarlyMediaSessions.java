package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Authenticated, call-bound receive-only leases. Never authorizes a dial or microphone. */
final class EarlyMediaSessions {
    record Lease(String peer, String agent, String backend, String telecom, String session, long deadline, long expires) {}
    private static final Map<String, Lease> leases = new HashMap<>();
    private EarlyMediaSessions() {}
    static boolean eligible(String id) {
        return CallRepository.isOutgoingDialing(id) && CallRepository.callIDs().size() == 1;
    }
    static synchronized JSONObject grant(Context context, String peer, String backend, String nonce, byte[] secret) throws Exception {
        if (backend.isEmpty() || backend.length() > 128 || backend.contains("\n") || backend.contains("\r")) return null;
        var response = new AgentClient(context).forwardVoWLAN("GET", "/api/calls/status", null);
        if (response.status() != 200) return null;
        JSONObject call = new JSONObject(response.payload()).optJSONObject("active");
        if (call == null || !backend.equals(call.optString("id"))) return null;
        String id = call.optString("android_id");
        if (!eligible(id)) return null;
        long now = System.currentTimeMillis() / 1000L;
        leases.entrySet().removeIf(e -> e.getValue().expires < now - 120);
        String key = peer + "\n" + backend;
        Lease old = leases.get(key);
        if (old != null && (!old.telecom.equals(id) || now >= old.deadline)) return null;
        if (old == null && leases.size() >= 128) return null;
        Lease lease = new Lease(peer, AndroidAgentIdentity.agentID(context), backend, id,
            old == null ? UUID.randomUUID().toString() : old.session,
            old == null ? now + 120 : old.deadline, Math.min(now + 25, old == null ? now + 120 : old.deadline));
        leases.put(key, lease);
        String proof = "AIRSIM-EARLY-MEDIA1\n" + nonce + "\n" + lease.agent + "\n" + backend + "\n" + lease.session
            + "\n" + lease.expires + "\nearly_media\nrecvonly\ns16le-8000-mono";
        return new JSONObject().put("version", 1).put("agent_id", lease.agent).put("call_id", backend)
            .put("session_id", lease.session).put("expires_at", lease.expires).put("state", "early_media")
            .put("direction", "recvonly").put("format", "s16le-8000-mono").put("proof", VoWLANAuth.sign(secret, proof));
    }
    static synchronized Lease resolve(String peer, String binding, long now) {
        String[] f = binding.split("\n", -1);
        if (f.length != 6 || !f[4].equals("recvonly") || !f[5].equals("s16le-8000-mono")) return null;
        Lease lease = leases.get(peer + "\n" + f[1]);
        return lease != null && EarlyMediaLeaseRules.matches(lease.peer, peer, lease.agent, lease.backend,
            lease.session, lease.expires, binding, now, live(lease)) ? lease : null;
    }
    static synchronized boolean live(Lease lease) {
        Lease current = leases.get(lease.peer + "\n" + lease.backend);
        return current != null && current.session.equals(lease.session)
            && System.currentTimeMillis() / 1000L < current.expires && eligible(current.telecom);
    }
    static String binding(String payload) {
        if (payload.length() > 1024) throw new SecurityException("early media payload too large");
        return new String(Base64.getDecoder().decode(payload), StandardCharsets.UTF_8);
    }
}
