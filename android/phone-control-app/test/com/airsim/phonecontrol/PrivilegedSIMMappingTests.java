package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.ComponentName;
import android.os.Binder;
import android.os.Build;
import android.os.Process;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import android.telephony.SmsManager;
import java.util.List;

/** Exercises the real service's read-only resolver; no SMS send method is called. */
public final class PrivilegedSIMMappingTests {
    public static void main(String[] args) throws Exception {
        Process.uid = 0; // privileged context, avoids shell package reflection in JVM fixtures
        for (int sdk : new int[]{29, 31}) {
            Build.VERSION.SDK_INT = sdk;
            Context context = new Context();
            context.grant(Manifest.permission.READ_PHONE_STATE);
            var first = new PhoneAccountHandle(new ComponentName("phone", "Service"), "opaque-first");
            var second = new PhoneAccountHandle(new ComponentName("phone", "Service"), "opaque-second");
            TelecomManager telecom = new TelecomManager();
            telecom.enabled = List.of(first, second);
            for (var handle : telecom.enabled) telecom.accounts.put(handle,
                    new PhoneAccount(handle, "SIM", PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION));
            context.setSystemService(TelecomManager.class, telecom);
            context.setSystemService(TelephonyManager.class, new TelephonyManager() {
                @Override public int getSubscriptionId(PhoneAccountHandle handle) { return handle.equals(second) ? 73 : 42; }
                @Override public TelephonyManager createForPhoneAccountHandle(PhoneAccountHandle handle) {
                    var manager = new TelephonyManager(); manager.subscriptionId = getSubscriptionId(handle); return manager;
                }
            });
            var subscriptions = new SubscriptionManager();
            var one = new SubscriptionInfo(); one.subscriptionId = 42;
            var two = new SubscriptionInfo(); two.subscriptionId = 73;
            subscriptions.active = List.of(one, two);
            context.setSystemService(SubscriptionManager.class, subscriptions);
            var slots = DefaultCallAccount.snapshot(context).accounts();
            ShizukuBridgeUserService service = new ShizukuBridgeUserService();
            var field = ShizukuBridgeUserService.class.getDeclaredField("serviceContext");
            field.setAccessible(true); field.set(service, context);
            var resolve = ShizukuBridgeUserService.class.getDeclaredMethod("resolveSmsSubscription", String.class);
            resolve.setAccessible(true);
            for (int pass = 0; pass < 2; pass++) {
                telecom.enabled = pass == 0 ? List.of(first, second) : List.of(second, first);
                check("73", resolve.invoke(service, slots.get(1).key()));
                check("42", resolve.invoke(service, slots.get(0).key()));
            }
            check("-1", resolve.invoke(service, "unknown"));
            check("-1", resolve.invoke(service, ""));
            check("-1", resolve.invoke(service, "x".repeat(8193)));
            subscriptions.active = List.of(one);
            check("-1", resolve.invoke(service, slots.get(1).key())); // stale subscription
            telecom.enabled = List.of(first);
            check("-1", resolve.invoke(service, slots.get(1).key())); // removed Telecom account
            context.revoke(Manifest.permission.READ_PHONE_STATE);
            check("-1", resolve.invoke(service, slots.get(0).key()));
            check(0, SmsManager.sends);
            check(Binder.clears, Binder.restores);
        }
        System.out.println("PrivilegedSIMMappingTests passed: exact account, reorder, inactive, removed, permission, no SMS sent");
    }
    private static void check(Object expected, Object actual) {
        if (!java.util.Objects.equals(expected, actual)) throw new AssertionError(expected + " != " + actual);
    }
}
