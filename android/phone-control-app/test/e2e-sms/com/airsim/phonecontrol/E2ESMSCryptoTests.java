package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.Base64;
import java.util.HexFormat;
import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class E2ESMSCryptoTests {
    private static int cases;
    // Reference vectors computed independently with Node crypto (hkdfSync, createHmac, aes-256-gcm).
    private static final byte[] KEY = range(0x00, 32);
    private static final String SMS_IN = "51df33def69dff3879fd25f082b96f4c53edbf4bf66ca06d9c29da22d0bddd59";
    private static final String DELIVERY_KEY = "0601e5c4ad1cb5cbbfa95c8f803a4458aee98c35d05078f03367f813d505a1ab";
    private static final String KID = "3946e215";
    private static final String DELIVERY_ID =
            "android-sms-ff317720dfc84a7be3125b7af8e2f3f5a0351aba73f515b48d111eb126fc0394";
    private static final String PLAINTEXT = "{\"sender\":\"95588\",\"content\":\"【银行】验证码 123456\","
            + "\"timestamp\":\"2024-10-27T03:33:20Z\",\"truncated\":false}";
    private static final String NONCE = "oKGio6Slpqeoqaqr";
    private static final String CIPHERTEXT = "G1bqIzAQqg49db6t2KX7AlFUmc4-J3ZRnP7zb16Y_jFW4Cr0qQSX_TCq8X4GU6j4XMzwmOC"
            + "jBcJ5K1JRWBhrTEZXOH73vi8utyUL4PvZeT18QcVa6VhqzCsLIG94qPMrIVx_7zyWui8P6JZ2uWzOwJznSOxpekWaZ8mRet4v9oo";
    private static final String AAD = "AirSIM-E2E/v1|incoming_sms|iphone-air|android-A|" + DELIVERY_ID;

    public static void main(String[] args) throws Exception {
        vectorsMatchNode();
        plaintextIsExact();
        truncatesOnCodePoints();
        sealRoundTrips();
        System.out.println("E2E SMS crypto tests passed: " + cases + " cases");
    }

    private static void vectorsMatchNode() throws Exception {
        equal(SMS_IN, HexFormat.of().formatHex(E2ESMSCrypto.subkey(KEY, "sms-in")), "sms-in subkey");
        equal(DELIVERY_KEY, HexFormat.of().formatHex(E2ESMSCrypto.subkey(KEY, "delivery-id")), "delivery-id subkey");
        E2ESMSCrypto.Keys keys = E2ESMSCrypto.keys(KEY);
        equal(KID, keys.kid(), "kid");
        equal(DELIVERY_ID, keys.deliveryID("95588", "【银行】验证码 123456", 1730000000000L), "keyed delivery id");
        E2ESMSCrypto.Envelope envelope = keys.seal(PLAINTEXT, "iphone-air", "android-A", DELIVERY_ID, range(0xa0, 12));
        equal(KID, envelope.kid(), "envelope kid");
        equal(NONCE, envelope.nonce(), "envelope nonce");
        equal(CIPHERTEXT, envelope.ciphertext(), "envelope ciphertext");
        try {
            E2ESMSCrypto.keys(range(0x00, 31));
            throw new AssertionError("a 31-byte key must be rejected");
        } catch (GeneralSecurityException expected) { /* rejected */ }
        cases++;
    }

    private static void plaintextIsExact() {
        equal(PLAINTEXT, E2ESMSCrypto.plaintext("95588", "【银行】验证码 123456", "2024-10-27T03:33:20Z"),
                "vector plaintext");
        equal("{\"sender\":\"s\",\"content\":\"a\\\"b\\\\c\\u000ad\\u0001\",\"timestamp\":\"t\",\"truncated\":false}",
                E2ESMSCrypto.plaintext("s", "a\"b\\c\nd\u0001", "t"), "escaping");
        equal("{\"sender\":\"\",\"content\":\"\",\"timestamp\":\"t\",\"truncated\":false}",
                E2ESMSCrypto.plaintext(null, null, "t"), "null fields become empty strings");
        // The receiving SIM (PR #29) is sealed after the other fields; without one the bytes stay the vector's.
        equal("{\"sender\":\"95588\",\"content\":\"x\",\"timestamp\":\"t\",\"truncated\":false,\"sim_slot\":\"SIM 2\"}",
                E2ESMSCrypto.plaintext("95588", "x", "t", "SIM 2"), "sim_slot");
        equal(PLAINTEXT, E2ESMSCrypto.plaintext("95588", "【银行】验证码 123456", "2024-10-27T03:33:20Z", ""),
                "an empty sim_slot is left out");
        equal(PLAINTEXT, E2ESMSCrypto.plaintext("95588", "【银行】验证码 123456", "2024-10-27T03:33:20Z", null),
                "a missing sim_slot is left out");
        cases++;
    }

    private static void truncatesOnCodePoints() {
        for (String unit : new String[]{"短", "😀"}) {
            String text = E2ESMSCrypto.plaintext("95588", unit.repeat(1000), "2024-10-27T03:33:20Z");
            int bytes = text.getBytes(StandardCharsets.UTF_8).length;
            if (bytes > E2ESMSCrypto.PLAINTEXT_LIMIT || bytes < E2ESMSCrypto.PLAINTEXT_LIMIT - 4) {
                throw new AssertionError(unit + " plaintext is " + bytes + " bytes, not the longest fit");
            }
            if (!text.endsWith("…\",\"timestamp\":\"2024-10-27T03:33:20Z\",\"truncated\":true}")) {
                throw new AssertionError(unit + " plaintext does not end with an ellipsis and truncated=true");
            }
            if (text.codePoints().anyMatch(point -> point >= 0xD800 && point <= 0xDFFF)) {
                throw new AssertionError(unit + " plaintext contains a lone surrogate");
            }
        }
        if (!E2ESMSCrypto.plaintext("95588", "余额提醒", "t").endsWith("\"truncated\":false}")) {
            throw new AssertionError("a short SMS must not be marked truncated");
        }
        String withSlot = E2ESMSCrypto.plaintext("95588", "短".repeat(1000), "2024-10-27T03:33:20Z", "SIM 2");
        if (withSlot.getBytes(StandardCharsets.UTF_8).length > E2ESMSCrypto.PLAINTEXT_LIMIT
                || !withSlot.endsWith("\"truncated\":true,\"sim_slot\":\"SIM 2\"}")) {
            throw new AssertionError("the SIM slot must fit inside the limit and survive truncation");
        }
        cases++;
    }

    private static void sealRoundTrips() throws Exception {
        E2ESMSCrypto.Keys keys = E2ESMSCrypto.keys(KEY);
        E2ESMSCrypto.Envelope first = keys.seal(PLAINTEXT, "iphone-air", "android-A", DELIVERY_ID);
        E2ESMSCrypto.Envelope second = keys.seal(PLAINTEXT, "iphone-air", "android-A", DELIVERY_ID);
        equal(PLAINTEXT, open(first, AAD), "random-nonce envelope opens");
        if (first.nonce().equals(second.nonce()) || first.ciphertext().equals(second.ciphertext())) {
            throw new AssertionError("two seals of one plaintext must differ");
        }
        for (String other : new String[]{
                "AirSIM-E2E/v1|incoming_sms|iphone-other|android-A|" + DELIVERY_ID,
                "AirSIM-E2E/v1|incoming_sms|iphone-air|android-B|" + DELIVERY_ID,
                "AirSIM-E2E/v1|incoming_sms|iphone-air|android-A|android-sms-other"}) {
            try {
                open(first, other);
                throw new AssertionError("envelope opened under " + other);
            } catch (AEADBadTagException expected) { /* bound to its AAD */ }
        }
        cases++;
    }

    private static String open(E2ESMSCrypto.Envelope envelope, String aad) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(HexFormat.of().parseHex(SMS_IN), "AES"),
                new GCMParameterSpec(128, Base64.getUrlDecoder().decode(envelope.nonce())));
        cipher.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
        return new String(cipher.doFinal(Base64.getUrlDecoder().decode(envelope.ciphertext())), StandardCharsets.UTF_8);
    }

    private static byte[] range(int start, int count) {
        byte[] bytes = new byte[count];
        for (int index = 0; index < count; index++) bytes[index] = (byte) (start + index);
        return bytes;
    }

    private static void equal(Object expected, Object actual, String label) {
        if (!expected.equals(actual)) throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
    }
}
