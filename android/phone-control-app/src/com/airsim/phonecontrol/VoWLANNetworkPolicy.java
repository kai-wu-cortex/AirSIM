package com.airsim.phonecontrol;

public final class VoWLANNetworkPolicy {
    private VoWLANNetworkPolicy() {}

    public static boolean isOverlayInterface(String name, String host) {
        return name != null && (name.startsWith("tun") || name.startsWith("tailscale"))
                && isOverlayIPv4(host);
    }

    public static boolean permitsPeer(String remote, String local) {
        int[] r = ipv4(remote);
        int[] l = ipv4(local);
        if (r == null || l == null) return false;
        // Userspace Tailscale forwards incoming TCP to loopback. App-level HMAC
        // authentication remains mandatory; loopback never makes a peer trusted.
        if (l[0] == 127) return r[0] == 127;
        if (isOverlayIPv4(local)) return isOverlayIPv4(remote);
        return (isPrivateIPv4(local) || isLinkLocal(local))
                && (isPrivateIPv4(remote) || isLinkLocal(remote));
    }

    public static boolean permitsPairingPeer(String remote, String local, String interfaceName) {
        int[] fields = ipv4(local);
        if (fields == null || !permitsPeer(remote, local)) return false;
        return fields[0] == 127 || isVoWLANInterface(interfaceName, local) || isOverlayInterface(interfaceName, local);
    }

    public static boolean isOverlayIPv4(String host) {
        int[] fields = ipv4(host);
        return fields != null && fields[0] == 100 && fields[1] >= 64 && fields[1] <= 127;
    }

    private static boolean isLinkLocal(String host) {
        int[] fields = ipv4(host);
        return fields != null && fields[0] == 169 && fields[1] == 254;
    }

    private static int[] ipv4(String host) {
        if (host == null) return null;
        String[] fields = host.split("\\.", -1);
        if (fields.length != 4) return null;
        int[] values = new int[4];
        for (int index = 0; index < 4; index++) {
            if (fields[index].isEmpty() || fields[index].length() > 3) return null;
            if (fields[index].length() > 1 && fields[index].charAt(0) == '0') return null;
            for (int c = 0; c < fields[index].length(); c++) {
                if (fields[index].charAt(c) < '0' || fields[index].charAt(c) > '9') return null;
            }
            values[index] = Integer.parseInt(fields[index]);
            if (values[index] > 255) return null;
        }
        return values;
    }

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
        int[] fields = ipv4(host);
        return fields != null && (fields[0] == 10 || (fields[0] == 172 && fields[1] >= 16 && fields[1] <= 31)
                || (fields[0] == 192 && fields[1] == 168));
    }

    public static boolean shouldAdvertise(
            boolean hotspotReady, boolean paired, boolean agentReady, boolean pcmReady,
            boolean dialerRoleHeld) {
        return hotspotReady && paired && agentReady && pcmReady && dialerRoleHeld;
    }
}
