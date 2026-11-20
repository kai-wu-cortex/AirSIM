package com.airsim.phonecontrol;

import java.io.File;

public final class PhoneAudioBridgeProcessPolicy {
    private static final String MAIN_CLASS = "com.airsim.bridge.PhoneAudioBridge";
    public static final int DEFAULT_PORT = 7580;
    private static final int EARLY_TEST_PORT = 7581;

    public static int standalonePort(String packageName) {
        return "com.airsim.phonecontrol.earlytest".equals(packageName) ? EARLY_TEST_PORT : DEFAULT_PORT;
    }

    private PhoneAudioBridgeProcessPolicy() {}

    static boolean isStaleBridge(int candidatePid, int ownerPid, String commandLine,
            String processEnvironment, String packageName) {
        if (candidatePid <= 0 || candidatePid == ownerPid || commandLine == null) return false;
        if (processEnvironment == null || packageName == null || packageName.isEmpty()) return false;
        String[] arguments = commandLine.split("\0", -1);
        boolean hasMainClass = false;
        boolean hasListenPort = false;
        boolean hasExpectedRoute = false;
        for (int index = 0; index < arguments.length; index++) {
            String argument = arguments[index];
            if (MAIN_CLASS.equals(argument)) hasMainClass = true;
            if ("--listen-port".equals(argument)
                    && index + 1 < arguments.length
                    && (Integer.toString(DEFAULT_PORT).equals(arguments[index + 1])
                        || Integer.toString(standalonePort(packageName)).equals(arguments[index + 1]))) {
                hasListenPort = true;
            }
            if ("--listen-host".equals(argument)
                    && index + 1 < arguments.length
                    && "127.0.0.1".equals(arguments[index + 1])) {
                hasExpectedRoute = true;
            }
            if ("--listen-interface".equals(argument)
                    && index + 1 < arguments.length
                    && "avf_tap_fixed".equals(arguments[index + 1])) {
                hasExpectedRoute = true;
            }
        }
        if (!hasMainClass || !hasListenPort || !hasExpectedRoute) return false;
        for (String entry : processEnvironment.split("\0", -1)) {
            if (!entry.startsWith("CLASSPATH=")) continue;
            File parent = new File(entry.substring("CLASSPATH=".length())).getParentFile();
            if (parent != null && parent.getName().startsWith(packageName + "-")) return true;
        }
        return false;
    }
}
