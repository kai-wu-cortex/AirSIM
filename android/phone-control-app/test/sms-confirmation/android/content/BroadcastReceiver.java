package android.content;
public abstract class BroadcastReceiver {
    public int result;
    public int getResultCode() { return result; }
    public abstract void onReceive(Context context, Intent intent);
}
