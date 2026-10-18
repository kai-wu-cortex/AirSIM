package android.telephony;

/** Framework boundary only: emulate the absent pre-31 entry point without sending SMS. */
public final class SmsManager {
    private final int subscription;
    private SmsManager(int subscription) { this.subscription = subscription; }
    public static SmsManager getDefault() { return new SmsManager(-1); }
    public static SmsManager getSmsManagerForSubscriptionId(int subscription) {
        return new SmsManager(subscription);
    }
    public SmsManager createForSubscriptionId(int subscription) {
        if (android.os.Build.VERSION.SDK_INT < 31) throw new NoSuchMethodError("API 31 required");
        return new SmsManager(subscription);
    }
    public int getSubscriptionId() { return subscription; }
}
