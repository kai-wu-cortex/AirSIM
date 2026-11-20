package com.airsim.phonecontrol;

public final class RuntimeMode {
    public static boolean isStandalone(android.content.Context context) { return true; }
    public static boolean vowlanPushOnly(android.content.Context context) { return false; }
    public static String agentLabel(android.content.Context context) { return "Standalone fixture"; }
}
