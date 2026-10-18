package com.airsim.phonecontrol;

import java.util.List;

/** Media plus a call ID confirmed by authenticated control; never infer ownership from call order. */
final class RemoteCallAudioScope {
    static final RemoteCallAudioScope SHARED = new RemoteCallAudioScope();
    private final java.util.Map<Object, String> owners = new java.util.IdentityHashMap<>();
    synchronized void bind(Object owner, String confirmedCall) {
        if (owner == null || confirmedCall == null || confirmedCall.isEmpty()) return;
        owners.putIfAbsent(owner, confirmedCall);
    }
    synchronized void release(Object owner) { owners.remove(owner); }
    synchronized boolean owns(List<String> liveCalls) {
        if (liveCalls.size() != 1) return false;
        // Owner keys use identity, but call IDs cross JSON/BLE boundaries and must
        // match by text. IdentityHashMap.containsValue also uses reference equality.
        String liveCall = liveCalls.get(0);
        for (String confirmedCall : owners.values()) {
            if (confirmedCall.equals(liveCall)) return true;
        }
        return false;
    }
}
