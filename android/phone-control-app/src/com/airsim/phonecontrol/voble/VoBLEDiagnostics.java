package com.airsim.phonecontrol.voble;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/** Deliberately excludes call numbers, credentials, nonces, tags, and media bytes. */
public final class VoBLEDiagnostics {
    public record Snapshot(
            String runtime, boolean authenticated, boolean pcmReady, String codec,
            long downlinkFrames, long uplinkFrames, long droppedFrames, String lastError) {
        public Map<String, String> sanitizedFields() {
            Map<String, String> values = new LinkedHashMap<>();
            values.put("runtime", safe(runtime));
            values.put("authenticated", Boolean.toString(authenticated));
            values.put("pcm_ready", Boolean.toString(pcmReady));
            values.put("codec", safe(codec));
            values.put("downlink_frames", Long.toString(Math.max(0, downlinkFrames)));
            values.put("uplink_frames", Long.toString(Math.max(0, uplinkFrames)));
            values.put("dropped_frames", Long.toString(Math.max(0, droppedFrames)));
            values.put("last_error", categorize(lastError));
            return Map.copyOf(values);
        }
    }

    private VoBLEDiagnostics() {}

    public static Snapshot idle(String runtime) {
        return new Snapshot(runtime, false, false, "G.711-mu/8000/mono", 0, 0, 0, "");
    }

    public static String summary(Snapshot value) {
        if (value == null) return "VoBLE 待启动";
        if (!value.authenticated()) return "VoBLE 等待认证";
        if (!value.pcmReady()) return "VoBLE 已认证 · PCM 待启动";
        return "VoBLE 已认证 · PCM 运行中 · 丢帧 " + Math.max(0, value.droppedFrames());
    }

    public static Map<String, String> sanitize(Map<String, String> input) {
        Map<String, String> output = new LinkedHashMap<>();
        if (input == null) return output;
        for (Map.Entry<String, String> entry : input.entrySet()) {
            String key = entry.getKey() == null ? "" : entry.getKey().toLowerCase(Locale.ROOT);
            if (key.contains("number") || key.contains("phone") || key.contains("secret")
                    || key.contains("nonce") || key.contains("tag") || key.contains("payload")
                    || key.contains("key")) continue;
            output.put(entry.getKey(), safe(entry.getValue()));
        }
        return output;
    }

    private static String categorize(String error) {
        String value = error == null ? "" : error.toLowerCase(Locale.ROOT);
        if (value.isBlank()) return "none";
        if (value.contains("auth") || value.contains("认证") || value.contains("key")) return "authentication";
        if (value.contains("pcm") || value.contains("media")) return "pcm";
        if (value.contains("timeout") || value.contains("超时")) return "timeout";
        if (value.contains("bluetooth") || value.contains("蓝牙")) return "bluetooth";
        return "unknown";
    }

    private static String safe(String value) {
        if (value == null) return "";
        return value.substring(0, Math.min(96, value.length()));
    }
}
