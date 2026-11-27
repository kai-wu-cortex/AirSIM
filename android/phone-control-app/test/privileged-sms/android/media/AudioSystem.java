package android.media;

/** Real privileged service boundary: distinct native sinks, separate from framework volume. */
public final class AudioSystem {
    public static int earpiece = 7, speaker = 9;
    public static int getStreamVolumeIndex(int stream, int device) {
        if (stream != 0 || (device != 1 && device != 2)) throw new AssertionError("wrong physical device");
        return device == 1 ? earpiece : speaker;
    }
    public static int setStreamVolumeIndexAS(int stream, int index, boolean muted, int device) {
        getStreamVolumeIndex(stream, device);
        if (device == 1) earpiece = index; else speaker = index;
        return 0;
    }
}
