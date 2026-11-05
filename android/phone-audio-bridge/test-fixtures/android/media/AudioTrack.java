package android.media;

/** Only the platform buffer query is available; actual playback setup fails at the OS boundary. */
public class AudioTrack {
    public static int live, released;
    public static boolean reject8kMono;
    private int state = 1;
    public static int getMinBufferSize(int rate, int channels, int encoding) { return reject8kMono && rate == 8000 ? -2 : 320; }
    public boolean setPreferredDevice(AudioDeviceInfo device) { return true; }
    public int getState() { return 1; }
    public int getPlayState() { return state; }
    public void play() { state = 3; }
    public void stop() { state = 1; }
    public void release() { live--; released++; }
    public static final class Builder {
        public Builder setAudioAttributes(AudioAttributes attributes) { return this; }
        public Builder setAudioFormat(AudioFormat format) { return this; }
        public Builder setBufferSizeInBytes(int bytes) { return this; }
        public Builder setTransferMode(int mode) { return this; }
        public AudioTrack build() { live++; return new AudioTrack(); }
    }
}
