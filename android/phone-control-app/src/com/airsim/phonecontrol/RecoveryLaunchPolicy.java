package com.airsim.phonecontrol;

final class RecoveryLaunchPolicy {
    private static final int MODE_ALLOWED = 1;
    private static final int MODE_ALLOW_ALWAYS = 3;

    private RecoveryLaunchPolicy() {}

    static int backgroundActivityStartMode(int sdkInt) {
        return sdkInt >= 36 ? MODE_ALLOW_ALWAYS : MODE_ALLOWED;
    }
}
