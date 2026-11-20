package com.airsim.phonecontrol;

import java.util.regex.Pattern;

/** Only a fresh application wake belonging to a screen-off remote call is eligible. */
final class RemoteCallScreenPolicy {
    record Wake(boolean interactive, long time, int reason) {}
    private static final Pattern TIME = Pattern.compile("(?m)^\\s*mLastWakeTime=(\\d+)");
    private static final Pattern REASON = Pattern.compile("(?m)^\\s*mLastWakeReason=(\\d+)");
    static Wake parse(String dump) {
        var t = TIME.matcher(dump); var r = REASON.matcher(dump);
        if (!t.find() || !r.find()) throw new IllegalArgumentException("wake evidence unavailable");
        boolean awake = Pattern.compile("(?m)^\\s*mWakefulness=(Awake|1)\\s*$").matcher(dump).find();
        return new Wake(awake, Long.parseLong(t.group(1)), Integer.parseInt(r.group(1)));
    }
    static boolean suppress(Wake wake, long since, long now) {
        // POWER_BUTTON=1, WAKE_KEY=6 and BIOMETRIC=17 must remain user-controlled.
        return wake.interactive && wake.reason == 2 && since >= 0 && since <= now
                && wake.time >= Math.max(0, since - 1500) && wake.time <= now
                && now - wake.time <= 1500;
    }
    static boolean eligible(boolean remoteSilentPaired, boolean initiallyOff, boolean recentlyAwakened) {
        return remoteSilentPaired && (initiallyOff || recentlyAwakened);
    }
    static boolean scopeAllows(boolean eligible, boolean owned, int liveCalls, boolean terminalGrace) {
        return eligible && owned && (terminalGrace ? liveCalls == 0 : liveCalls == 1);
    }
}
