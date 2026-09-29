package com.airsim.phonecontrol;

import java.net.URI;

public final class AVFNetworkPolicy {
    private AVFNetworkPolicy() {}

    public static String agentEndpoint(String androidHost) {
        if (androidHost == null) return "";
        String[] parts = androidHost.trim().split("\\.");
        if (parts.length != 4) return "";
        int[] octets = new int[4];
        try {
            for (int index = 0; index < parts.length; index++) {
                octets[index] = Integer.parseInt(parts[index]);
                if (octets[index] < 0 || octets[index] > 255) return "";
            }
        } catch (NumberFormatException error) {
            return "";
        }
        boolean avfPrivate = octets[0] == 10 ||
                (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31);
        if (!avfPrivate) return "";
        return "http://" + octets[0] + "." + octets[1] + "." + octets[2] + ".25:7575";
    }

    public static boolean isAgentEndpoint(String value) {
        if (value == null) return false;
        try {
            URI uri = URI.create(value.trim());
            String path = uri.getPath();
            return "http".equals(uri.getScheme()) && uri.getUserInfo() == null &&
                    uri.getQuery() == null && uri.getFragment() == null &&
                    (path == null || path.isEmpty() || "/".equals(path)) && uri.getPort() == 7575 &&
                    !agentEndpoint(uri.getHost()).isEmpty() &&
                    agentEndpoint(uri.getHost()).equals("http://" + uri.getHost() + ":7575");
        } catch (IllegalArgumentException error) {
            return false;
        }
    }
}
