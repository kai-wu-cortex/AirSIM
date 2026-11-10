package com.airsim.phonecontrol;

/** No-op test stub; production scheduling needs Android Telecom and a real executor. */
final class RemoteCallHangupGuard {
    private RemoteCallHangupGuard() {}
    static void ownerBound(String callID) {}
    static int lostCalls;
    static void ownerLost(String callID) { lostCalls++; }
}
