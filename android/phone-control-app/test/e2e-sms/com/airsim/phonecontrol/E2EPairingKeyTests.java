package com.airsim.phonecontrol;

import android.content.SharedPreferences;
import java.lang.reflect.Proxy;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONObject;

public final class E2EPairingKeyTests {
    private static int cases;
    private static final byte[] KEY = range(0x00, 32);

    public static void main(String[] args) throws Exception {
        takeRemovesAndReturns();
        avfStripsAndIgnores();
        invalidKeyRejected();
        keyFollowsRegistration();
        capabilitiesAdvertiseE2E();
        System.out.println("E2E pairing key tests passed: " + cases + " cases");
    }

    private static void takeRemovesAndReturns() throws Exception {
        JSONObject registration = new JSONObject().put("device_id", "iphone-air").put("vowlan_secret", "secret")
                .put("e2e_key", base64URL(KEY));
        byte[] key = E2EPairingKey.take(registration, true);
        if (!Arrays.equals(KEY, key)) throw new AssertionError("standalone returns the claim's key");
        equal(false, registration.has("e2e_key"), "key removed before registerPairing");
        equal("secret", registration.getString("vowlan_secret"), "other fields untouched");
        equal(null, E2EPairingKey.take(new JSONObject().put("device_id", "iphone-air"), true), "old iPhone sends no key");
        cases++;
    }

    private static void avfStripsAndIgnores() throws Exception {
        JSONObject registration = new JSONObject().put("device_id", "iphone-air").put("e2e_key", base64URL(KEY));
        equal(null, E2EPairingKey.take(registration, false), "AVF never keeps a key");
        equal(false, registration.has("e2e_key"), "AVF strips the key for the strict Linux Agent");
        cases++;
    }

    private static void invalidKeyRejected() throws Exception {
        for (String invalid : new String[]{base64URL(range(0, 31)), base64URL(range(0, 33)), "not+base64/url", ""}) {
            JSONObject registration = new JSONObject().put("e2e_key", invalid);
            try {
                E2EPairingKey.take(registration, true);
                throw new AssertionError("accepted e2e_key " + invalid);
            } catch (GeneralSecurityException expected) {
                equal(false, registration.has("e2e_key"), "an invalid key is removed too");
            }
        }
        cases++;
    }

    private static void keyFollowsRegistration() throws Exception {
        Map<String, String> values = new HashMap<>();
        SharedPreferences preferences = preferences(values);
        E2EKeyStore.save(preferences, " iphone-air ", "https://relay.example/", KEY);
        if (!Arrays.equals(KEY, E2EKeyStore.key(preferences, "iphone-air", "https://relay.example"))) {
            throw new AssertionError("the key is found under the normalized device and Relay");
        }
        JSONObject registration = new JSONObject().put("device_id", "iphone-air").put("relay_url", "https://relay.example");
        if (!Arrays.equals(KEY, E2EKeyStore.forRegistration(preferences, registration))) {
            throw new AssertionError("the current registration finds its key");
        }
        equal(null, E2EKeyStore.forRegistration(preferences,
                new JSONObject(registration.toString()).put("relay_url", "https://other.example")), "other Relay");
        equal(null, E2EKeyStore.forRegistration(preferences,
                new JSONObject(registration.toString()).put("device_id", "iphone-other")), "other iPhone");
        equal(null, E2EKeyStore.forRegistration(preferences,
                new JSONObject(registration.toString()).put("local_mode", true)), "local mode never encrypts");
        equal(null, E2EKeyStore.forRegistration(preferences, null), "no registration");
        values.replaceAll((entry, stored) -> "not+base64");
        equal(null, E2EKeyStore.forRegistration(preferences, registration), "a corrupt entry is ignored");
        cases++;
    }

    private static void capabilitiesAdvertiseE2E() throws Exception {
        equal("{\"e2e_sms\":1}", E2EPairingKey.capabilities().toString(), "pairing info capabilities");
        cases++;
    }

    static SharedPreferences preferences(Map<String, String> values) {
        SharedPreferences.Editor editor = (SharedPreferences.Editor) Proxy.newProxyInstance(
                SharedPreferences.class.getClassLoader(), new Class<?>[]{SharedPreferences.Editor.class},
                (proxy, method, arguments) -> switch (method.getName()) {
                    case "putString" -> { values.put((String) arguments[0], (String) arguments[1]); yield proxy; }
                    case "remove" -> { values.remove((String) arguments[0]); yield proxy; }
                    case "commit" -> true;
                    case "apply" -> null;
                    default -> throw new UnsupportedOperationException(method.getName());
                });
        return (SharedPreferences) Proxy.newProxyInstance(SharedPreferences.class.getClassLoader(),
                new Class<?>[]{SharedPreferences.class}, (proxy, method, arguments) -> switch (method.getName()) {
                    case "getString" -> values.getOrDefault((String) arguments[0], (String) arguments[1]);
                    case "edit" -> editor;
                    default -> throw new UnsupportedOperationException(method.getName());
                });
    }

    private static String base64URL(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private static byte[] range(int start, int count) {
        byte[] bytes = new byte[count];
        for (int index = 0; index < count; index++) bytes[index] = (byte) (start + index);
        return bytes;
    }

    private static void equal(Object expected, Object actual, String label) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
        }
    }
}
