package android.telephony;
public final class TelephonyManager {
    public static final java.util.Map<Integer, SignalStrength> signals = new java.util.HashMap<>();
    public static int denied = -2; private final int sub;
    public TelephonyManager(int sub) { this.sub = sub; }
    public TelephonyManager createForSubscriptionId(int value) {
        if (value < 0) throw new AssertionError("unresolved subscription must not use a default");
        return new TelephonyManager(value);
    }
    public SignalStrength getSignalStrength() {
        if (sub < 0) throw new AssertionError("unscoped/default signal lookup");
        if (sub == denied) throw new SecurityException("OEM permission restriction");
        return signals.get(sub);
    }
}
