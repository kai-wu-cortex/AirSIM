package com.airsim.phonecontrol;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;

public final class AVFEnvironmentDetector {
    public static final String TERMINAL_PACKAGE = "com.android.virtualization.terminal";
    private static final String AVF_FEATURE = "android.software.virtualization_framework";

    public record Snapshot(
            AVFStartupPolicy.State state,
            boolean hasAVFSystemFeature,
            boolean terminalInstalled,
            boolean terminalEnabled,
            boolean avfNetworkActive,
            boolean restrictedChinaOEM) {}

    private AVFEnvironmentDetector() {}

    public static Snapshot inspect(Context context) {
        PackageManager packages = context.getPackageManager();
        boolean hasAVF = packages.hasSystemFeature(AVF_FEATURE);
        boolean terminalInstalled = false;
        boolean terminalEnabled = false;
        try {
            ApplicationInfo application = packages.getApplicationInfo(
                    TERMINAL_PACKAGE, PackageManager.MATCH_DISABLED_COMPONENTS);
            terminalInstalled = true;
            int enabledSetting = packages.getApplicationEnabledSetting(TERMINAL_PACKAGE);
            terminalEnabled = application.enabled
                    && enabledSetting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    && enabledSetting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                    && enabledSetting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED;
        } catch (PackageManager.NameNotFoundException ignored) {
            // OEM firmware did not ship the AOSP Terminal package.
        }
        boolean networkActive = !AppConfig.discoverAVFEndpoint().isEmpty();
        return new Snapshot(
                AVFStartupPolicy.assess(hasAVF, terminalInstalled, terminalEnabled, networkActive),
                hasAVF,
                terminalInstalled,
                terminalEnabled,
                networkActive,
                AVFStartupPolicy.isRestrictedChinaOEM(Build.MANUFACTURER));
    }
}
