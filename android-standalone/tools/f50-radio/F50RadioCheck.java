package com.airsim.tools;

import android.content.Context;
import android.os.Build;
import android.os.Looper;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import org.json.JSONArray;
import org.json.JSONObject;
import java.lang.reflect.Method;

/** Temporary adb-shell diagnostic. No server, receiver, credentials or boot hook. */
public final class F50RadioCheck {
    interface Read { Object get() throws Exception; }
    static void add(JSONObject out, String name, Read read) throws Exception {
        try { out.put(name, read.get()); }
        catch (Exception error) {
            Throwable cause = error.getCause() == null ? error : error.getCause();
            out.put(name + "_error", cause.getClass().getSimpleName());
        }
    }
    static Object invoke(Object owner, String method) throws Exception {
        return owner.getClass().getMethod(method).invoke(owner);
    }
    public static void main(String[] args) {
        try { run(args); System.exit(0); }
        catch (Throwable error) {
            Throwable cause = error.getCause() == null ? error : error.getCause();
            System.err.println("radio diagnostic failed: " + cause);
            System.exit(1);
        }
    }
    static void run(String[] args) throws Exception {
        if (android.os.Process.myUid() != 2000 || !"MU3356".equals(Build.MODEL))
            throw new SecurityException("Only the verified MU3356 adb shell is supported");
        if (Looper.myLooper() == null) Looper.prepareMainLooper();
        // Bare app_process does not inherit the zygote telephony initializer.
        Class<?> initializer = Class.forName("android.telephony.TelephonyFrameworkInitializer");
        if (initializer.getMethod("getTelephonyServiceManager").invoke(null) == null) {
            Class<?> manager = Class.forName("android.os.TelephonyServiceManager");
            initializer.getMethod("setTelephonyServiceManager", manager)
                    .invoke(null, manager.getConstructor().newInstance());
        }
        Class<?> type = Class.forName("android.app.ActivityThread");
        Object thread = type.getMethod("systemMain").invoke(null);
        Context system = (Context) type.getMethod("getSystemContext").invoke(thread);
        Context context = system.createPackageContext("com.android.shell", 0);
        var op = context.getClass().getDeclaredField("mOpPackageName");
        op.setAccessible(true); op.set(context, "com.android.shell");
        var attribution = context.getClass().getDeclaredField("mAttributionSource");
        attribution.setAccessible(true);
        attribution.set(context, new android.content.AttributionSource.Builder(2000)
                .setPackageName("com.android.shell").build());
        var subscriptions = context.getSystemService(SubscriptionManager.class)
                .getActiveSubscriptionInfoList();
        if (subscriptions == null) throw new IllegalStateException("No active subscriptions");
        TelephonyManager base = context.getSystemService(TelephonyManager.class);
        String action = args.length == 0 ? "status" : args[0];
        if (!"status".equals(action)) {
            if (args.length < 2) throw new IllegalArgumentException("Explicit UK subscription required");
            int subId = Integer.parseInt(args[1]);
            SubscriptionInfo target = subscriptions.stream().filter(s -> s.getSubscriptionId() == subId)
                    .findFirst().orElseThrow(() -> new IllegalArgumentException("Inactive subscription"));
            TelephonyManager phone = base.createForSubscriptionId(subId);
            boolean restoreHK = "restore-hk-data".equals(action);
            if (restoreHK ? (!"hk".equalsIgnoreCase(target.getCountryIso()) || !"45400".equals(phone.getSimOperator()))
                    : (!"gb".equalsIgnoreCase(target.getCountryIso()) || !"23433".equals(phone.getSimOperator())))
                throw new SecurityException("Target is not the verified " + (restoreHK ? "HK restoration" : "UK network") + " subscription");
            for (SubscriptionInfo info : subscriptions)
                if (base.createForSubscriptionId(info.getSubscriptionId()).getCallState() != TelephonyManager.CALL_STATE_IDLE)
                    throw new IllegalStateException("A call is in progress");
            JSONObject result = new JSONObject().put("action", action).put("subscription", subId);
            switch (action) {
                case "roaming" -> {
                    if (args.length != 3 || !("true".equals(args[2]) || "false".equals(args[2])))
                        throw new IllegalArgumentException("roaming requires true or false");
                    Method setter = TelephonyManager.class.getMethod("setDataRoamingEnabled", boolean.class);
                    setter.invoke(phone, Boolean.parseBoolean(args[2]));
                    result.put("enabled", invoke(phone, "isDataRoamingEnabled"));
                }
                case "select-cmhk" -> result.put("accepted", phone.setNetworkSelectionModeManual("45412", false));
                case "automatic" -> { phone.setNetworkSelectionModeAutomatic(); result.put("requested", true); }
                case "data-enabled" -> {
                    if (args.length != 3 || !("true".equals(args[2]) || "false".equals(args[2])))
                        throw new IllegalArgumentException("data-enabled requires true or false");
                    phone.setDataEnabledForReason(TelephonyManager.DATA_ENABLED_REASON_USER, Boolean.parseBoolean(args[2]));
                    result.put("requested", Boolean.parseBoolean(args[2]));
                }
                case "default-data", "restore-hk-data" -> {
                    SubscriptionManager.class.getMethod("setDefaultDataSubId", int.class)
                            .invoke(context.getSystemService(SubscriptionManager.class), subId);
                    result.put("requested", true);
                }
                default -> throw new IllegalArgumentException("Unsupported action");
            }
            System.out.println(result);
            return;
        }
        JSONArray rows = new JSONArray();
        for (SubscriptionInfo info : subscriptions) {
            TelephonyManager phone = base.createForSubscriptionId(info.getSubscriptionId());
            JSONObject row = new JSONObject().put("subscription", info.getSubscriptionId())
                    .put("slot", info.getSimSlotIndex()).put("country", info.getCountryIso());
            add(row, "sim_operator", phone::getSimOperator);
            add(row, "network_operator", phone::getNetworkOperator);
            add(row, "network_name", phone::getNetworkOperatorName);
            add(row, "selection_mode", phone::getNetworkSelectionMode);
            add(row, "roaming_enabled", () -> invoke(phone, "isDataRoamingEnabled"));
            add(row, "data_enabled", phone::isDataEnabled);
            add(row, "voice_type", phone::getVoiceNetworkType);
            add(row, "data_type", phone::getDataNetworkType);
            add(row, "ims_registered", () -> invoke(phone, "isImsRegistered"));
            add(row, "data_connection_allowed", () -> invoke(phone, "isDataConnectionAllowed"));
            add(row, "radio_power", () -> invoke(phone, "getRadioPowerState"));
            add(row, "allowed_user", () -> phone.getAllowedNetworkTypesForReason(TelephonyManager.ALLOWED_NETWORK_TYPES_REASON_USER));
            add(row, "allowed_carrier", () -> phone.getAllowedNetworkTypesForReason(TelephonyManager.ALLOWED_NETWORK_TYPES_REASON_CARRIER));
            add(row, "supported_raf", () -> invoke(phone, "getSupportedRadioAccessFamily"));
            rows.put(row);
        }
        System.out.println(new JSONObject().put("subscriptions", rows)
                .put("default_voice", SubscriptionManager.getDefaultVoiceSubscriptionId())
                .put("default_data", SubscriptionManager.getDefaultDataSubscriptionId()));
    }
}
