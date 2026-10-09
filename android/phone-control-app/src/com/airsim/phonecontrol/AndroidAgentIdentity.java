package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.provider.Settings;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Locale;

/** Stable, non-secret metadata used to distinguish paired Android Agent instances. */
final class AndroidAgentIdentity {
    private AndroidAgentIdentity() {}

    static String agentID(Context context) {
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

    static String deviceName() {
        String manufacturer = clean(Build.MANUFACTURER);
        String model = clean(Build.MODEL);
        if (manufacturer.isEmpty()) return model;
        if (model.toLowerCase(Locale.ROOT).startsWith(manufacturer.toLowerCase(Locale.ROOT))) {
            return model;
        }
        return (manufacturer + " " + model).trim();
    }

    static String phoneNumber(Context context) {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS)
                != PackageManager.PERMISSION_GRANTED) return "";
        try {
            SubscriptionManager manager = context.getSystemService(SubscriptionManager.class);
            if (manager != null && context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                    == PackageManager.PERMISSION_GRANTED) {
                List<SubscriptionInfo> subscriptions = manager.getActiveSubscriptionInfoList();
                if (subscriptions != null) {
                    for (SubscriptionInfo subscription : subscriptions) {
                        String value = Build.VERSION.SDK_INT >= 33
                                ? manager.getPhoneNumber(subscription.getSubscriptionId())
                                : subscription.getNumber();
                        if (!clean(value).isEmpty()) return clean(value);
                    }
                }
            }
            TelephonyManager telephony = context.getSystemService(TelephonyManager.class);
            return telephony == null ? "" : clean(telephony.getLine1Number());
        } catch (SecurityException ignored) {
            return "";
        }
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
