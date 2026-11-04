package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.provider.Settings;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Locale;

/** Stable, non-secret metadata used to distinguish paired Android Agent instances. */
public final class AndroidAgentIdentity {
    private AndroidAgentIdentity() {}

    public static String agentID(Context context) {
        String androidID = Settings.Secure.getString(
                context.getContentResolver(), Settings.Secure.ANDROID_ID);
        String source = context.getPackageName() + ":" + (androidID == null ? "unknown" : androidID);
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(source.getBytes(StandardCharsets.UTF_8));
            StringBuilder value = new StringBuilder("android-");
            for (int index = 0; index < 12; index++) {
                value.append(String.format(Locale.ROOT, "%02x", digest[index]));
            }
            return value.toString();
        } catch (Exception ignored) {
            return "android-" + Integer.toUnsignedString(source.hashCode(), 16);
        }
    }

    public static String deviceName() {
        String manufacturer = clean(Build.MANUFACTURER);
        String model = clean(Build.MODEL);
        if (manufacturer.isEmpty()) return model;
        if (model.toLowerCase(Locale.ROOT).startsWith(manufacturer.toLowerCase(Locale.ROOT))) {
            return model;
        }
        return (manufacturer + " " + model).trim();
    }

    public static String phoneNumber(Context context) {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS)
                != PackageManager.PERMISSION_GRANTED
                || context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                != PackageManager.PERMISSION_GRANTED) return "";
        var snapshot = DefaultCallAccount.snapshot(context);
        String selected = DefaultCallAccount.selectedKey(context);
        if (!selected.isEmpty()) {
            for (DefaultCallAccount.Account account : snapshot.accounts()) {
                if (selected.equals(account.key())) return currentNumber(context, account);
            }
            // Removed/disabled explicit selection must never borrow another SIM.
            return "";
        }
        try {
            var telecom = context.getSystemService(android.telecom.TelecomManager.class);
            var handle = telecom == null ? null : telecom.getDefaultOutgoingPhoneAccount("tel");
            if (handle != null) {
                for (var account : snapshot.accounts()) {
                    if (handle.equals(account.handle())) return currentNumber(context, account);
                }
            }
        } catch (RuntimeException ignored) {
            // Continue with subscription-scoped lookup when Telecom cannot resolve it.
        }
        try {
            SubscriptionManager manager = context.getSystemService(SubscriptionManager.class);
            List<SubscriptionInfo> subscriptions = manager == null ? null : manager.getActiveSubscriptionInfoList();
            if (subscriptions != null) {
                int defaultVoice = SubscriptionManager.getDefaultVoiceSubscriptionId();
                SubscriptionInfo chosen = null;
                for (SubscriptionInfo subscription : subscriptions) {
                    if (subscription.getSubscriptionId() == defaultVoice) chosen = subscription;
                }
                if (chosen == null && subscriptions.size() == 1) chosen = subscriptions.get(0);
                if (chosen != null) {
                    int id = chosen.getSubscriptionId();
                    String value = "";
                    try { value = clean(Build.VERSION.SDK_INT >= 33 ? manager.getPhoneNumber(id) : chosen.getNumber()); }
                    catch (RuntimeException ignored) { }
                    return value.isEmpty() ? DefaultCallAccount.scopedNumber(context, id) : value;
                }
            }
        } catch (RuntimeException ignored) {
            // OEM subscription failures must not hide an available Telecom number.
        }
        return snapshot.accounts().size() == 1 ? currentNumber(context, snapshot.accounts().get(0)) : "";
    }

    private static String currentNumber(Context context, DefaultCallAccount.Account account) {
        String value = clean(account.number());
        return value.isEmpty() ? DefaultCallAccount.scopedNumber(context, account.subscriptionId()) : value;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
