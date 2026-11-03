package com.airsim.phonecontrol;

import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Strict version-one wire format shared by the authenticated WLAN/BLE and AVF adapters. */
public final class PureLocalModeWire {
    public static PureLocalModeProof.Command command(JSONObject value) throws Exception {
        long version = integer(value, "version");
        if (version != 1) throw new IllegalArgumentException("unsupported_version");
        return new PureLocalModeProof.Command(1, string(value, "agent_id"), string(value, "operation_id"),
                bool(value, "enabled"), integer(value, "expected_revision"),
                string(value, "owner_public_key"), string(value, "signature"));
    }
    public static JSONObject command(PureLocalModeProof.Command c) throws Exception {
        return new JSONObject().put("version", c.version).put("agent_id", c.agentID)
                .put("operation_id", c.operationID).put("enabled", c.enabled)
                .put("expected_revision", c.expectedRevision).put("owner_public_key", c.ownerPublicKey)
                .put("signature", c.signature);
    }
    public static JSONObject status(PureLocalModeCoordinator.Status s) throws Exception {
        return new JSONObject().put("version", s.version).put("agent_id", s.agentID).put("enabled", s.enabled)
                .put("revision", s.revision).put("last_operation_id", s.lastOperationID)
                .put("owner_fingerprint", s.ownerFingerprint).put("source", s.source)
                .put("drained", s.drained).put("avf_required", s.avfRequired).put("avf_confirmed", s.avfConfirmed);
    }
    public static PureLocalModeCoordinator.Status status(JSONObject value) throws Exception {
        if (integer(value, "version") != 1) throw new IllegalArgumentException("unsupported_version");
        String agent = string(value, "agent_id"), operation = string(value, "last_operation_id");
        String owner = string(value, "owner_fingerprint"), source = string(value, "source");
        long revision = integer(value, "revision");
        boolean enabled = bool(value, "enabled"), drained = bool(value, "drained");
        boolean required = bool(value, "avf_required"), confirmed = bool(value, "avf_confirmed");
        if (!PureLocalModeProof.validID(agent) || !("remote".equals(source) || "android_local".equals(source))
                || (revision == 0 ? enabled || !operation.isEmpty() || !owner.isEmpty()
                    : !PureLocalModeProof.validOperation(operation) || !owner.matches("[0-9a-f]{64}"))
                || (drained && required && !confirmed)) throw new IllegalArgumentException("invalid_status");
        var state = new PureLocalModePolicy.State(agent, enabled, revision, owner, operation, source, false);
        return new PureLocalModeCoordinator.Status(new PureLocalModeStore.Record(state, enabled, null, required, null), drained, confirmed);
    }
    public static JSONObject signedStatus(PureLocalModeCoordinator.Status s, String nonce, byte[] secret) throws Exception {
        return status(s).put("status_proof", proof(s, nonce, secret));
    }
    public static boolean verifyStatus(JSONObject value, String nonce, byte[] secret) {
        try {
            byte[] actual = Base64.getDecoder().decode(string(value, "status_proof"));
            byte[] expected = Base64.getDecoder().decode(proof(status(value), nonce, secret));
            return MessageDigest.isEqual(actual, expected);
        } catch (Exception invalid) { return false; }
    }
    private static String proof(PureLocalModeCoordinator.Status s, String nonce, byte[] secret) throws Exception {
        if (nonce == null || nonce.isEmpty() || nonce.getBytes(StandardCharsets.UTF_8).length > 256
                || nonce.contains("\n") || secret == null || secret.length < 16) throw new IllegalArgumentException("invalid_proof_input");
        String canonical = "airsim-pure-local-status-v1\n" + nonce + "\n1\n" + s.agentID + "\n"
                + bit(s.enabled) + "\n" + s.revision + "\n" + s.lastOperationID + "\n" + s.ownerFingerprint
                + "\n" + s.source + "\n" + bit(s.drained) + "\n" + bit(s.avfRequired) + "\n" + bit(s.avfConfirmed);
        Mac mac = Mac.getInstance("HmacSHA256"); mac.init(new SecretKeySpec(secret, "HmacSHA256"));
        return Base64.getEncoder().encodeToString(mac.doFinal(canonical.getBytes(StandardCharsets.UTF_8)));
    }
    private static int bit(boolean value) { return value ? 1 : 0; }
    private static long integer(JSONObject json, String key) throws Exception {
        Object value = json.get(key);
        if (!(value instanceof Integer || value instanceof Long) || ((Number)value).longValue() < 0)
            throw new IllegalArgumentException("invalid_" + key);
        return ((Number)value).longValue();
    }
    private static String string(JSONObject json, String key) throws Exception {
        Object value = json.get(key);
        if (!(value instanceof String)) throw new IllegalArgumentException("invalid_" + key);
        return (String)value;
    }
    private static boolean bool(JSONObject json, String key) throws Exception {
        Object value = json.get(key);
        if (!(value instanceof Boolean)) throw new IllegalArgumentException("invalid_" + key);
        return (Boolean)value;
    }
    private PureLocalModeWire() {}
}
