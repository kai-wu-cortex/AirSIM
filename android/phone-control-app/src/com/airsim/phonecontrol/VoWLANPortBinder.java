package com.airsim.phonecontrol;

import java.io.IOException;
import java.net.BindException;
import java.net.Inet4Address;
import java.net.InetSocketAddress;
import java.net.ServerSocket;

/** Keeps both VoWLAN listeners on the discovered private interface. */
final class VoWLANPortBinder {
    private VoWLANPortBinder() {}

    static ServerSocket bind(Inet4Address address, int preferredPort, int backlog) throws IOException {
        try {
            return bindOnce(address, preferredPort, backlog);
        } catch (BindException occupied) {
            // Bonjour advertises the actual port. A stale or competing listener on
            // the preferred port must not prevent this app's private gateway starting.
            return bindOnce(address, 0, backlog);
        }
    }

    private static ServerSocket bindOnce(Inet4Address address, int port, int backlog) throws IOException {
        ServerSocket socket = new ServerSocket();
        try {
            socket.setReuseAddress(true);
            socket.bind(new InetSocketAddress(address, port), backlog);
            return socket;
        } catch (IOException | RuntimeException error) {
            socket.close();
            throw error;
        }
    }
}
