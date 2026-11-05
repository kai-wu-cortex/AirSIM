package android.media;

public final class AudioManager {
    public static boolean denyQuery = true;
    public static boolean exposeTx;
    public static boolean exposeRx;
    public static AudioDeviceInfo[] getDevicesStatic(int flags) {
        if (denyQuery) throw new SecurityException("private OEM error text");
        if (flags == 1) return exposeRx ? new AudioDeviceInfo[]{new AudioDeviceInfo(true)} : new AudioDeviceInfo[0];
        return exposeTx ? new AudioDeviceInfo[]{new AudioDeviceInfo()} : new AudioDeviceInfo[0];
    }
}
