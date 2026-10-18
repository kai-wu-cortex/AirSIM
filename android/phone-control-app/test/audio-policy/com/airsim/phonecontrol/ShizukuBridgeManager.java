package com.airsim.phonecontrol;

/** Replace only the external privileged Binder/AudioManager boundary. */
final class ShizukuBridgeManager {
    static final ShizukuBridgeManager INSTANCE = new ShizukuBridgeManager();
    static ShizukuBridgeManager get(android.content.Context context) { return INSTANCE; }
    final Platform platform = new Platform();
    LocalOutputMuteController output = new LocalOutputMuteController(platform);
    boolean watchdog;
    void setLocalOutputMuted(boolean value) {
        try { output.setMuted(value); }
        catch (Exception error) { throw new AssertionError(error); }
    }
    void updateAudioWatchdog(boolean active, String key, String transports) { watchdog = active; }
    static final class Platform implements LocalOutputMuteController.Backend {
        boolean muted;
        int volume = 6;
        public boolean isMuted() { return muted; }
        public int volume() { return volume; }
        public int minimumVolume() { return 1; }
        public void setMuted(boolean value) { muted = value; }
        public void setVolume(int value) { volume = value; }
    }
}
