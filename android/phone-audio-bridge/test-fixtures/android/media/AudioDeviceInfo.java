package android.media;

public final class AudioDeviceInfo {
    private final boolean source;
    public AudioDeviceInfo() { this(false); }
    public AudioDeviceInfo(boolean source) { this.source = source; }
    public boolean isSink() { return !source; }
    public boolean isSource() { return source; }
    public int[] getSampleRates() { return source ? new int[]{8000,16000,48000} : new int[]{44100,48000}; }
    public int[] getChannelCounts() { return source ? new int[]{1,2} : new int[]{2}; }
    public int[] getEncodings() { return new int[]{2}; }
    public int getType() { return 18; }
    public int getId() { return 7; }
}
