package com.airsim.phonecontrol;

public final class VoWLANNetworkPolicy {
    private VoWLANNetworkPolicy() {}

    public static boolean isHotspotInterface(String name, String host) {
        if (name == null || host == null || !(name.startsWith("swlan") || name.startsWith("ap"))) return false;
        String[] fields = host.split("\\.");
        if (fields.length != 4) return false;
        int first;
        int second;
        try {
            first = Integer.parseInt(fields[0]);
            second = Integer.parseInt(fields[1]);
        } catch (NumberFormatException error) {
            return false;
        }
        return first == 10 || (first == 172 && second >= 16 && second <= 31)
                || (first == 192 && second == 168);
    }

    public static boolean isVoWLANInterface(String name, String host) {
        if (!isPrivateIPv4(host) || name == null) return false;
        return isHotspotInterface(name, host) || name.startsWith("wlan");
    }

    private static boolean isPrivateIPv4(String host) {
        if (host == null) return false;
        String[] fields = host.split("\\.");
        if (fields.length != 4) return false;
        try {
            int first = Integer.parseInt(fields[0]);
            int second = Integer.parseInt(fields[1]);
            for (String field : fields) {
                int value = Integer.parseInt(field);
                if (value < 0 || value > 255) return false;
            }
            return first == 10 || (first == 172 && second >= 16 && second <= 31)
                    || (first == 192 && second == 168);
        } catch (NumberFormatException error) {
            return false;
        }
    }

    public static boolean shouldAdvertise(
            boolean hotspotReady, boolean paired, boolean agentReady, boolean pcmReady) {
        return hotspotReady && paired && agentReady && pcmReady;
    }
}
