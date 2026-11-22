package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Same delivery key for the SMS broadcast and the optional inbox fallback. */
final class SMSDeliveryIdentity {
    private SMSDeliveryIdentity() {}

    static long providerTimestamp(long sentAt, long receivedAt) {
        return sentAt > 0 ? sentAt : receivedAt;
    }

    /** Keyed once the cloud registration has an E2E key, so the Relay cannot test guesses against the id. */
    static String id(byte[] e2eKey, String sender, String body, long timestamp) throws Exception {
        return e2eKey == null ? id(sender, body, timestamp)
                : E2ESMSCrypto.keys(e2eKey).deliveryID(sender, body, timestamp);
    }

    static String id(String sender, String body, long timestamp) throws Exception {
        String source = (sender == null ? "" : sender) + "\0" + timestamp + "\0"
                + (body == null ? "" : body);
        byte[] hash = MessageDigest.getInstance("SHA-256")
                .digest(source.getBytes(StandardCharsets.UTF_8));
        char[] alphabet = "0123456789abcdef".toCharArray();
        StringBuilder result = new StringBuilder("android-sms-");
        for (byte value : hash) {
            result.append(alphabet[(value >> 4) & 0x0f]);
            result.append(alphabet[value & 0x0f]);
        }
        return result.toString();
    }
}
