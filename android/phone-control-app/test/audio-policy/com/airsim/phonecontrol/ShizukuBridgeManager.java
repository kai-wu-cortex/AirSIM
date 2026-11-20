package com.airsim.phonecontrol;

/** Replace only the external privileged Binder/AudioManager boundary. */
final class ShizukuBridgeManager {
    static final ShizukuBridgeManager INSTANCE = new ShizukuBridgeManager();
    static ShizukuBridgeManager get(android.content.Context context) { return INSTANCE; }
    final Platform platform = new Platform();
    LocalOutputMuteController output = new LocalOutputMuteController(platform);
    final LocalMicrophoneMuteController microphone = new LocalMicrophoneMuteController(
            new LocalMicrophoneMuteController.Backend() {
                public boolean muted() { return platform.microphoneMuted; }
                public void setMuted(boolean value) { platform.microphoneMuted = value; }
            });
    boolean watchdog;
    String lastTransport = PrivilegedBridgeProtocol.TRANSPORT_VOWLAN;
    void setLocalOutputMuted(boolean value) {
        setLocalOutputMuted(value, PrivilegedBridgeProtocol.TRANSPORT_VOWLAN);
    }
    void setLocalOutputMuted(boolean value, String transport) {
        lastTransport = transport;
        try {
            if (value) microphone.setMuted(!PrivilegedBridgeProtocol.TRANSPORT_VOBLE.equals(transport));
            output.setMuted(value);
            if (!value) microphone.setMuted(false);
        }
        catch (Exception error) { throw new AssertionError(error); }
    }
    void updateAudioWatchdog(boolean active, String key, String transports) { watchdog = active; }
    static final class Platform implements LocalOutputMuteController.Backend {
        boolean muted;
        boolean microphoneMuted;
        int volume = 6;
        public boolean isMuted() { return muted; }
        public int volume() { return volume; }
        public int minimumVolume() { return 1; }
        public void setMuted(boolean value) { muted = value; }
        public void setVolume(int value) { volume = value; }
    }
}
