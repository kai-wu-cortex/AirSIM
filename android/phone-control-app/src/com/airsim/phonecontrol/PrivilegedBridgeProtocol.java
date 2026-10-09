package com.airsim.phonecontrol;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class PrivilegedBridgeProtocol {
    static final String DESCRIPTOR = "com.airsim.phonecontrol.IPrivilegedBridge";
    static final int TRANSACTION_START_BRIDGE = 1;
    static final int TRANSACTION_STATUS = 2;
    static final int TRANSACTION_SET_LOCAL_OUTPUT_MUTED = 3;
    static final int TRANSACTION_ENSURE_DIALER_ROLE = 4;
    static final int STREAM_VOICE_CALL = 0;
    private static final String DIALER_ROLE = "android.app.role.DIALER";
    private static final Pattern PACKAGE_NAME = Pattern.compile(
            "[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+");

    private static final Pattern STREAM_VOLUME = Pattern.compile("->\\s*(-?\\d+)\\s*$");

    private PrivilegedBridgeProtocol() {}

    static String[] audioMuteCommand(boolean muted) {
        return new String[]{"cmd", "audio", muted ? "adj-mute" : "adj-unmute", "0"};
    }

    static boolean isStreamMuted(String output) {
        Matcher matcher = STREAM_VOLUME.matcher(output == null ? "" : output.trim());
        if (!matcher.find()) throw new IllegalArgumentException("voice-call volume result missing");
        return Integer.parseInt(matcher.group(1)) == 0;
    }

    static boolean supportsUid(int uid) {
        return uid == 0 || uid == 2000;
    }

    static String[] dialerRoleGrantCommand(String packageName) {
        requirePackageName(packageName);
        return new String[]{"cmd", "role", "add-role-holder", DIALER_ROLE, packageName};
    }

    static String[] dialerRoleQueryCommand() {
        return new String[]{"cmd", "role", "get-role-holders", DIALER_ROLE};
    }

    static boolean isDialerRoleHolder(String output, String packageName) {
        requirePackageName(packageName);
        if (output == null) return false;
        for (String line : output.split("\\R")) {
            if (packageName.equals(line.trim())) return true;
        }
        return false;
    }

    private static void requirePackageName(String packageName) {
        if (packageName == null || !PACKAGE_NAME.matcher(packageName).matches()) {
            throw new IllegalArgumentException("package name is invalid");
        }
    }
}
