package android.media;

public final class AudioFormat {
    public static int rate, channels;
    public static final class Builder {
        public Builder setEncoding(int value) { return this; }
        public Builder setSampleRate(int value) { rate = value; return this; }
        public Builder setChannelMask(int value) { channels = value; return this; }
        public AudioFormat build() { return new AudioFormat(); }
    }
}
