package android.telephony;

import android.os.TelephonyServiceManager;

public final class TelephonyFrameworkInitializer {
    public static TelephonyServiceManager manager;
    public static TelephonyServiceManager getTelephonyServiceManager() { return manager; }
    public static void setTelephonyServiceManager(TelephonyServiceManager value) { manager = value; }
}
