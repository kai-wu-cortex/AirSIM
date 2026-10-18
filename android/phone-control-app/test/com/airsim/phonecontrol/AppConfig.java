package com.airsim.phonecontrol;

import android.content.Context;

final class AppConfig {
    static String audioMode = "remote_silent";
    static String mode(Context ignored) { return audioMode; }
    static boolean debugEnabled(Context ignored) { return false; }
    static void setDebugEnabled(Context ignored, boolean enabled) {}
    static String endpoint(Context ignored) { return ""; }
    static String token(Context ignored) { return ""; }
	static String installerEndpoint(Context ignored) { return ""; }
}
