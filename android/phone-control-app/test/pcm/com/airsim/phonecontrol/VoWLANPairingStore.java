package com.airsim.phonecontrol;
import android.content.Context;
public final class VoWLANPairingStore {
    public static final class Record {
        public String id() { return "test-pairing"; }
        public byte[] secretCopy() { return new byte[32]; }
    }
    public static byte[] load(Context ignored) { return new byte[32]; }
    public static Record match(Context ignored, String signature, String canonical,
                               long timestamp, long now) {
        return signature == null || signature.isEmpty() ? null : new Record();
    }
}
