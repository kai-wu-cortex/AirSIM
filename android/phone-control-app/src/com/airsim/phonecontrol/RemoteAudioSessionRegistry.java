package com.airsim.phonecontrol;

/** Tracks whether a remote PCM owner has actually completed its handshake. */
public final class RemoteAudioSessionRegistry {
    private static boolean vowlan;
    private static boolean voble;
    private static final java.util.Set<Object> cloud = java.util.Collections.newSetFromMap(new java.util.IdentityHashMap<>());

    private RemoteAudioSessionRegistry() {}

    public static synchronized void setVoWLAN(boolean active) {
        vowlan = active;
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static synchronized void setVoBLE(boolean active) {
        voble = active;
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static synchronized void setCloud(Object owner, boolean active, String confirmedCall) {
        if (owner == null) return;
        if (active) {
            cloud.add(owner);
            RemoteCallAudioScope.SHARED.bind(owner, confirmedCall);
        } else {
            cloud.remove(owner);
            RemoteCallAudioScope.SHARED.release(owner);
        }
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static synchronized String diagnostic() {
        return "vowlan=" + vowlan + " voble=" + voble + " cloud_sessions=" + cloud.size();
    }

    public static synchronized boolean active() { return vowlan || voble || !cloud.isEmpty(); }

    public static void ownCall(Object owner, String confirmedCall) {
        RemoteCallAudioScope.SHARED.bind(owner, confirmedCall);
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static void releaseCall(Object owner) {
        RemoteCallAudioScope.SHARED.release(owner);
        AirSIMInCallService.refreshAudioPolicy();
    }

    static synchronized boolean ownsCall(java.util.List<String> calls) { return active() && RemoteCallAudioScope.SHARED.owns(calls); }

    static synchronized void resetForTests() { vowlan = false; voble = false; cloud.clear(); }
}
