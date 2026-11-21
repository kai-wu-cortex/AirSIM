package android.content;
public final class Context {
    public android.telephony.TelephonyManager manager = new android.telephony.TelephonyManager(-1);
    public <T> T getSystemService(Class<T> type) { return type.cast(manager); }
}
