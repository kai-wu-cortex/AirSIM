package com.airsim.phonecontrol;

import android.content.Context;

public final class RuntimeMode {
    private RuntimeMode() {}
    public static boolean isStandalone(Context context) { return false; }
}
