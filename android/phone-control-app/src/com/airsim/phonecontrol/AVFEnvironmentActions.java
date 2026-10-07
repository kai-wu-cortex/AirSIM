package com.airsim.phonecontrol;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.provider.Settings;

public final class AVFEnvironmentActions {
    private AVFEnvironmentActions() {}

    public static boolean openTerminal(Activity activity) {
        try {
            Intent launch = activity.getPackageManager().getLaunchIntentForPackage(
                    AVFEnvironmentDetector.TERMINAL_PACKAGE);
            if (launch == null) {
                launch = new Intent("android.virtualization.VM_TERMINAL")
                        .setPackage(AVFEnvironmentDetector.TERMINAL_PACKAGE);
            }
            // Reuse an existing Terminal task. Launching another VM runner while the
            // guest is running can trigger "VM is not in stopped state" on Android 16.
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK |
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            if (launch.resolveActivity(activity.getPackageManager()) == null) return false;
            activity.startActivity(launch);
            return true;
        } catch (RuntimeException error) {
            BridgeLog.error("terminal_launch_failed", error);
            return false;
        }
    }

    public static Intent terminalIntent(Context context) {
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(
                AVFEnvironmentDetector.TERMINAL_PACKAGE);
        if (launch == null) {
            launch = new Intent("android.virtualization.VM_TERMINAL")
                    .setPackage(AVFEnvironmentDetector.TERMINAL_PACKAGE);
        }
        return launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_USER_ACTION |
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    }

    public static void openDeveloperOptions(Activity activity) {
        try {
            activity.startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));
        } catch (RuntimeException error) {
            activity.startActivity(new Intent(Settings.ACTION_SETTINGS));
        }
    }
}
