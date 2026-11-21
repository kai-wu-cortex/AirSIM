package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Build;
import android.telephony.SmsManager;

public final class SMSCompatibilityTests {
    public static void main(String[] args) throws Exception {
        for (int sdk : new int[]{29, 30, 31, 32, 33, 35}) {
            Build.VERSION.SDK_INT = sdk;
            Context context = new Context();
            context.setSystemService(SmsManager.class, SmsManager.getDefault());
            context.getPackageManager().features.add("android.hardware.telephony");
            boolean legacy = sdk < 33;
            if (SMSCommandExecutor.supportsSystemSMS(context) != legacy) {
                throw new AssertionError("wrong legacy SMS capability on API " + sdk);
            }
            context.getPackageManager().features.add("android.hardware.telephony.messaging");
            if (!SMSCommandExecutor.supportsSystemSMS(context)) throw new AssertionError("SMS capability missing");
            if (SMSCommandExecutor.supportsSystemSMS(new Context())) throw new AssertionError("Wi-Fi-only accepted");
            SmsManager manager = SMSCommandExecutor.managerForSubscription(context, 7);
            if (manager.getSubscriptionId() != 7) throw new AssertionError("wrong SIM on API " + sdk);
            manager = SMSCommandExecutor.managerForSubscription(new Context(), 9);
            if (manager.getSubscriptionId() != 9) throw new AssertionError("null-service fallback lost SIM");
        }
        for (String result : new String[]{"unavailable", "error:no_context", "error:no_service", "error:prepare:NullPointerException"}) {
            if (!SMSPrivilegedResult.mayFallback(result)) throw new AssertionError("safe prepare failure blocked");
        }
        for (String result : new String[]{"error:send_unknown:NullPointerException", "error:timeout", "error:no_result",
                "error:NullPointerException", "error:remote", "error:root", "error:permission", "", null}) {
            if (SMSPrivilegedResult.mayFallback(result)) throw new AssertionError("ambiguous send would be repeated");
        }
        // A post-dispatch exception is not success, but independent system callbacks
        // can confirm the one attempted send. Partial/duplicate callbacks cannot.
        SMSConfirmation receipt = new SMSConfirmation(2);
        receipt.record(0, -1);
        receipt.record(0, -1);
        receipt.record(9, -1);
        String partial = SMSPrivilegedResult.confirmed(receipt.await(1), 2);
        if (!partial.equals("error:send_unknown:callback_timeout") || SMSPrivilegedResult.mayFallback(partial))
            throw new AssertionError("partial/duplicate receipt must not succeed or resend");
        receipt.record(1, -1);
        if (!SMSPrivilegedResult.confirmed(receipt.await(1), 2).equals("ok:2"))
            throw new AssertionError("all sent callbacks must reconcile the original attempt");
        SMSConfirmation rejected = new SMSConfirmation(2);
        rejected.record(0, 4);
        String failure = SMSPrivilegedResult.confirmed(rejected.await(1), 2);
        if (!failure.equals("error:sent:4") || SMSPrivilegedResult.mayFallback(failure))
            throw new AssertionError("modem rejection must not be treated as success or repeated");
        if (!SMSPrivilegedResult.failureMessage(failure).startsWith("系统短信发送失败"))
            throw new AssertionError("known failure must differ from unknown status");
        Context sendContext = new Context();
        sendContext.grant("android.permission.SEND_SMS");
        sendContext.getPackageManager().features.add("android.hardware.telephony.messaging");
        int[] privilegedCalls = {0};
        SMSCommandExecutor.setRootSender((n,b,s) -> RootSMSPreflight.check(() -> {
            throw new java.io.IOException("no su on this phone");
        }, 1));
        SMSCommandExecutor.setPrivilegedSender((n,b,s) -> { privilegedCalls[0]++; return "ok:1"; });
        var command = new AgentCommand("fixture", "send_sms", "", "10086", "synthetic", "");
        if (!SMSCommandExecutor.execute(sendContext, command).success())
            throw new AssertionError("VoWLAN/cloud shared executor blocked before dispatch");
        if (!SMSCommandExecutor.sendFromVoBLE(sendContext,"fixture2","10086","synthetic","").equals("ok:1"))
            throw new AssertionError("VoBLE adapter blocked before dispatch");
        if (privilegedCalls[0] != 2) throw new AssertionError("fallback was not exactly once per intent");
        SMSCommandExecutor.setRootSender((n,b,s) -> "error:send_unknown:IOException");
        if (SMSCommandExecutor.execute(sendContext, command).success()) throw new AssertionError("unknown falsely accepted");
        SMSCommandExecutor.sendFromVoBLE(sendContext,"fixture3","10086","synthetic","");
        if (privilegedCalls[0] != 2) throw new AssertionError("ambiguous send retried on another sender");
        SMSCommandExecutor.setRootSender(null);
        SMSCommandExecutor.setPrivilegedSender(null);
        System.out.println("SMSCompatibilityTests passed (API 29–35, shared executor and VoBLE fallback, no SMS sent)");
    }
}
