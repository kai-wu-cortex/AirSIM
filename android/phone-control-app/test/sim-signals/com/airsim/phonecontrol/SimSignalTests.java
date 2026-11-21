package com.airsim.phonecontrol;
import android.content.Context;
import android.os.Build;
import android.telephony.*;
import org.json.*;
public final class SimSignalTests {
    static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        Context context = new Context();
        SignalStrength a = new SignalStrength(4), b = new SignalStrength(1);
        TelephonyManager.signals.put(10, a); TelephonyManager.signals.put(20, b);
        for (int sdk : new int[]{29,30,35,36}) {
            Build.VERSION.SDK_INT = sdk;
            JSONArray values = SimSlotJson.slots(context);
            check(values.length() == 2, "two cards preserved");
            check(values.getJSONObject(0).getJSONObject("signal").getInt("level") == 4, "first SIM signal");
            check(values.getJSONObject(1).getJSONObject("signal").getInt("level") == 1, "second SIM distinct signal");
            check(values.getJSONObject(0).getJSONObject("signal").getLong("observed_at_ms") <= System.currentTimeMillis(), "timestamp");
        }
        b.level = 0;
        check(SimSlotJson.slots(context).getJSONObject(1).getJSONObject("signal").getInt("level") == 0, "zero is a real measurement");
        b.timestamp = 600_000;
        check(!SimSlotJson.slots(context).getJSONObject(1).has("signal"), "stale sample omitted");
        b.timestamp = 1_000_001;
        check(!SimSlotJson.slots(context).getJSONObject(1).has("signal"), "future uptime omitted");
        b.timestamp = 999_000; b.empty = true;
        check(!SimSlotJson.slots(context).getJSONObject(1).has("signal"), "no radio measurement is unknown");
        b.empty = false; b.level = 99;
        check(!SimSlotJson.slots(context).getJSONObject(1).has("signal"), "invalid level omitted");
        TelephonyManager.denied = 10;
        JSONArray restricted = SimSlotJson.slots(context);
        check(restricted.length() == 2 && !restricted.getJSONObject(0).has("signal"), "permission denial retains roster");
        TelephonyManager.denied = -2;
        DefaultCallAccount.accounts = java.util.List.of(new DefaultCallAccount.Account("unresolved", "SIM", -1, -1));
        check(!SimSlotJson.slots(context).getJSONObject(0).has("signal"), "never substitute default SIM");
        DefaultCallAccount.accounts = java.util.List.of();
        check(SimSlotJson.slots(context).length() == 0, "removed SIM clears roster");
        System.out.println("SimSlotJson signal tests passed: API 29/30/35/36, two subscriptions, zero/unknown, timestamps, permissions, removal");
    }
}
