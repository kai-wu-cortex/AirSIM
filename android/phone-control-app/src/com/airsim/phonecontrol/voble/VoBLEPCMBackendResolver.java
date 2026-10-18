package com.airsim.phonecontrol.voble;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;

/** Resolves only the trusted PCM endpoints exposed by the two Android runtimes. */
public final class VoBLEPCMBackendResolver {
    public enum Runtime { STANDALONE, AVF }

    private VoBLEPCMBackendResolver() {}

    public static InetSocketAddress resolve(Runtime runtime, String avfAddress) {
        if (runtime == null) throw new IllegalArgumentException("runtime is required");
        try {
            if (runtime == Runtime.STANDALONE) {
                return new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 7580);
            }
            String candidate = avfAddress == null ? "" : avfAddress.trim();
            if (!candidate.matches("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}")) {
                throw new IllegalArgumentException("AVF private IPv4 is required");
            }
            InetAddress address = InetAddress.getByName(candidate);
            if (!(address instanceof Inet4Address) || !address.isSiteLocalAddress()
                    || address.isLoopbackAddress()) {
                throw new IllegalArgumentException("AVF address must be private IPv4");
            }
            return new InetSocketAddress(address, 7580);
        } catch (IllegalArgumentException error) {
            throw error;
        } catch (Exception error) {
            throw new IllegalArgumentException("PCM backend address is invalid", error);
        }
    }
}
