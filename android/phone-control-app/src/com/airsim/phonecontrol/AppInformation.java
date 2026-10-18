package com.airsim.phonecontrol;

import android.content.Context;
import android.content.pm.PackageInfo;

/** Installed package metadata, shared by About and private crash diagnostics. */
public final class AppInformation {
    public static final String REPOSITORY_URL = "https://github.com/kai-wu-cortex/AirSIM";
    public static final String RELEASES_URL = REPOSITORY_URL + "/releases";

    private AppInformation() {}

    static int privilegedServiceVersion(Context context) {
        try {
            long build = context.getPackageManager().getPackageInfo(context.getPackageName(), 0).getLongVersionCode();
            if (build > 9 && build <= Integer.MAX_VALUE) return (int) build;
        } catch (Exception ignored) { /* Never reuse the old fixed daemon version 9. */ }
        return 10;
    }

    public static String version(Context context) {
        try {
            PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            String name = info.versionName == null || info.versionName.isEmpty()
                    ? "未知版本" : info.versionName;
            // minSdk 29; getLongVersionCode is available since API 28.
            return name + " (" + info.getLongVersionCode() + ")";
        } catch (Exception ignored) {
            return "未知版本";
        }
    }
}
