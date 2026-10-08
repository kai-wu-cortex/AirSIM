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
import android.telephony.SmsManager;
import android.telephony.SubscriptionManager;

import java.util.ArrayList;
import java.util.UUID;

/** Executes an Agent SMS command through the selected Android SIM, not Telecom. */
final class SMSCommandExecutor {
    private static final long SENT_TIMEOUT_MS = 45_000L;
    private static final String SEGMENT_EXTRA = "segment";

    private SMSCommandExecutor() {}

    static AgentCommandDispatcher.Result execute(Context context, AgentCommand command) {
        String destination = SMSPayloadPolicy.normalizeDestination(command.number);
        if (destination.isEmpty() || !SMSPayloadPolicy.validBody(command.message)) {
            return AgentCommandDispatcher.Result.failure("号码或短信内容无效");
        }
        if (context.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            return AgentCommandDispatcher.Result.failure("AirSIM 缺少短信发送权限；请在三星应用权限中允许短信");
        }
        if (!context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_TELEPHONY_MESSAGING)) {
            return AgentCommandDispatcher.Result.failure("此设备不支持系统短信发送");
        }

        try {
            int subscriptionID = SmsManager.getDefaultSmsSubscriptionId();
            if (subscriptionID == SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                return AgentCommandDispatcher.Result.failure("请在三星 SIM 卡设置中选择默认短信 SIM");
            }
            SmsManager manager = context.getSystemService(SmsManager.class)
                    .createForSubscriptionId(subscriptionID);
            ArrayList<String> parts = manager.divideMessage(command.message);
            if (parts == null || parts.isEmpty()) {
                return AgentCommandDispatcher.Result.failure("短信分段失败");
            }

            SMSConfirmation confirmation = new SMSConfirmation(parts.size());
            String action = context.getPackageName() + ".SMS_SENT." + UUID.randomUUID();
            BroadcastReceiver receiver = new BroadcastReceiver() {
                @Override public void onReceive(Context ignored, Intent intent) {
                    if (action.equals(intent.getAction())) {
                        confirmation.record(intent.getIntExtra(SEGMENT_EXTRA, -1), getResultCode());
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
                    return AgentCommandDispatcher.Result.failure("等待系统短信发送回执超时；请先确认短信是否发出，勿立即重试");
                }
                if (!outcome.success()) {
                    return AgentCommandDispatcher.Result.failure(
                            "系统短信发送失败（代码 " + outcome.errorCode() + "）");
                }
                return AgentCommandDispatcher.Result.success(parts.size());
            } finally {
                for (PendingIntent intent : sentIntents) intent.cancel();
                context.unregisterReceiver(receiver);
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return AgentCommandDispatcher.Result.failure("短信发送等待被中断；请先确认短信是否发出，勿立即重试");
        } catch (RuntimeException error) {
            BridgeLog.error("sms_send_failed", error);
            return AgentCommandDispatcher.Result.failure("Android 短信发送失败：" + error.getClass().getSimpleName());
        }
    }
}
