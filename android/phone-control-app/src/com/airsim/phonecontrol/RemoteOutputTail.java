package com.airsim.phonecontrol;

/** Retain an already-owned output policy only across confirmed Telecom teardown.
 * Socket loss while ACTIVE is not a hangup. Never mute an ordinary/replacement call.
 * No global microphone or capture gain is changed by this policy.
 */
final class RemoteOutputTail {
    static final long MAX_MILLIS = 2_000;
    private String callID = "";
    private String transport = "";
    private boolean wasOwned;
    private long deadline;

    boolean update(String soleNativeCallID, boolean terminal, boolean owned,
                   String currentTransport, long now) {
        if (soleNativeCallID == null || soleNativeCallID.isEmpty()) { clear(); return false; }
        if (!soleNativeCallID.equals(callID)) {
            clear(); callID = soleNativeCallID;
        }
        if (terminal) {
            if (!wasOwned) return false;
            if (deadline == 0) deadline = now + MAX_MILLIS;
            // Repeated callbacks cannot extend the deadline or re-mute after it.
            return now < deadline;
        }
        deadline = 0;
        wasOwned = owned;
        transport = currentTransport;
        return false;
    }
    long deadline() { return deadline; }
    String transport() { return transport; }
    void clear() { callID = ""; transport = ""; wasOwned = false; deadline = 0; }
}
