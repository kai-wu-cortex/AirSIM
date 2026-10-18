package com.airsim.phonecontrol;

/** Limits the fallback command poll when the real-time WebSocket is unavailable. */
final class CommandPollingPolicy {
    private static final long FALLBACK_INTERVAL_MILLIS = 15_000;

    private CommandPollingPolicy() {}

    static boolean shouldPoll(boolean channelConnected, long lastPollMillis, long nowMillis) {
        return !channelConnected && (lastPollMillis == 0 || nowMillis < lastPollMillis
                || nowMillis - lastPollMillis >= FALLBACK_INTERVAL_MILLIS);
    }
    static boolean shouldPoll(boolean connected, long lastPoll, long now, long cooldown) {
        return cooldown == 0 && shouldPoll(connected, lastPoll, now);
    }
}
