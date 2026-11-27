package com.airsim.phonecontrol;

import android.content.Context;

final class AppConfig {
    static final String MODE_REMOTE_SILENT = "remote_silent";
    static final String MODE_LOCAL_AND_PUSH = "local_and_push";
    static String audioMode = "remote_silent";
    static String volumePolicy = "minimum_nonzero_volume";
    static String callAudioVolumePolicy(Context ignored) { return volumePolicy; }
    static String mode(Context ignored) { return audioMode; }
    static boolean debugEnabled(Context ignored) { return false; }
    static void setDebugEnabled(Context ignored, boolean enabled) {}
    static String endpoint(Context ignored) { return ""; }
    static String token(Context ignored) { return ""; }
	static String installerEndpoint(Context ignored) { return ""; }
}
