package com.airsim.phonecontrol;

import android.content.Context;
import android.util.Base64;

import java.util.Arrays;

public final class VoWLANPairingStore {
    private static final String FILE = "vowlan_pairing";
    private static final String SECRET = "secret_v1";

    private VoWLANPairingStore() {}

    public static void saveEncoded(Context context, String encoded) {
        byte[] decoded = decode(encoded);
        try {
            context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
                    .putString(SECRET, Base64.encodeToString(decoded, Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING))
                    .apply();
        } finally {
            Arrays.fill(decoded, (byte) 0);
        }
    }

    public static byte[] load(Context context) {
        String encoded = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getString(SECRET, "");
        if (encoded.isEmpty()) return new byte[0];
        try { return decode(encoded); }
        catch (IllegalArgumentException error) { return new byte[0]; }
    }

    public static boolean configured(Context context) {
        byte[] secret = load(context);
        try { return secret.length >= 32; }
        finally { Arrays.fill(secret, (byte) 0); }
    }

    public static void clear(Context context) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().remove(SECRET).apply();
    }

    private static byte[] decode(String encoded) {
        byte[] value = Base64.decode(encoded, Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING);
        if (value.length < 32) {
            Arrays.fill(value, (byte) 0);
            throw new IllegalArgumentException("VoWLAN secret too short");
        }
        return value;
    }
}
