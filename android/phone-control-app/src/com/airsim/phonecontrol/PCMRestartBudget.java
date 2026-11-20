package com.airsim.phonecontrol;
/** Bounded crash recovery; elapsed realtime must be supplied by caller. */
final class PCMRestartBudget {
    private int failures;
    private long blockedUntil;
    synchronized boolean permits(long now) {
        if(now < blockedUntil) return false;
        if(blockedUntil != 0) { failures=0; blockedUntil=0; }
        return true;
    }
    synchronized String diagnostic(long now) {
        return "pcm_restart_attempts=" + failures + " pcm_restart_cooldown_ms=" + Math.max(0, blockedUntil - now);
    }
    synchronized long exited(long now, long runtime) {
        if(runtime >= 60000) failures=0;
        failures++;
        if(failures > 5) { blockedUntil=now+120000; return -1; }
        return Math.min(16000,1000L << (failures-1));
    }
}
