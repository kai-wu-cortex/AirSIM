package android.content;
public class Context {
    public static final int RECEIVER_NOT_EXPORTED = 4;
    public BroadcastReceiver receiver;
    public int unregisters;
    public boolean rejectRegistration;
    public String getPackageName() { return "com.airsim.fixture"; }
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter) {
        if (rejectRegistration) throw new SecurityException("fixture");
        this.receiver = receiver; return null;
    }
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter, int flags) {
        if (flags != RECEIVER_NOT_EXPORTED) throw new AssertionError("exported");
        return registerReceiver(receiver, filter);
    }
    public void unregisterReceiver(BroadcastReceiver receiver) { this.receiver = null; unregisters++; }
}
