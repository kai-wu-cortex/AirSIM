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

    private static final android.os.Handler SIGNAL_MAIN = new android.os.Handler(android.os.Looper.getMainLooper());
    private static final java.util.Map<Integer, SubscriptionSignal> SIGNALS = new java.util.HashMap<>();
    private static boolean observing;
    private static final java.util.concurrent.atomic.AtomicBoolean refreshPending = new java.util.concurrent.atomic.AtomicBoolean();

    private static final class SubscriptionSignal {
        final android.telephony.TelephonyManager manager;
        android.telephony.PhoneStateListener listener;
        JSONObject sample;
        SubscriptionSignal(android.telephony.TelephonyManager manager) { this.manager = manager; }
    }

    /** Lifecycle-owned, per-subscription listeners also receive non-default SIM updates. */
    static synchronized void startSignals(Context context) {
        observing = true;
        refreshSignals(context);
    }

    private static void refreshSignals(Context context) {
        if (!refreshPending.compareAndSet(false, true)) return;
        SIGNAL_MAIN.post(() -> {
            refreshPending.set(false);
            synchronizeSignals(context);
        });
    }

    @SuppressWarnings("deprecation")
    private static synchronized void synchronizeSignals(Context context) {
        if (!observing) return;
        var snapshot = DefaultCallAccount.snapshot(context);
        var wanted = new java.util.HashSet<Integer>();
        for (var account : snapshot.accounts()) if (account.subscriptionId() >= 0) wanted.add(account.subscriptionId());
        for (int id : new java.util.ArrayList<>(SIGNALS.keySet())) {
            if (!wanted.contains(id)) removeSignal(id);
        }
        var base = context.getSystemService(android.telephony.TelephonyManager.class);
        if (base == null) return;
        for (int id : wanted) {
            if (SIGNALS.containsKey(id)) continue;
            try {
                var scoped = base.createForSubscriptionId(id);
                if (scoped == null) continue;
                var entry = new SubscriptionSignal(scoped);
                // Construct on the main looper for API 29 compatibility. listen()
                // scopes this listener to the TelephonyManager's exact subscription.
                entry.listener = new android.telephony.PhoneStateListener() {
                    @Override public void onSignalStrengthsChanged(android.telephony.SignalStrength strength) {
                        synchronized (SimSlotJson.class) {
                            if (SIGNALS.get(id) == entry) entry.sample = encodeSignal(strength);
                        }
                    }
                };
                SIGNALS.put(id, entry);
                scoped.listen(entry.listener, android.telephony.PhoneStateListener.LISTEN_SIGNAL_STRENGTHS);
            } catch (RuntimeException denied) { removeSignal(id); }
        }
    }

    @SuppressWarnings("deprecation")
    private static void removeSignal(int id) {
        var removed = SIGNALS.remove(id);
        if (removed != null) {
            try { removed.manager.listen(removed.listener, android.telephony.PhoneStateListener.LISTEN_NONE); }
            catch (RuntimeException ignored) { }
        }
    }

    static synchronized void stopSignals() {
        observing = false;
        for (int id : new java.util.ArrayList<>(SIGNALS.keySet())) removeSignal(id);
    }

    public static JSONArray slots(Context context) {
        JSONArray values = new JSONArray();
        try {
            DefaultCallAccount.Snapshot snapshot = DefaultCallAccount.snapshot(context);
            if (!snapshot.error().isEmpty()) return values;
            refreshSignals(context);
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
        JSONObject polled = null;
        try {
            var manager = context.getSystemService(android.telephony.TelephonyManager.class);
            if (manager != null) polled = encodeSignal(manager.createForSubscriptionId(subscriptionId).getSignalStrength());
        } catch (RuntimeException ignored) { }
        synchronized (SimSlotJson.class) {
            var entry = SIGNALS.get(subscriptionId);
            JSONObject pushed = entry == null ? null : entry.sample;
            long now = System.currentTimeMillis();
            if (pushed != null && now - pushed.optLong("observed_at_ms") >= 0
                    && now - pushed.optLong("observed_at_ms") < 300_000
                    && (polled == null || pushed.optLong("observed_at_ms") >= polled.optLong("observed_at_ms"))) return pushed;
        }
        return polled;
    }

    private static JSONObject encodeSignal(android.telephony.SignalStrength strength) {
        try {
            if (strength == null) return null;
            var cells = strength.getCellSignalStrengths();
            if (cells.isEmpty()) return null;
            // Some vendor aggregate levels reference an unavailable primary RAT.
            // A sole valid component is unambiguous; never take the strongest of
            // several technologies (LTE/NR can coexist), or borrow another SIM.
            int level = cells.size() == 1 ? cells.get(0).getLevel() : strength.getLevel();
            if (level < 0 || level > 4) return null;
            long now = System.currentTimeMillis();
            long age = 0;
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                long measured = strength.getTimestampMillis();
                age = android.os.SystemClock.elapsedRealtime() - measured;
                if (measured <= 0 || age < 0 || age >= 300_000) return null;
            }
            return new JSONObject().put("level", level).put("observed_at_ms", now - age);
        } catch (RuntimeException | org.json.JSONException ignored) {
            return null;
        }
    }

}
