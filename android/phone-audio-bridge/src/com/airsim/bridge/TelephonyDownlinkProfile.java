package com.airsim.bridge;

/** Format admission only. AudioRecord initialization and Telephony Rx routing are still mandatory. */
final class TelephonyDownlinkProfile {
    static boolean supports(int[] rates, int[] channels, int[] encodings) {
        return accepts(rates, 8000) && accepts(channels, 1) && accepts(encodings, 2);
    }
    private static boolean accepts(int[] values, int target) {
        if (values == null) return false;
        if (values.length == 0) return true; // Android: arbitrary values supported; validate by opening.
        for (int value : values) if (value == target) return true;
        return false;
    }
}
