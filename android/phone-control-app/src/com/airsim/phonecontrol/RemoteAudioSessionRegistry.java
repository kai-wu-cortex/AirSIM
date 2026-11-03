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
            RemoteCallHangupGuard.ownerBound(confirmedCall);
        } else {
            cloud.remove(owner);
            String releasedCall = RemoteCallAudioScope.SHARED.release(owner);
            if (releasedCall != null) RemoteCallHangupGuard.ownerLost(releasedCall);
        }
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static synchronized String diagnostic() {
        return "vowlan=" + vowlan + " voble=" + voble + " cloud_sessions=" + cloud.size();
    }

    public static synchronized boolean active() { return vowlan || voble || !cloud.isEmpty(); }

    /**
     * Stream policy for the current owner. VoBLE mutes the local stream because its
     * uplink is BLE; every other remote transport keeps the vendor capture-safe policy.
     */
    public static synchronized String streamPolicy() {
        return voble && !vowlan ? PrivilegedBridgeProtocol.TRANSPORT_VOBLE
                : PrivilegedBridgeProtocol.TRANSPORT_VOWLAN;
    }

    public static void ownCall(Object owner, String confirmedCall) {
        RemoteCallAudioScope.SHARED.bind(owner, confirmedCall);
        RemoteCallHangupGuard.ownerBound(confirmedCall);
        AirSIMInCallService.refreshAudioPolicy();
    }

    public static void releaseCall(Object owner) {
        String releasedCall = RemoteCallAudioScope.SHARED.release(owner);
        if (releasedCall != null) RemoteCallHangupGuard.ownerLost(releasedCall);
        AirSIMInCallService.refreshAudioPolicy();
    }

    static synchronized boolean ownsCall(String callID) {
        return RemoteCallAudioScope.SHARED.ownsCall(callID);
    }

    static synchronized boolean ownsCall(java.util.List<String> calls) { return active() && RemoteCallAudioScope.SHARED.owns(calls); }

    static synchronized void resetForTests() { vowlan = false; voble = false; cloud.clear(); }
}
