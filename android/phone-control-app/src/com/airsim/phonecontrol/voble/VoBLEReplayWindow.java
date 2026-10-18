package com.airsim.phonecontrol.voble;

import java.util.ArrayDeque;
import java.util.Base64;
import java.util.HashSet;
import java.util.Set;

public final class VoBLEReplayWindow {
    private final long maximumAgeMillis;
    private final int capacity;
    private final ArrayDeque<String> order = new ArrayDeque<>();
    private final Set<String> observed = new HashSet<>();
    private boolean revoked;

    public VoBLEReplayWindow(long maximumAgeMillis, int capacity) {
        if (maximumAgeMillis <= 0 || capacity <= 0) {
            throw new IllegalArgumentException("replay window bounds must be positive");
        }
        this.maximumAgeMillis = maximumAgeMillis;
        this.capacity = capacity;
    }

    public synchronized boolean accept(byte[] nonce, long timestampMillis, long nowMillis) {
        if (revoked || nonce == null || nonce.length == 0
                || timestampMillis < nowMillis - maximumAgeMillis
                || timestampMillis > nowMillis + 5_000L) return false;
        String key = Base64.getEncoder().encodeToString(nonce);
        if (!observed.add(key)) return false;
        order.addLast(key);
        if (order.size() > capacity) observed.remove(order.removeFirst());
        return true;
    }

    public synchronized void revoke() {
        revoked = true;
        order.clear();
        observed.clear();
    }
}
