package com.airsim.phonecontrol;

import android.content.Context;
import android.telecom.Call;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

/** Issued grants only; repeated authentication never extends their lifetime. */
final class WatchMediaSessions {
    private record Issued(WatchMediaGrant grant, java.util.function.BooleanSupplier identityCurrent) {}
    private static final Map<String, Issued> issued = new HashMap<>();
    static synchronized void register(WatchMediaGrant grant, java.util.function.BooleanSupplier identityCurrent) {
        issued.entrySet().removeIf(e -> CallRepository.state(e.getValue().grant.instance)<0
                || System.currentTimeMillis()/1000L >= e.getValue().grant.sessionUntil);
        if (issued.size() >= 64) throw new SecurityException("watch session capacity");
        issued.put(grant.encoded, new Issued(grant, identityCurrent));
    }
    static synchronized void revoke(String encoded) { issued.remove(encoded); }
    static synchronized WatchMediaGrant media(Context context, String encoded, long now, boolean attaching) {
        Issued entry = issued.get(encoded);
        if (entry == null) return null;
        WatchMediaGrant grant = entry.grant;
        boolean identityCurrent;
        try { identityCurrent = entry.identityCurrent.getAsBoolean(); }
        catch (RuntimeException unavailable) { identityCurrent = false; }
        int state = CallRepository.state(grant.instance);
        boolean paired = VoWLANPairingStore.records(context).stream().anyMatch(p -> p.id().equals(grant.owner));
        if (!paired || !identityCurrent || (state != Call.STATE_ACTIVE && state != Call.STATE_HOLDING) || now >= grant.sessionUntil) {
            issued.remove(encoded); return null;
        }
        return now < grant.expiresAt || !attaching ? grant : null;
    }
    static byte[] mediaKey(Context context, WatchMediaGrant grant) {
        for (var parent : VoWLANPairingStore.records(context)) if (parent.id().equals(grant.owner)) {
            byte[] root = parent.secretCopy(), control = WatchMediaGrant.controlKey(root);
            try { return WatchMediaGrant.mediaKey(control, grant.encoded); }
            finally { Arrays.fill(root,(byte)0); Arrays.fill(control,(byte)0); }
        }
        throw new SecurityException("watch parent revoked");
    }
}
