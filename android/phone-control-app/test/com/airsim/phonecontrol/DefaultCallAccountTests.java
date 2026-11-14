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
        modernLookupFallsBackOnlyToExactAccount();
        smsSelectionDistinguishesMissingAndUnmapped();
        authorizedResolverPreservesExactKeyAndPermissionGate();
        supportsMoreThanTwoAccountsAndKeepsIdentityAcrossReordering();
        telecomNumbersSurviveSubscriptionFailureWithoutCrossingAccounts();
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

    private static void modernLookupFallsBackOnlyToExactAccount() {
        int version = Build.VERSION.SDK_INT;
        try {
            Build.VERSION.SDK_INT = 31;
            PhoneAccountHandle one = handle("opaque-one"), two = handle("opaque-two"), missing = handle("7");
            Context context = context(telecom(one, two, missing));
            context.setSystemService(TelephonyManager.class, new TelephonyManager() {
                @Override public int getSubscriptionId(PhoneAccountHandle handle) {
                    if (handle.equals(one)) throw new IllegalStateException("OEM lookup unavailable");
                    return -1;
                }
                @Override public TelephonyManager createForPhoneAccountHandle(PhoneAccountHandle handle) {
                    if (handle.equals(missing)) return null;
                    TelephonyManager scoped = new TelephonyManager();
                    scoped.subscriptionId = handle.equals(one) ? 42 : 73;
                    return scoped;
                }
            });
            var accounts = DefaultCallAccount.snapshot(context).accounts();
            assertEquals(42, accounts.get(0).subscriptionId());
            assertEquals(73, accounts.get(1).subscriptionId());
            assertEquals(-1, accounts.get(2).subscriptionId());
            context.setSystemService(TelephonyManager.class, new TelephonyManager() {
                @Override public int getSubscriptionId(PhoneAccountHandle handle) { throw new SecurityException("denied"); }
                @Override public TelephonyManager createForPhoneAccountHandle(PhoneAccountHandle handle) { throw new SecurityException("denied"); }
            });
            assertEquals(-1, DefaultCallAccount.snapshot(context).accounts().get(0).subscriptionId());
        } finally { Build.VERSION.SDK_INT = version; }
    }

    private static void smsSelectionDistinguishesMissingAndUnmapped() {
        PhoneAccountHandle one = handle("one"), two = handle("two");
        var snapshot = new DefaultCallAccount.Snapshot(List.of(
                new DefaultCallAccount.Account("one", "SIM 1", "", one, 0, 42, "", false, false, false),
                new DefaultCallAccount.Account("two", "SIM 2", "", two, 1, 73, "", false, false, false)), "");
        assertEquals(73, DefaultCallAccount.smsSubscription(snapshot, "two"));
        assertEquals(42, DefaultCallAccount.smsSubscription(snapshot, "one"));
        try { DefaultCallAccount.smsSubscription(snapshot, "removed"); throw new AssertionError("missing accepted"); }
        catch (IllegalStateException e) { assertTrue(e.getMessage().contains("移除")); }
        var unmapped = new DefaultCallAccount.Snapshot(List.of(
                new DefaultCallAccount.Account("two", "SIM 2", "", two)), "");
        try { DefaultCallAccount.smsSubscription(unmapped, "two"); throw new AssertionError("unmapped accepted"); }
        catch (IllegalStateException e) { assertTrue(e.getMessage().contains("仍存在")); }
        try { DefaultCallAccount.smsSubscription(new DefaultCallAccount.Snapshot(List.of(), "权限不可用"), "two");
            throw new AssertionError("permission denied accepted"); }
        catch (IllegalStateException e) { assertEquals("权限不可用", e.getMessage()); }
    }

    private static void authorizedResolverPreservesExactKeyAndPermissionGate() {
        Context context = context(telecom(handle("opaque-one"), handle("opaque-two")));
        var original = DefaultCallAccount.snapshot(context).accounts();
        java.util.List<String> requested = new java.util.ArrayList<>();
        try {
            DefaultCallAccount.setSubscriptionResolver(key -> {
                requested.add(key);
                return key.equals(original.get(1).key()) ? 73 : -1;
            });
            var resolved = DefaultCallAccount.snapshot(context).accounts();
            assertEquals(-1, resolved.get(0).subscriptionId());
            assertEquals(73, resolved.get(1).subscriptionId());
            assertEquals(List.of(original.get(0).key(), original.get(1).key()), requested);
            context.revoke(Manifest.permission.READ_PHONE_STATE);
            requested.clear();
            assertTrue(!DefaultCallAccount.snapshot(context).error().isEmpty());
            assertTrue(requested.isEmpty());
        } finally { DefaultCallAccount.setSubscriptionResolver(null); }
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

    private static void telecomNumbersSurviveSubscriptionFailureWithoutCrossingAccounts() {
        PhoneAccountHandle one = handle("opaque-one"), two = handle("opaque-two");
        TelecomManager telecom = telecom(one, two);
        telecom.accounts.put(one, new PhoneAccount(one, "SIM 1", PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION,
                android.net.Uri.parse("tel:+10000000001"), null));
        telecom.accounts.put(two, new PhoneAccount(two, "SIM 2", PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION,
                android.net.Uri.parse("tel:+10000000002"), android.net.Uri.parse("tel:+10000000003")));
        Context context = context(telecom);
        context.setSystemService(TelephonyManager.class, new TelephonyManager() {
            @Override public int getSubscriptionId(PhoneAccountHandle handle) { throw new IllegalStateException("OEM service unavailable"); }
        });
        var denied = DefaultCallAccount.snapshot(context);
        assertEquals("", denied.accounts().get(0).number());
        assertEquals("", denied.accounts().get(1).number());
        context.grant(Manifest.permission.READ_PHONE_NUMBERS);
        var snapshot = DefaultCallAccount.snapshot(context);
        assertEquals("+10000000001", snapshot.accounts().get(0).number());
        assertEquals("+10000000003", snapshot.accounts().get(1).number());
        assertEquals(-1, snapshot.accounts().get(0).subscriptionId());
        assertEquals(-1, snapshot.accounts().get(1).slotIndex());
        telecom.enabled = List.of(two, one);
        assertEquals("+10000000003", DefaultCallAccount.snapshot(context).accounts().get(0).number());
        telecom.accounts.put(two, new PhoneAccount(two, "SIM 2", PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION,
                android.net.Uri.parse("sip:someone@example.invalid"), android.net.Uri.parse("tel:")));
        assertEquals("", DefaultCallAccount.snapshot(context).accounts().get(0).number());
        context.revoke(Manifest.permission.READ_PHONE_NUMBERS);
        assertEquals("", DefaultCallAccount.snapshot(context).accounts().get(1).number());
    }
    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }
    private static void assertEquals(Object expected, Object actual) {
        if (!java.util.Objects.equals(expected, actual)) throw new AssertionError("account selection mismatch");
    }
}
