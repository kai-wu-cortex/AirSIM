package com.airsim.phonecontrol;

import android.content.Context;
import android.telephony.SmsManager;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Android-only JSON adapter for the paired iPhone's SIM selector. Kept separate
 * from DefaultCallAccount so the JVM account tests do not need org.json.
 * The list is display metadata only; identifiers are opaque Telecom handles and
 * numbers are never logged or persisted by this class.
 */
public final class SimSlotJson {
    private SimSlotJson() {}

    public static JSONArray slots(Context context) {
        JSONArray values = new JSONArray();
        try {
            DefaultCallAccount.Snapshot snapshot = DefaultCallAccount.snapshot(context);
            if (!snapshot.error().isEmpty()) return values;
            String selected = DefaultCallAccount.selectedKey(context);
            for (DefaultCallAccount.Account account : snapshot.accounts()) {
                JSONObject slot = new JSONObject()
                        .put("id", account.key())
                        .put("label", account.label())
                        .put("number", account.number())
                        .put("default", account.key().equals(selected))
                        .put("slot_index", account.slotIndex())
                        .put("sub_id", account.subscriptionId())
                        .put("carrier_name", account.carrierName())
                        .put("is_embedded", account.embedded())
                        .put("is_default_voice", account.defaultVoice())
                        .put("is_default_sms", account.defaultSms()
                                || account.subscriptionId() == SmsManager.getDefaultSmsSubscriptionId());
                JSONObject signal = signal(context, account.subscriptionId());
                if (signal != null) slot.put("signal", signal);
                values.put(slot);
            }
        } catch (RuntimeException | org.json.JSONException ignored) {
            // A missing permission or OEM restriction leaves the selector hidden.
        }
        return values;
    }
    /** Read only this resolved subscription. Never use the default SIM as a fallback. */
    private static JSONObject signal(Context context, int subscriptionId) {
        if (subscriptionId < 0) return null;
        try {
            android.telephony.TelephonyManager manager = context.getSystemService(android.telephony.TelephonyManager.class);
            if (manager == null) return null;
            android.telephony.SignalStrength strength = manager.createForSubscriptionId(subscriptionId).getSignalStrength();
            if (strength == null || strength.getCellSignalStrengths().isEmpty()) return null;
            int level = strength.getLevel();
            if (level < 0 || level > 4) return null;
            long now = System.currentTimeMillis();
            long age = 0;
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                long measured = strength.getTimestampMillis();
                age = android.os.SystemClock.elapsedRealtime() - measured;
                if (measured <= 0 || age < 0 || age >= 300_000) return null;
            }
            // API 29 exposes no measurement timestamp: use retrieval time. Newer
            // systems retain the modem timestamp so an old sample cannot look fresh.
            return new JSONObject().put("level", level).put("observed_at_ms", now - age);
        } catch (RuntimeException | org.json.JSONException ignored) {
            // Optional telemetry; missing permissions/OEM support must not hide SIMs.
            return null;
        }
    }

}
