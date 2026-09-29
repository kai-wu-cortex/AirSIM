package com.airsim.phonecontrol;

public final class SMSPayloadPolicy {
    private SMSPayloadPolicy() {}

    public static boolean validDestination(String value) {
        if (value == null) return false;
        String trimmed = value.trim();
        if (trimmed.isEmpty() || trimmed.length() > 82) return false;
        for (int index = 0; index < trimmed.length(); index++) {
            char character = trimmed.charAt(index);
            if ((character >= '0' && character <= '9') || character == '+' || character == '*'
                    || character == '#' || character == ' ' || character == '-' || character == '('
                    || character == ')') continue;
            return false;
        }
        return true;
    }

    public static String normalizeDestination(String value) {
        if (!validDestination(value)) return "";
        return value.trim().replace(" ", "").replace("-", "").replace("(", "").replace(")", "");
    }

    public static boolean validBody(String value) {
        return value != null && !value.trim().isEmpty() && value.codePointCount(0, value.length()) <= 2000;
    }
}
