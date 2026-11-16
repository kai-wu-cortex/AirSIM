package com.airsim.phonecontrol;

import android.Manifest;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Build;
import android.provider.Telephony;
import android.telephony.SmsManager;
import android.telephony.SubscriptionManager;

import java.util.ArrayList;
import java.util.UUID;

/** Executes an Agent SMS command through the selected Android SIM, not Telecom. */
public final class SMSCommandExecutor {
    private static final long SENT_TIMEOUT_MS = 45_000L;
    private static final String SEGMENT_EXTRA = "segment";

    interface PrivilegedSender {
        String send(String destination, String body, int subscriptionId);
    }

    interface RootSender {
        String send(String destination, String body, int subscriptionId);
    }

    private static volatile PrivilegedSender privilegedSender;
    private static volatile RootSender rootSender;

    static void setPrivilegedSender(PrivilegedSender sender) {
        privilegedSender = sender;
    }

    static void setRootSender(RootSender sender) {
        rootSender = sender;
    }

    private SMSCommandExecutor() {}

    static boolean supportsSystemSMS(Context context) {
        // The split messaging feature was introduced in API 33. Older phones
        // advertise the umbrella telephony feature even when SMS is supported.
        String feature = Build.VERSION.SDK_INT >= 33
                ? PackageManager.FEATURE_TELEPHONY_MESSAGING : PackageManager.FEATURE_TELEPHONY;
        return context.getPackageManager().hasSystemFeature(feature);
    }

    static AgentCommandDispatcher.Result execute(Context context, AgentCommand command) {
        String destination = SMSPayloadPolicy.normalizeDestination(command.number);
        if (destination.isEmpty() || !SMSPayloadPolicy.validBody(command.message)) {
            return AgentCommandDispatcher.Result.failure("号码或短信内容无效");
        }
        if (context.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            return AgentCommandDispatcher.Result.failure("AirSIM 缺少短信发送权限；请在安卓应用权限中允许短信");
        }
        if (!supportsSystemSMS(context)) {
            return AgentCommandDispatcher.Result.failure("此设备不支持系统短信发送");
        }

        try {
            int defaultSubscription = defaultSmsSubscription(context);
            int subscriptionID = defaultSubscription;
            if (!command.simAccount.isEmpty()) {
                try {
                    subscriptionID = DefaultCallAccount.smsSubscription(
                            DefaultCallAccount.snapshot(context), command.simAccount);
                } catch (IllegalStateException error) {
                    return AgentCommandDispatcher.Result.failure(error.getMessage());
                }
            }

            if (subscriptionID == SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                return AgentCommandDispatcher.Result.failure("请在安卓 SIM 卡设置中选择默认短信 SIM");
            }
            // Arm before every sender path: Shizuku/root may run SmsManager in
            // another process, but the MIUI confirmation window is handled here.
            SmsSendConfirmationGate.arm(SENT_TIMEOUT_MS + 15_000L);
            RootSender root = rootSender;
            if (root != null) {
                String result = root.send(destination, command.message, subscriptionID);
                if (result != null && result.startsWith("ok:")) {
                    SmsSendConfirmationGate.disarm();
                    int segments = segments(result);
                    BridgeLog.info("sms_send_root accepted segments=" + segments);
                    return AgentCommandDispatcher.Result.success(segments);
                }
                if (!SMSPrivilegedResult.mayFallback(result)) {
                    SmsSendConfirmationGate.disarm();
                    BridgeLog.info("sms_send_root_unconfirmed no_fallback=true");
                    return AgentCommandDispatcher.Result.failure(SMSPrivilegedResult.failureMessage(result));
                }
                BridgeLog.info("sms_send_root_fallback result="
                        + (result == null || result.isEmpty() ? "unknown" : result));
            }
            PrivilegedSender privileged = privilegedSender;
            if (privileged != null) {
                String result = privileged.send(destination, command.message, subscriptionID);
                if (result != null && result.startsWith("ok:")) {
                    SmsSendConfirmationGate.disarm();
                    int segments = segments(result);
                    BridgeLog.info("sms_send_shizuku accepted segments=" + segments);
                    return AgentCommandDispatcher.Result.success(segments);
                }
                if (!SMSPrivilegedResult.mayFallback(result)) {
                    SmsSendConfirmationGate.disarm();
                    BridgeLog.info("sms_send_shizuku_unconfirmed no_fallback=true");
                    return AgentCommandDispatcher.Result.failure(SMSPrivilegedResult.failureMessage(result));
                }
                BridgeLog.info("sms_send_shizuku_fallback result="
                        + (result == null || result.isEmpty() ? "unknown" : result));
            }
            BridgeLog.info("sms_send_path=system subscription=" + subscriptionID);
            SmsManager manager = managerForSubscription(context, subscriptionID);
            if (manager == null) {
                SmsSendConfirmationGate.disarm();
                return AgentCommandDispatcher.Result.failure("系统短信服务不可用");
            }
            ArrayList<String> parts = manager.divideMessage(command.message);
            if (parts == null || parts.isEmpty()) {
                SmsSendConfirmationGate.disarm();
                return AgentCommandDispatcher.Result.failure("短信分段失败");
            }

            SMSConfirmation confirmation = new SMSConfirmation(parts.size());
            String attemptID = UUID.randomUUID().toString();
            String trace = attemptID.substring(0, 8);
            String action = context.getPackageName() + ".SMS_SENT." + attemptID;
            String defaultSmsPackage = Telephony.Sms.getDefaultSmsPackage(context);
            BridgeLog.info("sms_send_started trace=" + trace + " segments=" + parts.size()
                    + " subscription=" + subscriptionID
                    + " default_subscription=" + defaultSubscription
                    + " default_sms_package=" + (defaultSmsPackage == null ? "none" : defaultSmsPackage));
            BroadcastReceiver receiver = new BroadcastReceiver() {
                @Override public void onReceive(Context ignored, Intent intent) {
                    if (action.equals(intent.getAction())) {
                        int segment = intent.getIntExtra(SEGMENT_EXTRA, -1);
                        int resultCode = getResultCode();
                        int modemError = intent.getIntExtra("errorCode", -1);
                        confirmation.record(segment, resultCode);
                        BridgeLog.info("sms_send_callback trace=" + trace + " segment=" + segment
                                + " result=" + resultCode
                                + " result_text=" + SMSResultCode.describe(resultCode)
                                + " modem_error=" + modemError);
                    }
                }
            };
            IntentFilter filter = new IntentFilter(action);
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
            } else {
                context.registerReceiver(receiver, filter);
            }
            ArrayList<PendingIntent> sentIntents = new ArrayList<>(parts.size());
            try {
                for (int index = 0; index < parts.size(); index++) {
                    Intent sent = new Intent(action).setPackage(context.getPackageName())
                            .putExtra(SEGMENT_EXTRA, index);
                    sentIntents.add(PendingIntent.getBroadcast(context, index, sent,
                            PendingIntent.FLAG_ONE_SHOT | PendingIntent.FLAG_IMMUTABLE));
                }
                if (parts.size() == 1) {
                    manager.sendTextMessage(destination, null, parts.get(0), sentIntents.get(0), null);
                } else {
                    manager.sendMultipartTextMessage(destination, null, parts, sentIntents, null);
                }
                SMSConfirmation.Outcome outcome = confirmation.await(SENT_TIMEOUT_MS);
                if (!outcome.complete()) {
                    SmsSendConfirmationGate.disarm();
                    BridgeLog.info("sms_send_timeout trace=" + trace + " confirmed="
                            + outcome.confirmedSegments() + " total=" + parts.size());
                    return AgentCommandDispatcher.Result.failure("等待系统短信发送回执超时；请先确认短信是否发出，勿立即重试");
                }
                if (!outcome.success()) {
                    SmsSendConfirmationGate.disarm();
                    int errorCode = outcome.errorCode();
                    BridgeLog.info("sms_send_rejected trace=" + trace + " result=" + errorCode
                            + " result_text=" + SMSResultCode.describe(errorCode));
                    String hint = SMSResultCode.isModemError(errorCode)
                            ? "；请检查默认短信 SIM 和信号，并允许小米的短信发送确认弹窗" : "";
                    return AgentCommandDispatcher.Result.failure(
                            "系统短信发送失败（" + SMSResultCode.describe(errorCode) + hint + "）");
                }
                SmsSendConfirmationGate.disarm();
                BridgeLog.info("sms_send_confirmed trace=" + trace + " segments=" + parts.size());
                return AgentCommandDispatcher.Result.success(parts.size());
            } finally {
                SmsSendConfirmationGate.disarm();
                for (PendingIntent intent : sentIntents) intent.cancel();
                context.unregisterReceiver(receiver);
            }
        } catch (InterruptedException error) {
            SmsSendConfirmationGate.disarm();
            Thread.currentThread().interrupt();
            return AgentCommandDispatcher.Result.failure("短信发送等待被中断；请先确认短信是否发出，勿立即重试");
        } catch (RuntimeException error) {
            SmsSendConfirmationGate.disarm();
            BridgeLog.error("sms_send_failed", error);
            return AgentCommandDispatcher.Result.failure("Android 短信发送失败：" + error.getClass().getSimpleName());
        }
    }

    /** Public bridge for the VoBLE gateway; returns "ok:<segments>" or "error:<message>". */
    public static String sendFromVoBLE(
            Context context, String requestId, String number, String message, String simAccount) {
        AgentCommandDispatcher.Result result = execute(context,
                new AgentCommand(requestId, "send_sms", "", number, message, simAccount));
        return result.success() ? "ok:" + result.segments() : "error:" + result.error();
    }

    private static int segments(String result) {
        try { return Math.max(1, Integer.parseInt(result.substring(3))); }
        catch (NumberFormatException ignored) { return 1; }
    }

    private static int defaultSmsSubscription(Context context) {
        try {
            int subscription = SubscriptionManager.getDefaultSmsSubscriptionId();
            if (subscription != SubscriptionManager.INVALID_SUBSCRIPTION_ID) return subscription;
        } catch (RuntimeException ignored) {
            // Fall through to SmsManager for vendors that do not expose the
            // SubscriptionManager default to non-default SMS apps.
        }
        return SmsManager.getDefaultSmsSubscriptionId();
    }

    static SmsManager managerForSubscription(Context context, int subscriptionID) {
        if (Build.VERSION.SDK_INT >= 31) {
            SmsManager service = context.getSystemService(SmsManager.class);
            if (service != null) return service.createForSubscriptionId(subscriptionID);
        }
        return SmsManager.getSmsManagerForSubscriptionId(subscriptionID);
    }
}
