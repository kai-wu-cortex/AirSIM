package com.airsim.phonecontrol;

import java.io.Closeable;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

record RetryDecision(long delayMillis, int failures, String reason) {}

/** Monotonic, shared WSS/HTTP cooldown and cancellable configuration epoch. */
final class RelayCommandRetryState {
    private int failures;
    private long failedAt, delay;
    private String scope;
    private long epoch;
    private Closeable socket;
    synchronized RetryDecision failedFor(long candidateEpoch, long nowMillis, long connectedDurationMillis, Throwable error, double jitterUnit) {
        if (!isCurrent(candidateEpoch)) return null;
        return failed(nowMillis,connectedDurationMillis,error,jitterUnit);
    }
    synchronized RetryDecision failed(long nowMillis, long connectedDurationMillis, Throwable error, double jitterUnit) {
        if (connectedDurationMillis >= 60_000) failures = 0;
        failures = Math.min(31, failures + 1);
        int tier = Math.min(failures - 1, 5);
        long base = Math.min(60_000L, 3_000L << tier);
        String reason = "network";
        if (error instanceof RelayHTTPException http && (http.statusCode() == 429 || http.statusCode() >= 500)) {
            base = Math.min(300_000L, 15_000L << tier); reason = "overload";
        } else if (error instanceof WebSocketPeerClose close) {
            reason = close.category();
            if (close.code() == 4001) base = Math.min(300_000L, 60_000L << tier);
        }
        double unit = Double.isFinite(jitterUnit) ? Math.max(0, Math.min(1, jitterUnit)) : 0;
        long next = base + (long)(base * .25 * unit);
        if (error instanceof RelayHTTPException http) next = Math.max(next, http.retryAfterMillis());
        // Concurrent WSS and HTTP failures may extend, but never shorten, an existing cooldown.
        next = Math.max(next, remainingMillis(nowMillis));
        failedAt = nowMillis; delay = next;
        return new RetryDecision(next, failures, reason);
    }
    synchronized long remainingMillis(long nowMillis) {
        if (delay == 0) return 0;
        if (nowMillis < failedAt) return delay;
        long elapsed = nowMillis - failedAt;
        return elapsed < 0 || elapsed >= delay ? 0 : delay - elapsed;
    }
    synchronized void reset() { failures = 0; delay = 0; failedAt = 0; }
    synchronized long configure(String nextScope) {
        if (!Objects.equals(scope, nextScope)) {
            scope = nextScope; epoch++; reset();
            Closeable old = socket; socket = null; close(old);
        }
        return epoch;
    }
    synchronized boolean isCurrent(long candidate) { return scope != null && candidate == epoch; }
    synchronized boolean attach(long candidate, Closeable next) {
        if (!isCurrent(candidate)) { close(next); return false; }
        socket = next; return true;
    }
    private static void close(Closeable value) { if (value != null) try { value.close(); } catch (Exception ignored) {} }
    static boolean validAgentID(String value) {
        if (value == null || value.isEmpty() || !value.equals(value.strip())
                || value.getBytes(StandardCharsets.UTF_8).length > 128) return false;
        for (int i=0;i<value.length();i++) {
            char c=value.charAt(i);
            if (c<32 || c==127) return false;
            if (Character.isHighSurrogate(c)) {
                if (++i>=value.length() || !Character.isLowSurrogate(value.charAt(i))) return false;
            } else if (Character.isLowSurrogate(c)) return false;
        }
        return true;
    }
}
