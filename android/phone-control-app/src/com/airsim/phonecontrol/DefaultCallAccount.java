package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.telecom.PhoneAccountHandle;
import android.telecom.PhoneAccount;
import android.telecom.TelecomManager;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import java.util.ArrayList;
import java.util.List;

/** App-local outgoing account preference; never changes the system default. */
public final class DefaultCallAccount {
    public record Account(String key, String label, String number, PhoneAccountHandle handle,
                          int slotIndex, int subscriptionId, String carrierName,
                          boolean embedded, boolean defaultVoice, boolean defaultSms) {
        public Account(String key, String label, String number, PhoneAccountHandle handle) {
            this(key, label, number, handle, -1, -1, "", false, false, false);
        }
    }
    public record Snapshot(List<Account> accounts, String error) {}
    private static final String SYSTEM = "跟随系统默认";
    private DefaultCallAccount() {}

    private static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences("default_call_account", Context.MODE_PRIVATE);
    }

    public static Snapshot snapshot(Context context) {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                != PackageManager.PERMISSION_GRANTED) {
            return new Snapshot(List.of(), "请授权电话状态权限后选择通话卡");
        }
        try {
            TelecomManager telecom = context.getSystemService(TelecomManager.class);
            if (telecom == null) return new Snapshot(List.of(), "系统电话服务不可用");
            List<Account> accounts = new ArrayList<>();
            for (PhoneAccountHandle handle : telecom.getCallCapablePhoneAccounts()) {
                PhoneAccount account = telecom.getPhoneAccount(handle);
                if (account == null || !account.hasCapabilities(PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION)) continue;
                String label = account.getLabel() == null ? "蜂窝通话卡" : account.getLabel().toString();
                String number = "";
                int slotIndex = -1;
                int subscriptionId = -1;
                String carrierName = "";
                boolean embedded = false;
                boolean defaultVoice = false;
                boolean defaultSms = false;
                // Metadata is optional. Never infer subscription IDs from opaque Telecom IDs.
                try {
                    TelephonyManager telephony = context.getSystemService(TelephonyManager.class);
                    SubscriptionManager subscriptions = context.getSystemService(SubscriptionManager.class);
                    if (telephony != null) {
                        if (Build.VERSION.SDK_INT >= 30) subscriptionId = telephony.getSubscriptionId(handle);
                        else {
                            TelephonyManager specific = telephony.createForPhoneAccountHandle(handle);
                            if (specific != null) subscriptionId = Integer.parseInt(specific.getNetworkSpecifier());
                        }
                    }
                    if (subscriptions != null && subscriptionId >= 0) {
                        SubscriptionInfo info = subscriptions.getActiveSubscriptionInfo(subscriptionId);
                        if (info != null) {
                            slotIndex = info.getSimSlotIndex();
                            embedded = info.isEmbedded();
                            CharSequence carrier = info.getCarrierName();
                            carrierName = carrier == null ? "" : carrier.toString();
                            String slot = slotIndex >= 0 ? " " + (slotIndex + 1) : "";
                            label = (embedded ? "eSIM" : "SIM") + slot + " · "
                                    + (carrierName.isEmpty() ? label : carrierName);
                            defaultVoice = subscriptionId == SubscriptionManager.getDefaultVoiceSubscriptionId();
                            // Resolved by SimSlotJson (Android-only) without
                            // pulling SmsManager into the JVM core test classpath.
                            defaultSms = false;
                            if (context.checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS)
                                    == PackageManager.PERMISSION_GRANTED) {
                                number = Build.VERSION.SDK_INT >= 33
                                        ? subscriptions.getPhoneNumber(subscriptionId) : info.getNumber();
                            }
                        }
                    }
                } catch (RuntimeException ignored) {
                    // A missing number or OEM metadata restriction must not block an enabled account.
                }
                if (context.checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS)
                        == PackageManager.PERMISSION_GRANTED && (number == null || number.trim().isEmpty())) {
                    // Telecom can expose this exact SIM's number even when the OEM
                    // subscription service is unavailable. Never infer a subscription
                    // from the opaque handle, slot order or another card's number.
                    number = accountNumber(account);
                    if (number.isEmpty()) number = scopedNumber(context, subscriptionId);
                }
                String key = handle.getComponentName().flattenToString() + "\n"
                        + handle.getId() + "\n" + handle.getUserHandle();
                accounts.add(new Account(key, label, number == null ? "" : number, handle,
                        slotIndex, subscriptionId, carrierName, embedded, defaultVoice, defaultSms));
            }
            return new Snapshot(List.copyOf(accounts), "");
        } catch (RuntimeException error) {
            return new Snapshot(List.of(), "无法读取通话卡，请检查电话状态权限及系统设置");
        }
    }

    private static String accountNumber(PhoneAccount account) {
        try {
            String number = telephoneAddress(account.getSubscriptionAddress());
            return number.isEmpty() ? telephoneAddress(account.getAddress()) : number;
        } catch (RuntimeException ignored) { return ""; }
    }

    private static String telephoneAddress(android.net.Uri address) {
        if (address == null || !"tel".equalsIgnoreCase(address.getScheme())) return "";
        String value = address.getSchemeSpecificPart();
        return value == null ? "" : value.trim();
    }

    static String scopedNumber(Context context, int subscriptionId) {
        if (subscriptionId < 0 || context.checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS)
                != PackageManager.PERMISSION_GRANTED) return "";
        try {
            TelephonyManager manager = context.getSystemService(TelephonyManager.class);
            if (manager == null) return "";
            TelephonyManager scoped = manager.createForSubscriptionId(subscriptionId);
            String value = scoped == null ? null : scoped.getLine1Number();
            return value == null ? "" : value.trim();
        } catch (RuntimeException ignored) { return ""; }
    }

    public static int slotIndex(Context context, PhoneAccountHandle handle) {
        if (handle == null) return -1;
        Snapshot snapshot = snapshot(context);
        if (!snapshot.error().isEmpty()) return -1;
        for (Account account : snapshot.accounts()) {
            if (handle.equals(account.handle())) return account.slotIndex();
        }
        return -1;
    }

    public static String selectedKey(Context context) {
        return preferences(context).getString("key", "");
    }
    public static String selectedLabel(Context context) {
        return selectedKey(context).isEmpty() ? SYSTEM : preferences(context).getString("label", "蜂窝通话卡");
    }
    public static void select(Context context, Account account) {
        preferences(context).edit().putString("key", account.key()).putString("label", account.label()).apply();
    }
    public static void followSystem(Context context) {
        preferences(context).edit().putString("key", "").putString("label", SYSTEM).apply();
    }
    public static Bundle dialExtras(Context context) {
        return dialExtras(context, "");
    }

    /** Optional per-call override from the paired iPhone; empty keeps the app default. */
    public static Bundle dialExtras(Context context, String overrideKey) {
        Bundle extras = new Bundle();
        String key = overrideKey == null ? "" : overrideKey.trim();
        if (key.isEmpty()) key = selectedKey(context);
        if (key.isEmpty()) return extras;
        Snapshot snapshot = snapshot(context);
        if (!snapshot.error().isEmpty()) throw new IllegalStateException(snapshot.error());
        for (Account account : snapshot.accounts()) {
            if (key.equals(account.key())) {
                extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account.handle());
                return extras;
            }
        }
        throw new IllegalStateException("所选通话卡已关闭或移除，请在 iPhone 上重新选择");
    }


}
