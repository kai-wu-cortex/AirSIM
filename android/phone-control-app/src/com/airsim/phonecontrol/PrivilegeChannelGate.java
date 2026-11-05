package com.airsim.phonecontrol;

/** Shared arbitration rules; actual connections are serialized by the manager worker. */
final class PrivilegeChannelGate {
    static boolean canStartRoot(String selected, boolean connected, boolean starting) {
        return !"SHIZUKU".equals(selected) && !connected && !starting;
    }
    static boolean canBindShizuku(String selected, boolean rootConnected, boolean rootStarting) {
        return !"ROOT".equals(selected) && !rootConnected
                && ("SHIZUKU".equals(selected) || !rootStarting);
    }
    static boolean accepts(long startedGeneration, long currentGeneration) {
        return startedGeneration == currentGeneration;
    }
}
