package com.airsim.phonecontrol;

import java.util.HashMap;
import java.util.UUID;

/** In-memory, single-use capabilities. Never stores a phone number or SMS body. */
final class RootSMSCallbackStore<T> {
    private record Entry<T>(T value, long expiresAt) {}
    private final HashMap<String, Entry<T>> entries = new HashMap<>();

    synchronized String register(T value, long now) {
        entries.values().removeIf(entry -> entry.expiresAt <= now);
        if (entries.size() >= 16) throw new IllegalStateException("too_many_sms_attempts");
        String token = UUID.randomUUID().toString();
        entries.put(token, new Entry<>(value, now + 60_000L));
        return token;
    }

    synchronized T claim(int callerUid, String token, long now) {
        if (callerUid != 0) throw new SecurityException("root required");
        Entry<T> entry = entries.remove(token);
        if (entry == null || entry.expiresAt <= now) throw new IllegalStateException("sms_attempt_unavailable");
        return entry.value;
    }

    synchronized void revoke(String token) { entries.remove(token); }
}
