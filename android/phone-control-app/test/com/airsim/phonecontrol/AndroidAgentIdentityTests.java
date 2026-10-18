package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.ComponentName;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import java.util.List;

public final class AndroidAgentIdentityTests {
    public static void main(String[] args) {
        SubscriptionInfo first = new SubscriptionInfo(), second = new SubscriptionInfo();
        first.subscriptionId = 1; first.number = "+10000000001";
        second.subscriptionId = 2; second.number = "+10000000002";
        SubscriptionManager subscriptions = new SubscriptionManager();
        subscriptions.active = List.of(first, second);
        SubscriptionManager.defaultVoiceId = 2;
        TelephonyManager telephony = new TelephonyManager();
        telephony.subscriptionId = 2;
        TelecomManager telecom = new TelecomManager();
        PhoneAccountHandle handle = new PhoneAccountHandle(new ComponentName("phone", "Service"), "opaque-esim");
        telecom.enabled = List.of(handle);
        telecom.accounts.put(handle, new PhoneAccount(handle, "eSIM", PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION));
        Context context = new Context();
        context.grant(Manifest.permission.READ_PHONE_STATE);
        context.grant(Manifest.permission.READ_PHONE_NUMBERS);
        context.setSystemService(SubscriptionManager.class, subscriptions);
        context.setSystemService(TelephonyManager.class, telephony);
        context.setSystemService(TelecomManager.class, telecom);
        assertNumber("+10000000002", AndroidAgentIdentity.phoneNumber(context));
        DefaultCallAccount.select(context, DefaultCallAccount.snapshot(context).accounts().get(0));
        assertNumber("+10000000002", AndroidAgentIdentity.phoneNumber(context));
        second.number = "+10000000003";
        assertNumber("+10000000003", AndroidAgentIdentity.phoneNumber(context));
        second.number = "";
        assertNumber("", AndroidAgentIdentity.phoneNumber(context));
        telecom.enabled = List.of();
        assertNumber("", AndroidAgentIdentity.phoneNumber(context));
        context.revoke(Manifest.permission.READ_PHONE_NUMBERS);
        assertNumber("", AndroidAgentIdentity.phoneNumber(context));
        SubscriptionManager.defaultVoiceId = -1;
        System.out.println("Android agent current SIM identity tests passed");
    }
    private static void assertNumber(String expected, String actual) {
        if (!expected.equals(actual)) throw new AssertionError("must report current selected SIM, never another or cached SIM");
    }
}
