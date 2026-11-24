package com.airsim.phonecontrol;

/** Display-only IMS caller projection. Not a dial/SMS or identity normalizer. */
public final class CallerNumber {
    private CallerNumber() {}
    public static String display(String raw) {
        if (raw == null) return "";
        String value = raw.trim(), rest = value;
        if (value.length() > 512) return raw;
        boolean tel = false;
        int colon = value.indexOf(':');
        if (colon >= 0) {
            String scheme = value.substring(0, colon).toLowerCase(java.util.Locale.ROOT);
            if (!scheme.equals("sip") && !scheme.equals("sips") && !scheme.equals("tel")) return raw;
            tel = scheme.equals("tel");
            rest = value.substring(colon + 1);
        } else if (!value.contains("@")) return raw;
        if (rest.chars().anyMatch(c -> Character.isWhitespace(c) || c < 32 || c == 127)) return raw;
        String[] parts = rest.split("@", -1);
        if (parts.length != (tel ? 1 : 2)) return raw;
        java.util.Set<String> seen = new java.util.HashSet<>();
        String[] user = parts[0].split(";", -1);
        if (!parameters(user, tel, seen)) return raw;
        if (!tel) {
            String[] host = parts[1].split(";", -1);
            if (!parameters(host, false, seen) || !authority(host[0])) return raw;
        }
        try {
            // URLDecoder treats literal '+' as a space: protect it before one decode.
            String decoded = java.net.URLDecoder.decode(user[0].replace("+", "%2B"), "UTF-8");
            if (!decoded.matches("\\+?[0-9().-]+")) return raw;
            String number = decoded.replaceAll("[().-]", "");
            int digits = number.startsWith("+") ? number.length() - 1 : number.length();
            return digits >= 1 && digits <= 20 ? number : raw;
        } catch (IllegalArgumentException | java.io.UnsupportedEncodingException e) { return raw; }
    }
    private static boolean parameters(String[] parts, boolean tel, java.util.Set<String> seen) {
        for (int i=1; i<parts.length; i++) {
            String[] pair = parts[i].toLowerCase(java.util.Locale.ROOT).split("=", -1);
            if (pair.length != 2 || !seen.add(pair[0])) return false;
            if (pair[0].equals("user") && pair[1].equals("phone")) continue;
            if (!tel && pair[0].equals("transport") && java.util.Set.of("udp", "tcp", "tls").contains(pair[1])) continue;
            return false;
        }
        return true;
    }
    private static boolean authority(String value) {
        if (value.isEmpty() || value.length() > 260) return false;
        String host, port = null;
        if (value.startsWith("[")) {
            int end = value.indexOf(']');
            if (end < 0) return false;
            String address = value.substring(1, end);
            if (!address.contains(":") || !address.matches("[0-9a-fA-F:.]+")) return false;
            try { if (new java.net.URI("sip://" + value).getHost() == null) return false; }
            catch (java.net.URISyntaxException e) { return false; }
            host = "ipv6";
            String suffix = value.substring(end+1);
            if (!suffix.isEmpty()) {
                if (!suffix.startsWith(":")) return false;
                port = suffix.substring(1);
            }
        } else {
            String[] parts = value.split(":", -1);
            if (parts.length > 2) return false;
            host = parts[0];
            if (parts.length == 2) port = parts[1];
            for (String label : host.split("\\.", -1)) {
                if (label.length() > 63 || !label.matches("[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?")) return false;
            }
        }
        if (port != null) {
            if (!port.matches("[0-9]+")) return false;
            try { int n = Integer.parseInt(port); if (n < 1 || n > 65535) return false; }
            catch (NumberFormatException e) { return false; }
        }
        return !host.isEmpty();
    }
}
