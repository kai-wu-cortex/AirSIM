package com.airsim.bridge;

/** Narrow, experimental profile for the inspected Redmi 9 / MT6768 ROM family. */
final class Redmi9PCMProfile {
    static boolean matches(String manufacturer, String device, String hardware) {
        return ("xiaomi".equalsIgnoreCase(manufacturer) || "redmi".equalsIgnoreCase(manufacturer))
                && "lancelot".equalsIgnoreCase(device) && "mt6768".equalsIgnoreCase(hardware);
    }
    static boolean supports(int[] rates, int[] channels, int[] encodings, int rate, int channelCount) {
        return contains(rates, rate) && contains(channels, channelCount) && contains(encodings, 2);
    }
    static int playbackRate(int[] rates, int[] channels, int[] encodings) {
        if (supports(rates, channels, encodings, 48000, 2)) return 48000;
        if (supports(rates, channels, encodings, 8000, 1)) return 8000;
        throw new IllegalStateException("Redmi 9 Telephony Tx has no supported PCM16 profile");
    }
    private static boolean contains(int[] values, int target) {
        if (values == null) return false;
        for (int value : values) if (value == target) return true;
        return false;
    }
}
