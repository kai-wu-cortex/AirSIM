package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Build;
import android.telephony.SmsManager;

public final class SMSCompatibilityTests {
    public static void main(String[] args) {
        for (int sdk : new int[]{29, 30, 31, 32, 33, 35}) {
            Build.VERSION.SDK_INT = sdk;
            Context context = new Context();
            context.setSystemService(SmsManager.class, SmsManager.getDefault());
            SmsManager manager = SMSCommandExecutor.managerForSubscription(context, 7);
            if (manager.getSubscriptionId() != 7) throw new AssertionError("wrong SIM on API " + sdk);
            manager = SMSCommandExecutor.managerForSubscription(new Context(), 9);
            if (manager.getSubscriptionId() != 9) throw new AssertionError("null-service fallback lost SIM");
        }
        System.out.println("SMSCompatibilityTests passed (API 29–35, no SMS sent)");
    }
}
