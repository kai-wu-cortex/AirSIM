package android.telephony;
import android.telecom.PhoneAccountHandle;
public class TelephonyManager {
    public int subscriptionId = -1;
    public int modernLookupCount;
    public int getSubscriptionId(PhoneAccountHandle handle) { modernLookupCount++; return subscriptionId; }
    public TelephonyManager createForPhoneAccountHandle(PhoneAccountHandle handle) { return this; }
    public String getNetworkSpecifier() { return Integer.toString(subscriptionId); }
    public TelephonyManager createForSubscriptionId(int subscriptionId) { return this; }
    public String getLine1Number() { return ""; }
    public boolean isVoiceCapable() { return true; }
}
