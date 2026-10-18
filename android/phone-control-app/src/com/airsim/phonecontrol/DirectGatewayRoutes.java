package com.airsim.phonecontrol;

import java.util.HashMap;
import java.util.Map;

/** Only live, explicitly bound Android gateways; never AVF or shell endpoints. */
public final class DirectGatewayRoutes {
    public record Ports(int controlPort, int pcmPort) {}
    private final Map<String, Ports> routes = new HashMap<>();

    public synchronized void put(String host, int controlPort, int pcmPort) {
        if (controlPort < 1024 || controlPort > 65535 || pcmPort < 1024 || pcmPort > 65535)
            throw new IllegalArgumentException("invalid direct gateway ports");
        routes.put(host, new Ports(controlPort, pcmPort));
    }
    public synchronized Ports forHost(String host) { return routes.get(host); }
    public synchronized void remove(String host) { routes.remove(host); }

    public static String proof(byte[] secret, String session, String clientKey, String agentID,
                               int controlPort, int pcmPort) {
        return VoWLANAuth.sign(secret, "AIRSIM-DIRECT1\n" + session + "\n" + clientKey + "\n" + agentID
                + "\n" + controlPort + "\n" + pcmPort);
    }
}
