package com.airsim.bridge;

record BridgeArguments(String listenHost, String listenInterface, int listenPort) {
    static BridgeArguments parse(String[] argv) {
        String host = null;
        String listenInterface = null;
        int port = 7580;
        for (int index = 0; index < argv.length; index++) {
            switch (argv[index]) {
                case "--listen-host" -> host = requireValue(argv, ++index, "--listen-host");
                case "--listen-interface" -> listenInterface = requireValue(
                    argv, ++index, "--listen-interface");
                case "--listen-port" -> port = parsePort(
                    requireValue(argv, ++index, "--listen-port"));
                default -> throw new IllegalArgumentException("unknown option: " + argv[index]);
            }
        }
        if ((host == null) == (listenInterface == null)) {
            throw new IllegalArgumentException("exactly one listen host or interface is required");
        }
        if (host != null && !isAllowedHost(host)) {
            throw new IllegalArgumentException("listen host must be loopback or private IPv4");
        }
        if (listenInterface != null && !"avf_tap_fixed".equals(listenInterface)) {
            throw new IllegalArgumentException("listen interface must be AVF-private");
        }
        return new BridgeArguments(host, listenInterface, port);
    }

    private static String requireValue(String[] argv, int index, String option) {
        if (index >= argv.length) {
            throw new IllegalArgumentException("missing value for " + option);
        }
        return argv[index];
    }

    private static int parsePort(String value) {
        final int port;
        try {
            port = Integer.parseInt(value);
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException("invalid listen port", error);
        }
        if (port < 1024 || port > 65535) {
            throw new IllegalArgumentException("listen port out of range");
        }
        return port;
    }

    private static boolean isAllowedHost(String host) {
        int[] octets = parseIPv4(host);
        if (octets == null) {
            return false;
        }
        if (octets[0] == 127) {
            return octets[1] == 0 && octets[2] == 0 && octets[3] == 1;
        }
        return octets[0] == 10
            || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
            || (octets[0] == 192 && octets[1] == 168);
    }

    private static int[] parseIPv4(String host) {
        String[] pieces = host.split("\\.", -1);
        if (pieces.length != 4) {
            return null;
        }
        int[] octets = new int[4];
        for (int index = 0; index < pieces.length; index++) {
            if (pieces[index].isEmpty() || pieces[index].length() > 3) {
                return null;
            }
            try {
                octets[index] = Integer.parseInt(pieces[index]);
            } catch (NumberFormatException error) {
                return null;
            }
            if (octets[index] < 0 || octets[index] > 255) {
                return null;
            }
        }
        return octets;
    }
}
