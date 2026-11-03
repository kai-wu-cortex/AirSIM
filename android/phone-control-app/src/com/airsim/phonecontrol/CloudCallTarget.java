package com.airsim.phonecontrol;

/** Resolves a Relay call identity to the Telecom call owned by that media session. */
final class CloudCallTarget {
    static boolean requiresIdentity(String type) { return "dtmf".equals(type) || "call_control".equals(type); }
    /** Whether a Telecom call event belongs to the call a cloud session owns; an unbound session owns none. */
    static boolean owns(String ownedAndroidID, String eventAndroidID) {
        return ownedAndroidID != null && !ownedAndroidID.isEmpty() && ownedAndroidID.equals(eventAndroidID);
    }
    private final String callID;
    private final String callUUID;
    private final long generation;
    private final String androidID;

    CloudCallTarget(String callID, String callUUID, long generation, String androidID) {
        this.callID = callID;
        this.callUUID = callUUID;
        this.generation = generation;
        this.androidID = androidID;
    }

    String resolve(String requestedID, String requestedUUID, long requestedGeneration) {
        if (androidID == null || androidID.isBlank() || callID == null || callID.isBlank()
                || callUUID == null || callUUID.isBlank()) return "";
        return callID.equals(requestedID) && callUUID.equalsIgnoreCase(requestedUUID)
                && generation == requestedGeneration ? androidID : "";
    }
}
