package com.airsim.bridge;

import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import java.lang.reflect.Method;
import java.util.Map;

/** Read-only discovery. Never creates recording/playback endpoints or changes routing. */
final class AudioCapabilityProbe {
    static Map<String, Object> inspect() {
        boolean samsung = false;
        try {
            AudioAttributes.Builder.class.getMethod("semAddAudioTag", String.class);
            samsung = true;
        } catch (ReflectiveOperationException | RuntimeException ignored) {}
        try {
            Method query = AudioManager.class.getMethod("getDevicesStatic", int.class);
            AudioDeviceInfo[] devices = (AudioDeviceInfo[]) query.invoke(null, AudioManager.GET_DEVICES_ALL);
            AudioDeviceInfo tx = null;
            boolean rx = false;
            for (AudioDeviceInfo device : devices) {
                if (device.getType() != AudioDeviceInfo.TYPE_TELEPHONY) continue;
                if (device.isSource()) rx = true;
                if (device.isSink() && tx == null) tx = device;
            }
            return Map.of("capability_query", "ok", "tx_route", samsung ? "samsung_tag" : tx != null ? "telephony" : "missing",
                "rx_route", rx ? "present" : "not_exposed",
                "tx_format", tx == null ? "unknown" : format(tx.getSampleRates(), tx.getChannelCounts(), tx.getEncodings()));
        } catch (ReflectiveOperationException | RuntimeException | LinkageError error) {
            // An inaccessible query is not evidence of absent hardware.
            return Map.of("capability_query", "unavailable", "tx_route", samsung ? "samsung_tag" : "unknown",
                "rx_route", "unknown", "tx_format", "unknown");
        }
    }

    static String format(int[] rates, int[] channels, int[] encodings) {
        if (rates == null || channels == null || encodings == null
                || rates.length == 0 || channels.length == 0 || encodings.length == 0) return "unknown";
        return contains(rates, 8000) && contains(channels, 1) && contains(encodings, AudioFormat.ENCODING_PCM_16BIT)
            ? "native" : "conversion";
    }

    private static boolean contains(int[] values, int value) {
        for (int candidate : values) if (candidate == value) return true;
        return false;
    }
}
