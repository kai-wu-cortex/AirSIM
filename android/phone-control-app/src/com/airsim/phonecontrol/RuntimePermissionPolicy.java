package com.airsim.phonecontrol;

import java.util.ArrayList;
import java.util.List;

final class RuntimePermissionPolicy {
    private static final String CALL_PHONE = "android.permission.CALL_PHONE";
    private static final String SEND_SMS = "android.permission.SEND_SMS";
    private static final String READ_PHONE_STATE = "android.permission.READ_PHONE_STATE";
    private static final String READ_PHONE_NUMBERS = "android.permission.READ_PHONE_NUMBERS";
    private static final String POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS";

    private RuntimePermissionPolicy() {}

    static String[] missingPermissions(
            int sdk, boolean callPhoneGranted, boolean sendSMSGranted,
            boolean notificationsGranted) {
        List<String> missing = new ArrayList<>();
        if (!callPhoneGranted) missing.add(CALL_PHONE);
        if (!sendSMSGranted) missing.add(SEND_SMS);
        if (sdk >= 33 && !notificationsGranted) missing.add(POST_NOTIFICATIONS);
        return missing.toArray(String[]::new);
    }

    static String[] missingPermissions(
            int sdk, boolean callPhoneGranted, boolean sendSMSGranted,
            boolean readPhoneStateGranted, boolean readPhoneNumbersGranted,
            boolean notificationsGranted) {
        List<String> missing = new ArrayList<>();
        if (!callPhoneGranted) missing.add(CALL_PHONE);
        if (!sendSMSGranted) missing.add(SEND_SMS);
        if (!readPhoneStateGranted) missing.add(READ_PHONE_STATE);
        if (!readPhoneNumbersGranted) missing.add(READ_PHONE_NUMBERS);
        if (sdk >= 33 && !notificationsGranted) missing.add(POST_NOTIFICATIONS);
        return missing.toArray(String[]::new);
    }
}
