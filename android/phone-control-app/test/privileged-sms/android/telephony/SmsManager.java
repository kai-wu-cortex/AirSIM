package android.telephony;

import android.app.PendingIntent;
import android.os.Binder;
import android.os.Build;
import android.os.Process;
import java.util.ArrayList;
import java.util.List;

public final class SmsManager {
    public static int sends, sentSubscription, parts = 1;
    public static String sentPackage;
    public static boolean multipart, failSubscription, failSend;
    private final String packageName;
    private final int subscription;

    public SmsManager(String packageName, int subscription) {
        this.packageName = packageName;
        this.subscription = subscription;
    }
    public static SmsManager getDefault() { return getSmsManagerForSubscriptionId(Integer.MAX_VALUE); }
    public static SmsManager getSmsManagerForSubscriptionId(int subscription) {
        checkIdentity();
        if (failSubscription) throw new IllegalArgumentException("subscription unavailable");
        return new SmsManager("legacy", subscription);
    }
    public SmsManager createForSubscriptionId(int subscription) {
        if (failSubscription) throw new IllegalArgumentException("subscription unavailable");
        return new SmsManager(packageName, subscription);
    }
    public ArrayList<String> divideMessage(String text) {
        checkIdentity();
        if (Build.VERSION.SDK_INT >= 30 && TelephonyFrameworkInitializer.manager == null)
            throw new IllegalStateException("telephony registry missing");
        return new ArrayList<>(parts == 0 ? List.of() : parts == 1 ? List.of(text) : List.of("a", "b"));
    }
    public void sendTextMessage(String destination, String sc, String text,
            PendingIntent sent, PendingIntent delivered) { send(false); }
    public void sendMultipartTextMessage(String destination, String sc, ArrayList<String> text,
            ArrayList<PendingIntent> sent, ArrayList<PendingIntent> delivered) { send(true); }
    private void send(boolean multi) {
        checkIdentity();
        if (failSend) throw new SecurityException("permission denied");
        if (Build.VERSION.SDK_INT >= 31 && Process.myUid() == 2000
                && !"com.android.shell".equals(packageName))
            throw new SecurityException("package does not belong to shell uid");
        sends++;
        sentPackage = packageName;
        sentSubscription = subscription;
        multipart = multi;
    }
    private static void checkIdentity() {
        if (Binder.callingUid != Process.myUid())
            throw new SecurityException("inherited app calling identity");
    }
}
