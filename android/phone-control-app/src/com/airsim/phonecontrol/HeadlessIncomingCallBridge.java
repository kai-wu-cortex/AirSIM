package com.airsim.phonecontrol;

import android.content.ComponentName;
import android.content.Context;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.telephony.PhoneStateListener;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import android.util.Log;

import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

/**
 * Bridges incoming IMS/PSTN calls into Android Telecom on data-centric firmware
 * (such as ZTE F50 Pro MU3356) where framework-res config_voice_capable=false.
 *
 * When config_voice_capable=false, Phone.notifyNewRingingConnectionP() returns
 * early, so PstnIncomingCallNotifier never calls TelecomManager.addNewIncomingCall().
 * However, ImsPhoneCallTracker.onIncomingCall() still attaches the ringing
 * ImsPhoneConnection to ImsPhone.mRingingCall and calls updatePhoneState() ->
 * DefaultPhoneNotifier.notifyPhoneState() -> TelephonyRegistry.notifyCallState()
 * for the active subscription ID.
 *
 * By registering AirSIMCallManagerService as the default dialer's SIM Call Manager
 * (from UID 2000 which holds MODIFY_PHONE_STATE) and listening per-subId for
 * CALL_STATE_RINGING, AirSIM invokes TelecomManager.addNewIncomingCall() with the
 * PSTN PhoneAccountHandle so TelephonyConnectionService.onCreateIncomingConnection()
 * attaches the ringing ImsPhoneConnection to Telecom and AirSIMInCallService.
 */
@SuppressWarnings("deprecation")
public final class HeadlessIncomingCallBridge {
    private static final String TAG = "AirSIMIncomingBridge";
    private static final String SIM_CALL_MANAGER_ID = "airsim_sim_call_manager";
    private static final String PSTN_PACKAGE = "com.android.phone";
    private static final String PSTN_CLASS = "com.android.services.telephony.TelephonyConnectionService";
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Map<Integer, SubCallStateListener> LISTENERS = new HashMap<>();
    private static final Map<Integer, Integer> LAST_STATE = new ConcurrentHashMap<>();
    private static volatile long lastBridgedAtElapsedMillis;
    private static volatile boolean subscriptionCallbackRegistered;

    private HeadlessIncomingCallBridge() {}

    /**
     * Invoked from UID 2000 (RootBridgeMain / ShizukuBridgeUserService) to register
     * AirSIMCallManagerService as the CAPABILITY_CONNECTION_MANAGER PhoneAccount.
     */
    public static void ensureSimCallManagerRegistered(Context context, String targetPackage) {
        if (context == null || targetPackage == null || targetPackage.isEmpty()) return;
        try {
            TelecomManager tm = context.getSystemService(TelecomManager.class);
            if (tm == null) {
                Context shell = context.createPackageContext("com.android.shell", 0);
                tm = shell.getSystemService(TelecomManager.class);
            }
            if (tm != null) {
                ComponentName component = new ComponentName(
                        targetPackage, "com.airsim.phonecontrol.AirSIMCallManagerService");
                PhoneAccountHandle handle = new PhoneAccountHandle(
                        component, SIM_CALL_MANAGER_ID, Process.myUserHandle());
                PhoneAccount account = PhoneAccount.builder(handle, "AirSIM Call Manager")
                        .setCapabilities(PhoneAccount.CAPABILITY_CONNECTION_MANAGER)
                        .build();
                tm.registerPhoneAccount(account);
                Log.i(TAG, "sim_call_manager_registered pkg=" + targetPackage);
            }
        } catch (Throwable error) {
            Log.w(TAG, "sim_call_manager_register_failed: " + error);
        }
        grantRuntimePermissionQuietly(targetPackage, "android.permission.READ_CALL_LOG");
        grantRuntimePermissionQuietly(targetPackage, "android.permission.READ_PHONE_STATE");
        grantRuntimePermissionQuietly(targetPackage, "android.permission.ANSWER_PHONE_CALLS");
    }

    private static void grantRuntimePermissionQuietly(String targetPackage, String permission) {
        try {
            java.lang.Process p = new ProcessBuilder("pm", "grant", targetPackage, permission)
                    .redirectErrorStream(true)
                    .start();
            p.waitFor(2, TimeUnit.SECONDS);
        } catch (Throwable ignored) {}
    }

    /**
     * Ensures per-subscription call state listeners are active when running on
     * firmware where TelephonyManager.isVoiceCapable() is false.
     */
    public static void ensureStarted(Context context) {
        if (context == null) return;
        final Context appContext = context.getApplicationContext() != null
                ? context.getApplicationContext() : context;
        TelephonyManager tm = appContext.getSystemService(TelephonyManager.class);
        if (tm == null || tm.isVoiceCapable()) return;
        MAIN.post(() -> registerListenersOnMain(appContext));
    }

    private static void registerListenersOnMain(Context appContext) {
        try {
            TelephonyManager baseTm = appContext.getSystemService(TelephonyManager.class);
            if (baseTm == null || baseTm.isVoiceCapable()) return;
            Set<Integer> subIds = discoverCandidateSubIds(appContext);
            for (Integer subId : subIds) {
                if (subId == null || subId <= 0 || LISTENERS.containsKey(subId)) continue;
                try {
                    TelephonyManager subTm = baseTm.createForSubscriptionId(subId);
                    if (subTm == null) continue;
                    SubCallStateListener listener = new SubCallStateListener(appContext, subId);
                    subTm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE);
                    LISTENERS.put(subId, listener);
                    BridgeLog.info("headless_incoming_listener_registered sub_id=" + subId);
                } catch (Throwable error) {
                    BridgeLog.error("headless_incoming_listener_failed sub_id=" + subId, error);
                }
            }
            if (!subscriptionCallbackRegistered) {
                SubscriptionManager sm = appContext.getSystemService(SubscriptionManager.class);
                if (sm != null) {
                    sm.addOnSubscriptionsChangedListener(new SubscriptionManager.OnSubscriptionsChangedListener() {
                        @Override
                        public void onSubscriptionsChanged() {
                            registerListenersOnMain(appContext);
                        }
                    });
                    subscriptionCallbackRegistered = true;
                }
            }
        } catch (Throwable error) {
            BridgeLog.error("headless_incoming_setup_failed", error);
        }
    }

    private static Set<Integer> discoverCandidateSubIds(Context context) {
        Set<Integer> result = new HashSet<>();
        for (int candidate = 1; candidate <= 8; candidate++) {
            result.add(candidate);
        }
        addIfValidSubId(result, SubscriptionManager.getDefaultSubscriptionId());
        addIfValidSubId(result, SubscriptionManager.getDefaultVoiceSubscriptionId());
        addIfValidSubId(result, SubscriptionManager.getDefaultDataSubscriptionId());
        addIfValidSubId(result, SubscriptionManager.getDefaultSmsSubscriptionId());
        try {
            SubscriptionManager sm = context.getSystemService(SubscriptionManager.class);
            if (sm != null) {
                List<SubscriptionInfo> infos = sm.getActiveSubscriptionInfoList();
                if (infos != null) {
                    for (SubscriptionInfo info : infos) {
                        if (info != null) addIfValidSubId(result, info.getSubscriptionId());
                    }
                }
            }
        } catch (SecurityException ignored) {}
        try {
            TelecomManager telecom = context.getSystemService(TelecomManager.class);
            if (telecom != null) {
                List<PhoneAccountHandle> accounts = telecom.getCallCapablePhoneAccounts();
                if (accounts != null) {
                    for (PhoneAccountHandle handle : accounts) {
                        if (handle == null || handle.getId() == null) continue;
                        try {
                            addIfValidSubId(result, Integer.parseInt(handle.getId().trim()));
                        } catch (NumberFormatException ignored) {}
                    }
                }
            }
        } catch (SecurityException ignored) {}
        return result;
    }

    private static void addIfValidSubId(Set<Integer> set, int subId) {
        if (subId > 0 && subId != Integer.MAX_VALUE) {
            set.add(subId);
        }
    }

    private static final class SubCallStateListener extends PhoneStateListener {
        private final Context appContext;
        private final int subId;

        SubCallStateListener(Context appContext, int subId) {
            this.appContext = appContext;
            this.subId = subId;
        }

        @Override
        public void onCallStateChanged(int state, String incomingNumber) {
            Integer previous = LAST_STATE.put(subId, state);
            if (state != TelephonyManager.CALL_STATE_RINGING) return;
            if (previous != null && previous == TelephonyManager.CALL_STATE_RINGING) return;
            onRingingDetected(appContext, subId, incomingNumber);
        }
    }

    private static void onRingingDetected(Context context, int subId, String incomingNumber) {
        long now = SystemClock.elapsedRealtime();
        if (!"idle".equals(CallRepository.diagnosticState())) {
            BridgeLog.info("headless_incoming_ignored_already_in_telecom sub_id=" + subId
                    + " state=" + CallRepository.diagnosticState());
            return;
        }
        if (now - lastBridgedAtElapsedMillis < 2_500L) {
            BridgeLog.info("headless_incoming_deduped sub_id=" + subId);
            return;
        }
        lastBridgedAtElapsedMillis = now;
        try {
            TelecomManager telecom = context.getSystemService(TelecomManager.class);
            if (telecom == null) return;
            PhoneAccountHandle pstnHandle = resolvePstnAccountHandle(telecom, subId);
            Bundle extras = new Bundle();
            if (incomingNumber != null && !incomingNumber.trim().isEmpty()) {
                extras.putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                        Uri.fromParts("tel", incomingNumber.trim(), null));
            }
            extras.putLong("android.telecom.extra.CALL_CREATED_TIME_MILLIS", now);
            try {
                telecom.addNewIncomingCall(pstnHandle, extras);
                BridgeLog.info("headless_incoming_call_bridged sub_id=" + subId
                        + " account_id=" + pstnHandle.getId());
            } catch (SecurityException securityError) {
                BridgeLog.error("headless_incoming_security_retry sub_id=" + subId, securityError);
                ShizukuBridgeManager.get(context).ensureDialerRole(false, (granted, message) -> {
                    if (granted) {
                        try {
                            telecom.addNewIncomingCall(pstnHandle, extras);
                            BridgeLog.info("headless_incoming_call_bridged_after_retry sub_id=" + subId
                                    + " account_id=" + pstnHandle.getId());
                        } catch (Throwable retryError) {
                            BridgeLog.error("headless_incoming_retry_failed sub_id=" + subId, retryError);
                        }
                    }
                });
            }
        } catch (Throwable error) {
            BridgeLog.error("headless_incoming_bridge_failed sub_id=" + subId, error);
        }
    }

    private static PhoneAccountHandle resolvePstnAccountHandle(TelecomManager telecom, int subId) {
        String targetId = Integer.toString(subId);
        PhoneAccountHandle fallbackPstn = null;
        try {
            List<PhoneAccountHandle> accounts = telecom.getCallCapablePhoneAccounts();
            if (accounts != null) {
                for (PhoneAccountHandle handle : accounts) {
                    if (handle == null || handle.getComponentName() == null) continue;
                    if (!PSTN_PACKAGE.equals(handle.getComponentName().getPackageName())) continue;
                    if (targetId.equals(handle.getId())) return handle;
                    if (fallbackPstn == null) fallbackPstn = handle;
                }
            }
        } catch (SecurityException ignored) {}
        if (fallbackPstn != null) return fallbackPstn;
        return new PhoneAccountHandle(
                new ComponentName(PSTN_PACKAGE, PSTN_CLASS),
                targetId,
                Process.myUserHandle());
    }
}
