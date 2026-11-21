package com.airsim.phonecontrol;
import android.content.Context;
import android.telephony.SmsManager;
final class SMSCommandExecutor {
    static SmsManager managerForSubscription(Context context, int subscription) { return new SmsManager(); }
}
