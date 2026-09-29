package com.airsim.phonecontrol;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public final class CallEventDeduplicator {
    private final Map<String, String> fingerprints = new ConcurrentHashMap<>();

    public boolean shouldSend(String callId, String direction, String state, String number) {
        String fingerprint = direction + "\n" + state + "\n" + (number == null ? "" : number);
        return !fingerprint.equals(fingerprints.put(callId, fingerprint));
    }

    public void remove(String callId) {
        fingerprints.remove(callId);
    }
}
