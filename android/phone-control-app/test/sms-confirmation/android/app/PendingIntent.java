package android.app;
import android.content.Context;
import android.content.Intent;
import java.util.ArrayList;
public class PendingIntent {
    public static final int FLAG_ONE_SHOT = 0x40000000, FLAG_IMMUTABLE = 0x04000000;
    public static final ArrayList<PendingIntent> created = new ArrayList<>();
    private Context context; private Intent intent;
    public boolean cancelled;
    public static PendingIntent getBroadcast(Context context, int code, Intent intent, int flags) {
        if (flags != (FLAG_ONE_SHOT | FLAG_IMMUTABLE)) throw new AssertionError("unsafe callback flags");
        PendingIntent p = new PendingIntent(); p.context = context; p.intent = intent; created.add(p); return p;
    }
    public void deliver(int result) {
        if (cancelled || context.receiver == null) return;
        context.receiver.result = result; context.receiver.onReceive(context, intent);
    }
    public void cancel() { cancelled = true; }
}
