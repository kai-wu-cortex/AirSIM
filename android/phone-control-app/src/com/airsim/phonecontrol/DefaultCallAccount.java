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
    public record Account(String key, String label, String number, PhoneAccountHandle handle) {}
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
                // Metadata is optional. Never infer subscription IDs from opaque Telecom IDs.
                try {
                    TelephonyManager telephony = context.getSystemService(TelephonyManager.class);
                    SubscriptionManager subscriptions = context.getSystemService(SubscriptionManager.class);
                    int subscriptionId = -1;
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
                            String slot = info.getSimSlotIndex() >= 0
                                    ? " " + (info.getSimSlotIndex() + 1) : "";
                            CharSequence carrier = info.getCarrierName();
                            label = (info.isEmbedded() ? "eSIM" : "SIM") + slot + " · "
                                    + (carrier == null || carrier.length() == 0 ? label : carrier);
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
                String key = handle.getComponentName().flattenToString() + "\n"
                        + handle.getId() + "\n" + handle.getUserHandle();
                accounts.add(new Account(key, label, number == null ? "" : number, handle));
            }
            return new Snapshot(List.copyOf(accounts), "");
        } catch (RuntimeException error) {
            return new Snapshot(List.of(), "无法读取通话卡，请检查电话状态权限及系统设置");
        }
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
        Bundle extras = new Bundle();
        String key = selectedKey(context);
        if (key.isEmpty()) return extras;
        Snapshot snapshot = snapshot(context);
        if (!snapshot.error().isEmpty()) throw new IllegalStateException(snapshot.error());
        for (Account account : snapshot.accounts()) {
            if (key.equals(account.key())) {
                extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account.handle());
                return extras;
            }
        }
        throw new IllegalStateException("默认通话卡已关闭或移除，请在 AirSIM 设置中重新选择");
    }
}
