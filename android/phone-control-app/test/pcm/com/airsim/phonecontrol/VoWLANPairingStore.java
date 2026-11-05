package com.airsim.phonecontrol;
import android.content.Context;
public final class VoWLANPairingStore {
    public static final class Record {
        public String id() { return "test-pairing"; }
        public byte[] secretCopy() { return new byte[32]; }
    }
    public static boolean paired = true;
    public static java.util.List<Record> records(Context ignored) { return paired ? java.util.List.of(new Record()) : java.util.List.of(); }
    public static byte[] load(Context ignored) { return new byte[32]; }
    public static Record match(Context ignored, String signature, String canonical,
                               long timestamp, long now) {
        return paired && VoWLANAuth.verify(new byte[32], signature, canonical, timestamp, now) ? new Record() : null;
    }
}
