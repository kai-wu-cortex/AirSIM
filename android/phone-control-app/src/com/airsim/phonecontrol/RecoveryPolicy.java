package com.airsim.phonecontrol;

public final class RecoveryPolicy {
    private static final long COOLDOWN_MILLIS = 5 * 60_000L;
    private RecoveryPolicy() {}

    public static boolean shouldAttempt(int consecutiveFailures, long lastAttemptMillis, long nowMillis) {
        return consecutiveFailures >= 3 && (lastAttemptMillis <= 0 || nowMillis - lastAttemptMillis >= COOLDOWN_MILLIS);
    }
}
