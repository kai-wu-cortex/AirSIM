package android.content;

import android.telephony.SmsManager;

public class Context {
    public final String packageName;
    public static boolean serviceMissing;
    public Context(String packageName) { this.packageName = packageName; }
    public Context createPackageContext(String name, int flags) { return new Context(name); }
    public ContentResolver getContentResolver() { return new ContentResolver(); }
    public final <T> T getSystemService(Class<T> type) {
        return serviceMissing ? null : type.cast(new SmsManager(packageName, -1));
    }
}
