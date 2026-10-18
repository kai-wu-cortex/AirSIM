package android.telephony;
import android.telecom.PhoneAccountHandle;
public class TelephonyManager {
    public static final int SIM_STATE_UNKNOWN = 0;
    public static final int SIM_STATE_ABSENT = 1;
    public static final int SIM_STATE_PIN_REQUIRED = 2;
    public static final int SIM_STATE_PUK_REQUIRED = 3;
    public static final int SIM_STATE_NETWORK_LOCKED = 4;
    public static final int SIM_STATE_READY = 5;
    public static final int SIM_STATE_NOT_READY = 6;
    public static final int SIM_STATE_PERM_DISABLED = 7;
    public static final int SIM_STATE_CARD_IO_ERROR = 8;
    public static final int SIM_STATE_CARD_RESTRICTED = 9;
    public static final int SIM_STATE_LOADED = 10;

    public int subscriptionId = -1;
    public int modernLookupCount;
    public int simState = SIM_STATE_UNKNOWN;
    public String networkOperatorName = "";
    public String simOperatorName = "";
    public String networkCountryIso = "";

    public int getSubscriptionId(PhoneAccountHandle handle) { modernLookupCount++; return subscriptionId; }
    public TelephonyManager createForPhoneAccountHandle(PhoneAccountHandle handle) { return this; }
    public TelephonyManager createForSubscriptionId(int id) { return this; }
    public String getNetworkSpecifier() { return Integer.toString(subscriptionId); }
    public String getLine1Number() { return ""; }
    public int getSimState() { return simState; }
    /** Per-slot variant introduced in API 26. */
    public int getSimState(int slotIndex) { return simState; }
    public String getNetworkOperatorName() { return networkOperatorName; }
    public String getSimOperatorName() { return simOperatorName; }
    public String getNetworkCountryIso() { return networkCountryIso; }
    public boolean isNetworkRoaming() { return false; }
}
