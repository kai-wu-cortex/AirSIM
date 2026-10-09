package com.airsim.phonecontrol;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;

/** Selects the AVF-backed or self-contained runtime without forking shared UI code. */
public final class RuntimeMode {
    private static final String STANDALONE_META_DATA = "com.airsim.phonecontrol.STANDALONE_AGENT";

    private RuntimeMode() {}

    public static boolean isStandalone(Context context) {
        try {
            ApplicationInfo application = context.getPackageManager().getApplicationInfo(
                    context.getPackageName(), PackageManager.GET_META_DATA);
            Bundle metadata = application.metaData;
            return metadata != null && metadata.getBoolean(STANDALONE_META_DATA, false);
        } catch (PackageManager.NameNotFoundException error) {
            return false;
        }
    }

    public static String agentLabel(Context context) {
        return isStandalone(context) ? "内置 Agent" : "Linux Agent";
    }
}
