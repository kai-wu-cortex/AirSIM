package android.media;
public class AudioManager {
    public static final int STREAM_VOICE_CALL = 0, ADJUST_MUTE = -100, ADJUST_UNMUTE = 100;
    public int volume = 5, writes;
    public boolean muted, rejectWrites;
    public boolean isStreamMute(int stream) { return muted; }
    public int getStreamVolume(int stream) { return volume; }
    public int getLastAudibleStreamVolume(int stream) { return volume; }
    public int getStreamMinVolume(int stream) { return 0; }
    public void setStreamVolume(int stream, int value, int flags) {
        if (rejectWrites) throw new IllegalStateException("fixture rejected write");
        volume = value; writes++;
    }
    public void adjustStreamVolume(int stream, int direction, int flags) {
        muted = direction == ADJUST_MUTE; writes++;
    }
    public int getMode() { return 2; }
    public boolean isSpeakerphoneOn() { return false; }
}
