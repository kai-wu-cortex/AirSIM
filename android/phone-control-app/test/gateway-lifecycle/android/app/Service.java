package android.app;

/** OS service boundary only; gateway lifecycle/control code remains production code. */
public class Service extends android.content.Context {
    private final java.util.Set<android.content.BroadcastReceiver> receivers = new java.util.HashSet<>();
    public android.content.Intent registerReceiver(android.content.BroadcastReceiver receiver,
            android.content.IntentFilter filter) { receivers.add(receiver); return null; }
    public android.content.Intent registerReceiver(android.content.BroadcastReceiver receiver,
            android.content.IntentFilter filter, int flags) { return registerReceiver(receiver, filter); }
    public void unregisterReceiver(android.content.BroadcastReceiver receiver) {
        if (!receivers.remove(receiver)) throw new IllegalArgumentException("receiver not registered");
    }
    public static final int START_STICKY = 1;
    public void onCreate() {}
    public void onDestroy() {}
    public int onStartCommand(android.content.Intent intent, int flags, int id) { return 0; }
    public android.os.IBinder onBind(android.content.Intent intent) { return null; }
    public void startForeground(int id, Notification notification) {}
    public void startForeground(int id, Notification notification, int type) {}
}
