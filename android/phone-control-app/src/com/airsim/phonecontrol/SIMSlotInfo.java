package com.airsim.phonecontrol;

import android.telecom.PhoneAccountHandle;
import org.json.JSONException;
import org.json.JSONObject;

public record SIMSlotInfo(
        int slotIndex,
        int subscriptionId,
        String carrierName,
        String displayName,
        String number,
        String countryIso,
        boolean isEmbedded,
        boolean isDefaultVoice,
        boolean isDefaultSms,
        String simState,
        PhoneAccountHandle accountHandle
) {
    public SIMSlotInfo(
            int slotIndex,
            int subscriptionId,
            String carrierName,
            String displayName,
            String number,
            String countryIso,
            boolean isEmbedded,
            boolean isDefaultVoice,
            boolean isDefaultSms,
            PhoneAccountHandle accountHandle
    ) {
        this(slotIndex, subscriptionId, carrierName, displayName, number, countryIso,
                isEmbedded, isDefaultVoice, isDefaultSms, "ready", accountHandle);
    }

    public JSONObject toJSON() {
        JSONObject json = new JSONObject();
        try {
            json.put("slot_index", slotIndex);
            json.put("sub_id", subscriptionId);
            json.put("carrier_name", carrierName == null ? "" : carrierName);
            json.put("display_name", displayName == null ? "" : displayName);
            json.put("number", number == null ? "" : number);
            json.put("country_iso", countryIso == null ? "" : countryIso);
            json.put("is_embedded", isEmbedded);
            json.put("is_default_voice", isDefaultVoice);
            json.put("is_default_sms", isDefaultSms);
            json.put("sim_state", simState == null ? "unknown" : simState);
        } catch (JSONException ignored) {}
        return json;
    }
}
