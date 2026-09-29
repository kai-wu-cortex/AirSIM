package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class VoWLANAuth {
    public static final long CLOCK_SKEW_SECONDS = 30;

    private VoWLANAuth() {}

    public static String canonicalRequest(
            String method, String pathAndQuery, byte[] body, long timestamp, String nonce) {
        return method.toUpperCase() + "\n" + pathAndQuery + "\n" + hex(sha256(body))
                + "\n" + timestamp + "\n" + nonce;
    }

    public static String sign(byte[] secret, String canonical) {
        if (secret == null || secret.length < 32) throw new IllegalArgumentException("VoWLAN secret too short");
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret, "HmacSHA256"));
            return Base64.getUrlEncoder().withoutPadding().encodeToString(
                    mac.doFinal(canonical.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception error) {
            throw new IllegalStateException("VoWLAN HMAC unavailable", error);
        }
    }

    public static boolean verify(
            byte[] secret, String suppliedSignature, String canonical,
            long timestamp, long now) {
        if (Math.abs(now - timestamp) > CLOCK_SKEW_SECONDS || suppliedSignature == null) return false;
        byte[] expected = sign(secret, canonical).getBytes(StandardCharsets.US_ASCII);
        byte[] supplied = suppliedSignature.getBytes(StandardCharsets.US_ASCII);
        return MessageDigest.isEqual(expected, supplied);
    }

    private static byte[] sha256(byte[] value) {
        try { return MessageDigest.getInstance("SHA-256").digest(value == null ? new byte[0] : value); }
        catch (Exception error) { throw new IllegalStateException("SHA-256 unavailable", error); }
    }

    private static String hex(byte[] value) {
        StringBuilder output = new StringBuilder(value.length * 2);
        for (byte item : value) output.append(String.format("%02x", item & 0xff));
        return output.toString();
    }
}
