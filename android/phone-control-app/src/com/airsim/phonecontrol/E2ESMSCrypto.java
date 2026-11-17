package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * End-to-end encrypted cloud SMS, envelope v1 (issue #24): the Relay only sees {v, kid, n, ct}.
 * Every key derives from the pairing's e2e_key, which only this phone and the iPhone hold.
 */
final class E2ESMSCrypto {
    /** Plaintext cap that keeps the base64url envelope inside a 4096-byte APNs payload. */
    static final int PLAINTEXT_LIMIT = 2400;
    private static final String INFO_PREFIX = "AirSIM-E2E/v1/";
    private static final String AAD_PREFIX = "AirSIM-E2E/v1|incoming_sms|";
    private static final SecureRandom RANDOM = new SecureRandom();

    record Envelope(String kid, String nonce, String ciphertext) {}

    private E2ESMSCrypto() {}

    static Keys keys(byte[] e2eKey) throws GeneralSecurityException {
        if (e2eKey == null || e2eKey.length != 32) throw new GeneralSecurityException("invalid e2e key");
        return new Keys(subkey(e2eKey, "sms-in"), subkey(e2eKey, "delivery-id"),
                hex(subkey(e2eKey, "kid"), 4));
    }

    /** HKDF-SHA256 with a 32-byte zero salt (the RFC 5869 default) and one 32-byte block. */
    static byte[] subkey(byte[] e2eKey, String purpose) throws GeneralSecurityException {
        Mac hmac = Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec(new byte[32], "HmacSHA256"));
        byte[] pseudoRandomKey = hmac.doFinal(e2eKey);
        hmac.init(new SecretKeySpec(pseudoRandomKey, "HmacSHA256"));
        hmac.update((INFO_PREFIX + purpose).getBytes(StandardCharsets.UTF_8));
        hmac.update((byte) 1);
        return hmac.doFinal();
    }

    /** {"sender","content","timestamp","truncated"}; content is cut on code points to fit the cap. */
    static String plaintext(String sender, String content, String timestamp) {
        return plaintext(sender, content, timestamp, null);
    }

    /** The receiving SIM follows the other fields, and only when known, so the plaintext keeps its bytes without it. */
    static String plaintext(String sender, String content, String timestamp, String simSlot) {
        String body = content == null ? "" : content;
        String whole = json(sender, body, timestamp, false, simSlot);
        if (utf8Length(whole) <= PLAINTEXT_LIMIT) return whole;
        int[] points = body.codePoints().toArray();
        String fitted = json(sender, "…", timestamp, true, simSlot);
        int low = 0;
        int high = points.length - 1;
        while (low < high) {
            int middle = (low + high + 1) >>> 1;
            String candidate = json(sender, new String(points, 0, middle) + "…", timestamp, true, simSlot);
            if (utf8Length(candidate) <= PLAINTEXT_LIMIT) {
                fitted = candidate;
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        return fitted;
    }

    static final class Keys {
        private final byte[] smsIn;
        private final byte[] deliveryKey;
        private final String kid;

        private Keys(byte[] smsIn, byte[] deliveryKey, String kid) {
            this.smsIn = smsIn;
            this.deliveryKey = deliveryKey;
            this.kid = kid;
        }

        String kid() { return kid; }

        /** SMSDeliveryIdentity's input, keyed, so the Relay cannot test guesses against the id. */
        String deliveryID(String sender, String body, long timestamp) throws GeneralSecurityException {
            Mac hmac = Mac.getInstance("HmacSHA256");
            hmac.init(new SecretKeySpec(deliveryKey, "HmacSHA256"));
            String source = (sender == null ? "" : sender) + "\0" + timestamp + "\0" + (body == null ? "" : body);
            return "android-sms-" + hex(hmac.doFinal(source.getBytes(StandardCharsets.UTF_8)), 32);
        }

        Envelope seal(String plaintext, String deviceID, String agentID, String deliveryID)
                throws GeneralSecurityException {
            byte[] nonce = new byte[12];
            RANDOM.nextBytes(nonce);
            return seal(plaintext, deviceID, agentID, deliveryID, nonce);
        }

        Envelope seal(String plaintext, String deviceID, String agentID, String deliveryID, byte[] nonce)
                throws GeneralSecurityException {
            if (nonce.length != 12) throw new GeneralSecurityException("invalid nonce");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(smsIn, "AES"), new GCMParameterSpec(128, nonce));
            // Binds the ciphertext to this registration, Agent and SMS.
            cipher.updateAAD((AAD_PREFIX + deviceID + "|" + agentID + "|" + deliveryID)
                    .getBytes(StandardCharsets.UTF_8));
            byte[] sealed = cipher.doFinal(plaintext.getBytes(StandardCharsets.UTF_8));
            return new Envelope(kid, base64URL(nonce), base64URL(sealed));
        }
    }

    private static String json(String sender, String content, String timestamp, boolean truncated, String simSlot) {
        StringBuilder out = new StringBuilder(content.length() + 112);
        out.append("{\"sender\":");
        quote(out, sender);
        out.append(",\"content\":");
        quote(out, content);
        out.append(",\"timestamp\":");
        quote(out, timestamp);
        out.append(",\"truncated\":").append(truncated);
        if (simSlot != null && !simSlot.isEmpty()) {
            out.append(",\"sim_slot\":");
            quote(out, simSlot);
        }
        return out.append('}').toString();
    }

    private static void quote(StringBuilder out, String value) {
        String text = value == null ? "" : value;
        out.append('"');
        for (int index = 0; index < text.length(); index++) {
            char c = text.charAt(index);
            if (c == '"' || c == '\\') out.append('\\').append(c);
            else if (c < 0x20) out.append(String.format("\\u%04x", (int) c));
            else out.append(c);
        }
        out.append('"');
    }

    private static int utf8Length(String text) {
        return text.getBytes(StandardCharsets.UTF_8).length;
    }

    private static String base64URL(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private static String hex(byte[] value, int count) {
        char[] alphabet = "0123456789abcdef".toCharArray();
        StringBuilder out = new StringBuilder(count * 2);
        for (int index = 0; index < count; index++) {
            out.append(alphabet[(value[index] >> 4) & 0x0f]).append(alphabet[value[index] & 0x0f]);
        }
        return out.toString();
    }
}
