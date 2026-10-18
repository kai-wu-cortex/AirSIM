package android.app;

/** OS service boundary only; gateway lifecycle/control code remains production code. */
public class Service extends android.content.Context {
    public static final int START_STICKY = 1;
    public void onCreate() {}
    public void onDestroy() {}
    public int onStartCommand(android.content.Intent intent, int flags, int id) { return 0; }
    public android.os.IBinder onBind(android.content.Intent intent) { return null; }
    public void startForeground(int id, Notification notification) {}
    public void startForeground(int id, Notification notification, int type) {}
}
