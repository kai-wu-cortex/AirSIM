package com.airsim.phonecontrol;
public final class RemoteAudioSessionRegistry {
    public static volatile boolean active;
    public static volatile String reserved = "";
    public static void reserveVoWLANCall(String id) { reserved = id; }
    public static void nativeCallEnded(String id) { if (reserved.equals(id)) reserved = ""; }
    public static void setEarlyMedia(Object owner, String callID, boolean ready) {}
    public static void setVoWLAN(boolean value) { active = value; }
}
