package com.airsim.phonecontrol;

import android.content.Context;
import android.telecom.Call;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;

/** Incoming Watch v2 only. Does not alter the iPhone, BLE, cloud or early-media lanes. */
final class WatchDirectGateway {
    record Reply(int status, String body) {}
    static final class Entry {
        final String owner, agent, call, uuid, instance;
        final long generation;
        boolean answerAttempted;
        WatchMediaGrant grant;
        Entry(String owner, JSONObject input, String instance) {
            this.owner = owner; agent = input.optString("agent_id"); call = input.optString("call_id");
            uuid = input.optString("call_uuid"); generation = input.optLong("generation"); this.instance = instance;
        }
        boolean matches(String parent, JSONObject input) {
            return owner.equals(parent) && agent.equals(input.optString("agent_id"))
                    && call.equals(input.optString("call_id")) && uuid.equals(input.optString("call_uuid"))
                    && generation == input.optLong("generation");
        }
    }
    private static final Map<String, Entry> entries = new LinkedHashMap<>();
    private static final VoWLANReplayCache replay = new VoWLANReplayCache(30);
    private WatchDirectGateway() {}

    static Reply handle(Context context, String method, String path, Map<String,String> headers, byte[] body) throws Exception {
        if (!RuntimeMode.isStandalone(context)) return new Reply(404, "{}");
        if (!"POST".equals(method) || !java.util.Set.of("/api/watch/status", "/api/watch/answer", "/api/watch/hangup").contains(path))
            return new Reply(404, "{}");
        if (!"2".equals(headers.get("x-airsim-watch-control")) || !"1".equals(headers.get("x-airsim-vowlan-version")))
            return new Reply(401, "{}");
        long now = System.currentTimeMillis()/1000L;
        long timestamp = Long.parseLong(headers.getOrDefault("x-airsim-vowlan-timestamp", "0"));
        String nonce = headers.getOrDefault("x-airsim-vowlan-nonce", "");
        String signature = headers.getOrDefault("x-airsim-vowlan-signature", "");
        String canonical = VoWLANAuth.canonicalRequest(method, path, body, timestamp, nonce);
        for (var parent : VoWLANPairingStore.records(context)) {
            byte[] root = parent.secretCopy(); byte[] key = WatchMediaGrant.controlKey(root); Arrays.fill(root, (byte)0);
            try {
                if (!VoWLANAuth.verify(key, signature, canonical, timestamp, now)) continue;
                if (nonce.isEmpty() || !replay.accept(nonce, now)) return new Reply(401, "{}");
                JSONObject input = new JSONObject(new String(body, java.nio.charset.StandardCharsets.UTF_8));
                int status = 200;
                JSONObject result;
                try { result = process(context, path, parent.id(), input, now); }
                catch (SecurityException stale) { status = 409; result = new JSONObject().put("state", "unknown").put("error", "call_identity_or_owner_changed"); }
                result.put("version", 2);
                for (String field : new String[]{"agent_id","call_id","call_uuid","generation"}) result.put(field, input.opt(field));
                String payload = WatchMediaGrant.encode(result.toString());
                return new Reply(status, new JSONObject().put("payload", payload)
                        .put("proof", VoWLANAuth.sign(key, WatchMediaGrant.responseCanonical(nonce, status, payload))).toString());
            } finally { Arrays.fill(key, (byte)0); }
        }
        return new Reply(401, "{}");
    }

    private static synchronized JSONObject process(Context context, String path, String owner, JSONObject input, long now) throws Exception {
        String id = input.optString("call_id"), uuid = input.optString("call_uuid");
        if (!AndroidAgentIdentity.agentID(context).equals(input.optString("agent_id")) || id.isEmpty() || id.length()>128
                || !uuid.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
                || !(input.opt("generation") instanceof Integer || input.opt("generation") instanceof Long) || input.optLong("generation") <= 0
                || input.optDouble("generation") != input.optLong("generation")) throw new SecurityException();
        Entry exact = entries.values().stream().filter(e -> e.matches(owner, input)).findFirst().orElse(null);
        if (exact == null) {
            // Resolve push UUID + generation atomically in the backend, not an id-only status lookup.
            var response = new AgentClient(context).forwardVoWLAN("POST", "/api/calls/resolve", input.toString());
            JSONObject active = new JSONObject(response.payload()).optJSONObject("active");
            if (response.status()!=200 || active==null || !"incoming".equals(active.optString("direction"))) throw new SecurityException();
            String instance = active.optString("android_id");
            if (instance.isEmpty() || CallRepository.state(instance) < 0) throw new SecurityException();
            exact = new Entry(owner, input, instance);
            // Keep status observations separate from an exclusive answer claim.
            if (entries.size() >= 64) {
                entries.entrySet().removeIf(e -> CallRepository.state(e.getValue().instance)<0);
                if (entries.size() >= 64) throw new SecurityException();
            }
            entries.put(owner+":"+exact.agent+":"+exact.call+":"+uuid+":"+exact.generation, exact);
        }
        int state = CallRepository.state(exact.instance);
        if (state != Call.STATE_DISCONNECTED && state >= 0 && !exact.instance.equals(
                StandaloneCloudMediaManager.get(context).androidCallIDFor(input))) throw new SecurityException();
        if ("/api/watch/answer".equals(path)) {
            if (!exact.answerAttempted) {
                if (state != Call.STATE_RINGING) throw new SecurityException();
                for (Entry e : entries.values()) if (e != exact && e.instance.equals(exact.instance) && e.answerAttempted) throw new SecurityException();
                exact.answerAttempted = true; // Never repeat an uncertain native answer.
                CallRepository.ActionResult result = CallRepository.answerForWatch(exact.instance);
                if (!result.success) throw new SecurityException();
            }
            state = CallRepository.state(exact.instance);
            if (state == Call.STATE_ACTIVE || state == Call.STATE_HOLDING) {
                if (exact.grant == null) {
                    exact.grant = new WatchMediaGrant(owner, exact.agent, exact.call, exact.uuid, exact.generation, exact.instance, now);
                    String instance = exact.instance;
                    JSONObject identity = new JSONObject(input.toString());
                    WatchMediaSessions.register(exact.grant, () -> instance.equals(
                            StandaloneCloudMediaManager.get(context).androidCallIDFor(identity)));
                }
                return new JSONObject().put("state", "active").put("grant", exact.grant.encoded);
            }
        } else if ("/api/watch/hangup".equals(path)) {
            // Reject a ringing call; an established call can only be ended by its Watch owner.
            for (Entry e : entries.values()) if (e != exact && e.instance.equals(exact.instance) && e.answerAttempted)
                throw new SecurityException();
            if (state == Call.STATE_RINGING || ((state==Call.STATE_ACTIVE || state==Call.STATE_HOLDING) && exact.answerAttempted)) {
                CallRepository.execute(context, new AgentCommand("watch:"+uuid, "end", exact.instance, ""));
                state = CallRepository.state(exact.instance);
            } else if (state == Call.STATE_ACTIVE || state == Call.STATE_HOLDING) throw new SecurityException();
        }
        String wire = switch (state) {
            case Call.STATE_RINGING -> "incoming";
            case Call.STATE_ACTIVE, Call.STATE_HOLDING -> "active";
            case Call.STATE_DISCONNECTED, -1 -> "ended";
            default -> "connecting";
        };
        if ("ended".equals(wire) && exact.grant != null) { WatchMediaSessions.revoke(exact.grant.encoded); exact.grant = null; }
        return new JSONObject().put("state", wire);
    }

}
