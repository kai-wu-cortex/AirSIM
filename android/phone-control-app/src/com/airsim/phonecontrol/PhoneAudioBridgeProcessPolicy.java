package com.airsim.phonecontrol;

final class PhoneAudioBridgeProcessPolicy {
    private static final String MAIN_CLASS = "com.airsim.bridge.PhoneAudioBridge";
    private static final String LISTEN_PORT = "7580";

    private PhoneAudioBridgeProcessPolicy() {}

    static boolean isStaleBridge(int candidatePid, int ownerPid, String commandLine) {
        if (candidatePid <= 0 || candidatePid == ownerPid || commandLine == null) return false;
        String[] arguments = commandLine.split("\0", -1);
        boolean hasMainClass = false;
        boolean hasListenPort = false;
        boolean hasExpectedRoute = false;
        for (int index = 0; index < arguments.length; index++) {
            String argument = arguments[index];
            if (MAIN_CLASS.equals(argument)) hasMainClass = true;
            if ("--listen-port".equals(argument)
                    && index + 1 < arguments.length
                    && LISTEN_PORT.equals(arguments[index + 1])) {
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
        return hasMainClass && hasListenPort && hasExpectedRoute;
    }
}
