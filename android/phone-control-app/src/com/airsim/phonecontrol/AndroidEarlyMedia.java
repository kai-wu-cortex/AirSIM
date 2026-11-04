package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Build;
import org.json.JSONObject;

/** Experimental Redmi 9 WLAN downlink; no cloud/AVF/global microphone fallback. */
final class AndroidEarlyMedia {
    static final EarlyMediaLeases LEASES = CallRepository.EARLY_MEDIA;
    static boolean supported(Context context) {
        return RuntimeMode.isStandalone(context) && "lancelot".equalsIgnoreCase(Build.DEVICE)
            && "mt6768".equalsIgnoreCase(Build.HARDWARE)
            && ("xiaomi".equalsIgnoreCase(Build.MANUFACTURER) || "redmi".equalsIgnoreCase(Build.MANUFACTURER));
    }
    static String response(EarlyMediaLeases.Grant g, String nonce, byte[] secret) throws Exception {
        return new JSONObject().put("version",1).put("agent_id",g.agent()).put("call_id",g.call())
            .put("session_id",g.session()).put("expires_at",g.expires()).put("state","early_media")
            .put("direction","recvonly").put("format","s16le-8000-mono")
            .put("proof",VoWLANAuth.sign(secret,g.proof(nonce))).toString();
    }
    static boolean paired(Context context, String id) {
        return VoWLANPairingStore.records(context).stream().anyMatch(r -> r.id().equals(id));
    }
}
