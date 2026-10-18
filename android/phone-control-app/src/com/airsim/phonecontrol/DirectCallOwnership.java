package com.airsim.phonecontrol;

import java.util.HashMap;
import java.util.Map;

/** Binds one authenticated PCM lease to a specific Telecom call, never "any current call". */
public final class DirectCallOwnership {
    public static final class Lease {
        private final String host;
        private String callID = "";
        private boolean pcmAttached;
        private boolean pcmReady;
        private boolean closed;
        private Lease(String host) { this.host = host; }
    }
    private static final Map<String, Lease> sessions = new HashMap<>();
    private DirectCallOwnership() {}

    public static synchronized Lease begin(String host) {
        Lease lease = capture(host);
        lease.pcmAttached = true;
        return lease;
    }
    public static synchronized Lease capture(String host) {
        return sessions.computeIfAbsent(host, Lease::new);
    }
    public static void record(String host, String callID) { record(host, callID, capture(host)); }
    public static void record(String host, String callID, Lease expected) {
        if (callID == null || callID.isEmpty()) return;
        boolean abandoned;
        synchronized (DirectCallOwnership.class) {
            abandoned = expected == null || expected.closed || sessions.get(host) != expected;
            if (!abandoned && expected.callID.isEmpty()) expected.callID = callID;
            if (!abandoned && expected.pcmReady) RemoteCallAudioScope.SHARED.bind(expected, expected.callID);
        }
        if (abandoned) CallRepository.disconnect(callID);
    }
    public static void disconnectHost(String host) { end(existing(host), true); }
    public static synchronized void pcmReady(Lease lease) {
        if (lease == null || lease.closed || sessions.get(lease.host) != lease) return;
        lease.pcmReady = true;
        RemoteCallAudioScope.SHARED.bind(lease, lease.callID);
    }
    private static synchronized Lease existing(String host) { return sessions.get(host); }
    public static void end(Lease lease, boolean disconnect) {
        if (lease == null) return;
        String id;
        synchronized (DirectCallOwnership.class) {
            if (lease.closed) return;
            lease.closed = true;
            RemoteCallAudioScope.SHARED.release(lease);
            if (sessions.get(lease.host) == lease) sessions.remove(lease.host);
            id = lease.callID;
        }
        if (disconnect && !id.isEmpty()) CallRepository.disconnect(id);
    }
}
