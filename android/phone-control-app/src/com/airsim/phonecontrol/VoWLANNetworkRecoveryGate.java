package com.airsim.phonecontrol;

/** Debounce network identity, not just IPv4: reconnecting can reuse the same address. */
final class VoWLANNetworkRecoveryGate {
    private String signature;
    private long stableAt;
    private boolean pending, closed;
    synchronized void observe(String next, long now) {
        if (closed || java.util.Objects.equals(signature, next)) return;
        signature = next;
        stableAt = now + 1_000;
        pending = true;
    }
    synchronized boolean consume(long now) {
        if (closed || !pending || now < stableAt) return false;
        pending = false;
        return true;
    }
    synchronized long nextDelay(long now, long fallback) {
        return !closed && pending ? Math.max(1, Math.min(fallback, stableAt - now)) : fallback;
    }
    synchronized void close() { closed = true; pending = false; }
}
