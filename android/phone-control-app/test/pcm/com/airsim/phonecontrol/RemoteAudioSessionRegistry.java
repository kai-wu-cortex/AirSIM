package com.airsim.phonecontrol;
public final class RemoteAudioSessionRegistry {
    public static volatile boolean active;
    public static void setVoWLAN(boolean value) { active = value; }
}
