package android.media;

/** External OS boundary: allocating capture succeeds, later Android setup is unavailable. */
public class AudioRecord {
    public static int live, released;
    public static boolean rejectPreferred;
    public static AudioDeviceInfo preferred;
    public static int requestedSource, requestedRate;
    private volatile int state = 1;
    private int mRecordSource;
    public static boolean auditFailure, unrelatedFailure, retryFailure;
    public static int starts, sourceAtStart;
    public int getAudioSource() { return mRecordSource; }
    public static final int RECORDSTATE_RECORDING = 3;
    public AudioRecord(int source, int rate, int channels, int encoding, int bytes) { live++; mRecordSource = source; requestedSource = source; requestedRate = rate; }
    public boolean setPreferredDevice(AudioDeviceInfo device) { preferred = device; return !rejectPreferred; }
    public static int getMinBufferSize(int rate, int channels, int encoding) { return 320; }
    public int getState() { return 1; }
    public int getAudioSessionId() { return 100; }
    public int getRecordingState() { return state; }
    public AudioDeviceInfo getRoutedDevice() { return preferred; }
    public AudioRecordingConfiguration getActiveRecordingConfiguration() { return null; }
    public int read(byte[] data,int offset,int size,int mode) {
        try { Thread.sleep(5); } catch(InterruptedException ignored) { return -3; }
        if(state!=3) return -3;
        for(int i=offset;i<offset+size;i+=2) { data[i]=64; data[i+1]=0; }
        return size;
    }
    public void startRecording() {
        starts++; sourceAtStart = mRecordSource;
        if (unrelatedFailure) throw new NullPointerException("unrelated");
        if (auditFailure && mRecordSource != 5) {
            NullPointerException error = new NullPointerException("private OEM message");
            error.setStackTrace(new StackTraceElement[]{
                new StackTraceElement("java.util.Objects", "requireNonNull", "Objects.java", 1),
                new StackTraceElement("android.media.AudioRecord", "startRecording", "AudioRecord.java", 1560)});
            throw error;
        }
        if (retryFailure) throw new SecurityException("denied");
        state = 3;
    }
    public void stop() { state = 1; }
    public void release() { released++; live--; }
}
