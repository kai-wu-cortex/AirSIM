package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.ComponentName;
import android.os.Build;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.telephony.TelephonyManager;
import android.telephony.SubscriptionManager;
import android.telephony.SubscriptionInfo;
import java.util.List;

public final class DefaultCallAccountTests {
    public static void main(String[] args) {
        followsSystemWithoutPhoneStatePermission();
        choosesExactAccountAndPersistsAcrossReload();
        missingAccountAndRevokedPermissionNeverFallBack();
        onlyEnabledSimCallingAccountsAreOffered();
        telecomDialReceivesSelectedAccountOnAllRemoteEntrypoints();
        metadataIsOptionalAndNumberRequiresPermission();
        android29UsesSupportedSubscriptionLookup();
        supportsMoreThanTwoAccountsAndKeepsIdentityAcrossReordering();
        System.out.println("default call account tests passed");
    }

    private static Context context(TelecomManager telecom) {
        Context context = new Context();
        context.setSystemService(TelecomManager.class, telecom);
        context.grant(Manifest.permission.READ_PHONE_STATE);
        return context;
    }

    private static PhoneAccountHandle handle(String id) {
        return new PhoneAccountHandle(new ComponentName("phone", "ConnectionService"), id);
    }

    private static TelecomManager telecom(PhoneAccountHandle... handles) {
        TelecomManager telecom = new TelecomManager();
        for (PhoneAccountHandle handle : handles) {
            telecom.accounts.put(handle, new PhoneAccount(handle, "Carrier " + handle.getId(),
                    PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION));
        }
        telecom.enabled = List.of(handles);
        return telecom;
    }

    private static void followsSystemWithoutPhoneStatePermission() {
        Context context = new Context();
        assertTrue(!DefaultCallAccount.dialExtras(context).containsKey(
                TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
    }

    private static void choosesExactAccountAndPersistsAcrossReload() {
        PhoneAccountHandle sim1 = handle("opaque-sim-one"), sim2 = handle("opaque-esim-two");
        Context context = context(telecom(sim1, sim2));
        assertEquals(2, DefaultCallAccount.snapshot(context).accounts().size());
        var selected = DefaultCallAccount.snapshot(context).accounts().get(1);
        DefaultCallAccount.select(context, selected);
        assertEquals(sim2, DefaultCallAccount.dialExtras(context).getParcelable(
                TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
        // A new Context representing a restarted process reads the same storage.
        Context reopened = context.reopen();
        assertEquals(selected.key(), DefaultCallAccount.selectedKey(reopened));
        assertEquals(sim2, DefaultCallAccount.dialExtras(reopened).getParcelable(
                TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
        DefaultCallAccount.followSystem(reopened);
        assertEquals("", DefaultCallAccount.selectedKey(context));
        assertTrue(!DefaultCallAccount.dialExtras(context).containsKey(
                TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
    }

    private static void missingAccountAndRevokedPermissionNeverFallBack() {
        PhoneAccountHandle sim1 = handle("sim-one"), sim2 = handle("sim-two");
        TelecomManager telecom = telecom(sim1, sim2);
        Context context = context(telecom);
        DefaultCallAccount.select(context, DefaultCallAccount.snapshot(context).accounts().get(1));
        telecom.enabled = List.of(sim1);
        assertFails(() -> DefaultCallAccount.dialExtras(context));
        assertEquals(0, telecom.dialCount);
        context.revoke(Manifest.permission.READ_PHONE_STATE);
        assertFails(() -> DefaultCallAccount.dialExtras(context));
        assertTrue(!DefaultCallAccount.snapshot(context).error().isEmpty());
        DefaultCallAccount.followSystem(context);
        assertTrue(!DefaultCallAccount.dialExtras(context).containsKey(
                TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
    }

    private static void onlyEnabledSimCallingAccountsAreOffered() {
        PhoneAccountHandle sim = handle("sim"), voip = handle("voip"), disabled = handle("disabled");
        TelecomManager telecom = telecom(sim, voip, disabled);
        telecom.accounts.put(voip, new PhoneAccount(voip, "VoIP", 0));
        telecom.enabled = List.of(sim, voip);
        var snapshot = DefaultCallAccount.snapshot(context(telecom));
        assertEquals(1, snapshot.accounts().size());
        assertEquals(sim, snapshot.accounts().get(0).handle());
    }

    private static void telecomDialReceivesSelectedAccountOnAllRemoteEntrypoints() {
        PhoneAccountHandle sim1 = handle("sim1"), sim2 = handle("sim2");
        TelecomManager telecom = telecom(sim1, sim2);
        Context context = context(telecom);
        DefaultCallAccount.select(context, DefaultCallAccount.snapshot(context).accounts().get(1));
        assertTrue(CallRepository.execute(context,
                new AgentCommand("local-or-cloud", "dial", "", "10010")).success);
        assertEquals(sim2, telecom.lastExtras.getParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
        assertTrue(CallRepository.executeRemote(context, "bluetooth", "dial", "", "10010").success);
        assertEquals(sim2, telecom.lastExtras.getParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
        int invoked = telecom.dialCount;
        telecom.enabled = List.of(sim1);
        assertTrue(!CallRepository.execute(context,
                new AgentCommand("missing-sim", "dial", "", "10010")).success);
        assertEquals(invoked, telecom.dialCount);
    }

    private static void assertFails(Runnable operation) {
        try { operation.run(); }
        catch (IllegalStateException expected) { return; }
        throw new AssertionError("A selected unavailable SIM must not fall back");
    }

    private static void metadataIsOptionalAndNumberRequiresPermission() {
        Context context = context(telecom(handle("esim")));
        TelephonyManager telephony = new TelephonyManager();
        telephony.subscriptionId = 7;
        SubscriptionManager subscriptions = new SubscriptionManager();
        subscriptions.info = new SubscriptionInfo();
        subscriptions.info.slot = 1;
        subscriptions.info.embedded = true;
        subscriptions.info.number = "+10000000000";
        context.setSystemService(TelephonyManager.class, telephony);
        context.setSystemService(SubscriptionManager.class, subscriptions);
        var withoutNumber = DefaultCallAccount.snapshot(context).accounts().get(0);
        assertEquals("eSIM 2 · Carrier", withoutNumber.label());
        assertEquals("", withoutNumber.number());
        assertEquals(0, subscriptions.numberReadCount);
        context.grant(Manifest.permission.READ_PHONE_NUMBERS);
        assertEquals("+10000000000", DefaultCallAccount.snapshot(context).accounts().get(0).number());
        context.setSystemService(SubscriptionManager.class, new SubscriptionManager() {
            @Override public SubscriptionInfo getActiveSubscriptionInfo(int id) {
                throw new SecurityException("metadata denied");
            }
        });
        var fallback = DefaultCallAccount.snapshot(context);
        assertEquals(1, fallback.accounts().size());
        assertEquals("", fallback.error());
        DefaultCallAccount.select(context, fallback.accounts().get(0));
        assertTrue(DefaultCallAccount.dialExtras(context).containsKey(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
    }

    private static void android29UsesSupportedSubscriptionLookup() {
        int version = Build.VERSION.SDK_INT;
        try {
            Build.VERSION.SDK_INT = 29;
            Context context = context(telecom(handle("opaque-id-not-subscription-id")));
            TelephonyManager telephony = new TelephonyManager();
            telephony.subscriptionId = 9;
            SubscriptionManager subscriptions = new SubscriptionManager();
            subscriptions.info = new SubscriptionInfo();
            subscriptions.info.number = "+10000000001";
            context.setSystemService(TelephonyManager.class, telephony);
            context.setSystemService(SubscriptionManager.class, subscriptions);
            context.grant(Manifest.permission.READ_PHONE_NUMBERS);
            var account = DefaultCallAccount.snapshot(context).accounts().get(0);
            assertEquals("SIM 1 · Carrier", account.label());
            assertEquals("+10000000001", account.number());
            assertEquals(0, telephony.modernLookupCount);
            assertEquals(0, subscriptions.numberReadCount);
        } finally { Build.VERSION.SDK_INT = version; }
    }

    private static void supportsMoreThanTwoAccountsAndKeepsIdentityAcrossReordering() {
        PhoneAccountHandle one = handle("one"), two = handle("two"), three = handle("three");
        TelecomManager telecom = telecom(one, two, three);
        Context context = context(telecom);
        assertEquals(3, DefaultCallAccount.snapshot(context).accounts().size());
        DefaultCallAccount.select(context, DefaultCallAccount.snapshot(context).accounts().get(2));
        telecom.enabled = List.of(three, one, two);
        assertEquals(three, DefaultCallAccount.dialExtras(context).getParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE));
    }
    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }
    private static void assertEquals(Object expected, Object actual) {
        if (!java.util.Objects.equals(expected, actual)) throw new AssertionError("account selection mismatch");
    }
}
