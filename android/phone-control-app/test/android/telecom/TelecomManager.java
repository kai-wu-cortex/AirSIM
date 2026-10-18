package android.telecom;

import android.net.Uri;
import android.os.Bundle;

public class TelecomManager {
    public static final String EXTRA_PHONE_ACCOUNT_HANDLE = "android.telecom.extra.PHONE_ACCOUNT_HANDLE";
    public java.util.Map<PhoneAccountHandle, PhoneAccount> accounts = new java.util.LinkedHashMap<>();
    public java.util.List<PhoneAccountHandle> enabled = java.util.List.of();
    public Bundle lastExtras;
    public int dialCount;
    public java.util.List<PhoneAccountHandle> getCallCapablePhoneAccounts() { return enabled; }
    public PhoneAccount getPhoneAccount(PhoneAccountHandle handle) { return accounts.get(handle); }
    public void placeCall(Uri address, Bundle extras) { lastExtras = extras; dialCount++; }
}
