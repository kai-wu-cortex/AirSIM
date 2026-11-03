package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters;
import org.bouncycastle.crypto.signers.Ed25519Signer;

/** Versioned ownership proof, in addition to (never instead of) local pairing authentication. */
public final class PureLocalModeProof {
    public static final class Command {
        public final int version;
        public final String agentID, operationID, ownerPublicKey, signature;
        public final boolean enabled;
        public final long expectedRevision;
        public Command(int version, String agentID, String operationID, boolean enabled, long revision, String key, String signature) {
            this.version = version; this.agentID = agentID; this.operationID = operationID;
            this.enabled = enabled; this.expectedRevision = revision; this.ownerPublicKey = key; this.signature = signature;
        }
        byte[] canonical() {
            return ("airsim-pure-local-v1\n" + agentID + "\n" + operationID + "\n" + (enabled ? "1" : "0") + "\n" + expectedRevision).getBytes(StandardCharsets.UTF_8);
        }
    }
    static boolean validID(String id) { return id != null && id.matches("[A-Za-z0-9._:-]{1,128}"); }
    static boolean validOperation(String id) { return id != null && id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"); }
    public static String verify(Command c, String agentID) throws PureLocalModePolicy.Rejected {
        if (c == null || c.version != 1 || !validID(c.agentID) || !c.agentID.equals(agentID)
                || !validOperation(c.operationID) || c.expectedRevision < 0
                || c.ownerPublicKey == null || c.ownerPublicKey.length() != 44
                || c.signature == null || c.signature.length() != 88) throw new PureLocalModePolicy.Rejected("invalid_command");
        try {
            byte[] key = Base64.getDecoder().decode(c.ownerPublicKey), signature = Base64.getDecoder().decode(c.signature);
            if (key.length != 32 || signature.length != 64) throw new IllegalArgumentException();
            Ed25519Signer verifier = new Ed25519Signer(); verifier.init(false, new Ed25519PublicKeyParameters(key, 0));
            byte[] message = c.canonical(); verifier.update(message, 0, message.length);
            if (!verifier.verifySignature(signature)) throw new PureLocalModePolicy.Rejected("invalid_signature");
            StringBuilder hex = new StringBuilder();
            for (byte b : MessageDigest.getInstance("SHA-256").digest(key)) hex.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
            return hex.toString();
        } catch (PureLocalModePolicy.Rejected error) { throw error; }
        catch (Exception error) { throw new PureLocalModePolicy.Rejected("invalid_signature"); }
    }
    private PureLocalModeProof() {}
}
