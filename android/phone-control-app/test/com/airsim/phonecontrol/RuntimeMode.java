package com.airsim.phonecontrol;

import android.content.Context;

public final class RuntimeMode {
    public static boolean standalone;
    private RuntimeMode() {}
    public static boolean isStandalone(Context context) { return standalone; }
}
