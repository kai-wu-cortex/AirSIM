package com.airsim.phonecontrol;

import java.util.regex.Pattern;

public final class DebugRedactor {
    private static final Pattern BEARER = Pattern.compile("(?i)(authorization\\s*[:=]\\s*bearer\\s+)\\S+");
    private static final Pattern SECRET = Pattern.compile(
            "(?i)\\b(token|secret|password|pairing_code|code)\\s*[:=]\\s*[\\\"']?([^\\s,\\\"'}]+)");
    private static final Pattern NUMBER_FIELD = Pattern.compile(
            "(?i)(\\b(?:number|phone|tel)\\b\\s*[:=]\\s*[\\\"']?)\\+?[0-9*# -]{6,24}");
    private static final Pattern PHONE_LIKE = Pattern.compile("(?<![\\w.])\\+?\\d{7,15}(?![\\w.])");

    private DebugRedactor() {}

    public static String safeNumber(String ignored) {
        return "[redacted]";
    }

    public static String safeIdentifier(String value) {
        if (value == null) return "";
        return value.length() <= 128 ? value : value.substring(0, 128);
    }

    public static String sanitize(String value) {
        if (value == null) return "";
        String safe = BEARER.matcher(value).replaceAll("$1[redacted]");
        safe = SECRET.matcher(safe).replaceAll("$1=[redacted]");
        safe = NUMBER_FIELD.matcher(safe).replaceAll("$1[redacted]");
        return PHONE_LIKE.matcher(safe).replaceAll("[redacted]");
    }
}
