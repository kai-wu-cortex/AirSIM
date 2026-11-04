package com.airsim.phonecontrol;

/** Strict identities for helper lifetime and one-time migration of pre-owner helpers. */
final class RootHelperIdentity {
    static String startTime(String procStat) {
        if (procStat == null) return "";
        int end = procStat.lastIndexOf(')');
        if (end < 0 || end + 2 >= procStat.length()) return "";
        String[] fields = procStat.substring(end + 2).trim().split("\\s+");
        // proc(5) field 22; the tail starts at field 3 (state).
        return fields.length > 19 && fields[19].matches("[0-9]+") ? fields[19] : "";
    }

    static boolean isLegacyHelper(String commandLine, String packageName, String cachePath) {
        if (commandLine == null || packageName == null || packageName.isEmpty() || cachePath == null) return false;
        String[] args = commandLine.split("\0");
        // app_process /system/bin RootBridgeMain package port token-file, no owner fields.
        if (args.length != 6 || !(args[0].equals("app_process") || args[0].endsWith("/app_process"))
                || !args[1].equals("/system/bin")
                || !args[2].equals("com.airsim.phonecontrol.RootBridgeMain") || !args[3].equals(packageName)
                || !args[4].matches("[0-9]{1,5}")) return false;
        return args[5].startsWith(cachePath + "/root-bridge-") && args[5].endsWith(".token")
                && args[5].substring((cachePath + "/root-bridge-").length()).matches("[a-fA-F0-9-]+\\.token");
    }
}
