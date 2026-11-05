package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONObject;

/** Transport-independent admission; the privileged bridge must prove capture capability. */
public final class AndroidEarlyMedia {
    static final EarlyMediaLeases LEASES = CallRepository.EARLY_MEDIA;
    public static boolean supported(Context context) {
        // This is protocol support, not proof that an OEM exposes carrier audio.
        return RuntimeMode.isStandalone(context);
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
