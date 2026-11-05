package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.HexFormat;
import java.util.TreeSet;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONObject;

public final class CloudSMSEventTests {
    private static int cases;
    private static final byte[] KEY = new byte[32];
    static {
        for (int index = 0; index < KEY.length; index++) KEY[index] = (byte) index;
    }
    private static final String SMS_IN = "51df33def69dff3879fd25f082b96f4c53edbf4bf66ca06d9c29da22d0bddd59";
    private static final String TIMESTAMP = "2024-10-27T03:33:20Z";

    public static void main(String[] args) throws Exception {
        plaintextWithoutKey();
        encryptedHasNoPlaintext();
        noPlaintextFallback();
        deliveryIDFollowsKey();
        System.out.println("Cloud SMS event tests passed: " + cases + " cases");
    }

    private static void plaintextWithoutKey() throws Exception {
        JSONObject body = CloudSMSEvent.body(identity(), source(), TIMESTAMP, null);
        equal("[agent_id, content, delivery_id, device_id, device_secret, event, sender, sim_slot, timestamp]",
                new TreeSet<>(body.keySet()).toString(), "plaintext body fields stay as today");
        equal("95588", body.getString("sender"), "sender");
        equal("SIM 2", body.getString("sim_slot"), "the receiving SIM (PR #29)");
        equal("【银行】验证码 123456", body.getString("content"), "content");
        equal(TIMESTAMP, body.getString("timestamp"), "timestamp");
        equal("incoming_sms", body.getString("event"), "event");
        cases++;
    }

    private static void encryptedHasNoPlaintext() throws Exception {
        JSONObject body = CloudSMSEvent.body(identity(), source(), TIMESTAMP, E2ESMSCrypto.keys(KEY));
        equal("[agent_id, delivery_id, device_id, device_secret, e2e, event, timestamp]",
                new TreeSet<>(body.keySet()).toString(), "encrypted body has no sender, content or code");
        if (body.toString().contains("95588") || body.toString().contains("123456")) {
            throw new AssertionError("plaintext leaked into the encrypted body");
        }
        JSONObject e2e = body.getJSONObject("e2e");
        equal(1, e2e.getInt("v"), "envelope version");
        equal("3946e215", e2e.getString("kid"), "envelope kid");
        String aad = "AirSIM-E2E/v1|incoming_sms|iphone-air|android-A|" + source().getString("delivery_id");
        equal(E2ESMSCrypto.plaintext("95588", "【银行】验证码 123456", TIMESTAMP), open(e2e, aad),
                "the envelope opens to the plaintext of this SMS and timestamp");
        cases++;
    }

    private static void noPlaintextFallback() throws Exception {
        JSONObject withoutAgent = identity();
        withoutAgent.remove("agent_id");
        try {
            CloudSMSEvent.body(withoutAgent, source(), TIMESTAMP, E2ESMSCrypto.keys(KEY));
            throw new AssertionError("an SMS that cannot be sealed must not produce a body");
        } catch (org.json.JSONException expected) { /* stays pending, never plaintext */ }
        cases++;
    }

    private static void deliveryIDFollowsKey() throws Exception {
        equal("android-sms-ff317720dfc84a7be3125b7af8e2f3f5a0351aba73f515b48d111eb126fc0394",
                SMSDeliveryIdentity.id(KEY, "95588", "【银行】验证码 123456", 1730000000000L), "keyed id (Node vector)");
        equal("android-sms-56ade2bc830c126252281aee319d5eda590b56518ebcbec623697999554c5b00",
                SMSDeliveryIdentity.id((byte[]) null, "+8613800000000", "验证码 123456", 1_000L),
                "without a key the id is today's SHA-256 id");
        cases++;
    }

    private static JSONObject identity() throws Exception {
        return new JSONObject().put("device_id", "iphone-air").put("agent_id", "android-A")
                .put("device_secret", "s".repeat(32));
    }

    private static JSONObject source() throws Exception {
        return new JSONObject().put("delivery_id", "android-sms-ff317720dfc84a7be3125b7af8e2f3f5a0351aba73f515b48d111eb126fc0394")
                .put("sender", "95588").put("content", "【银行】验证码 123456").put("timestamp", "2024-10-27T03:33:20.000Z")
                .put("sim_slot", "SIM 2");
    }

    private static String open(JSONObject e2e, String aad) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(HexFormat.of().parseHex(SMS_IN), "AES"),
                new GCMParameterSpec(128, Base64.getUrlDecoder().decode(e2e.getString("n"))));
        cipher.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
        return new String(cipher.doFinal(Base64.getUrlDecoder().decode(e2e.getString("ct"))), StandardCharsets.UTF_8);
    }

    private static void equal(Object expected, Object actual, String label) {
        if (!expected.equals(actual)) throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
    }
}
