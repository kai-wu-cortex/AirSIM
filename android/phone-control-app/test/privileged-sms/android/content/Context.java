package android.content;

import android.telephony.SmsManager;

public class Context {
    public final String packageName;
    public static boolean serviceMissing;
    public static android.media.AudioManager audio = new android.media.AudioManager();
    public Context(String packageName) { this.packageName = packageName; }
    public String getPackageName() { return packageName; }
    public Context createPackageContext(String name, int flags) { return new Context(name); }
    public ContentResolver getContentResolver() { return new ContentResolver(); }
    public final <T> T getSystemService(Class<T> type) {
        if (serviceMissing) return null;
        if (type == android.media.AudioManager.class) return type.cast(audio);
        return type.cast(new SmsManager(packageName, -1));
    }
}
