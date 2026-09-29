package com.airsim.phonecontrol;

public final class RetryPolicy {
    private RetryPolicy() {}

    public static long delayMillis(int failureCount) {
        int exponent = Math.max(0, Math.min(failureCount, 4));
        return Math.min(15_000L, 1_000L << exponent);
    }
}
