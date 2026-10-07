package com.airsim.phonecontrol;

import java.net.URI;

public final class AVFNetworkPolicy {
    private AVFNetworkPolicy() {}

    public static String agentEndpoint(String androidHost) {
		return endpoint(androidHost, 8575);
	}

	public static String installerEndpoint(String androidHost) {
		return endpoint(androidHost, 8576);
	}

	private static String endpoint(String androidHost, int port) {
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
		return "http://" + octets[0] + "." + octets[1] + "." + octets[2] + ".25:" + port;
    }

    public static boolean isAgentEndpoint(String value) {
		return isEndpoint(value, 8575);
	}

	public static boolean isInstallerEndpoint(String value) {
		return isEndpoint(value, 8576);
	}

	public static String installerEndpointForAgent(String value) {
		if (!isAgentEndpoint(value)) return "";
		URI uri = URI.create(value.trim());
		return "http://" + uri.getHost() + ":8576";
	}

	private static boolean isEndpoint(String value, int port) {
        if (value == null) return false;
        try {
            URI uri = URI.create(value.trim());
            String path = uri.getPath();
            return "http".equals(uri.getScheme()) && uri.getUserInfo() == null &&
                    uri.getQuery() == null && uri.getFragment() == null &&
					(path == null || path.isEmpty() || "/".equals(path)) && uri.getPort() == port &&
					!endpoint(uri.getHost(), port).isEmpty() &&
					endpoint(uri.getHost(), port).equals("http://" + uri.getHost() + ":" + port);
        } catch (IllegalArgumentException error) {
            return false;
        }
    }
}
