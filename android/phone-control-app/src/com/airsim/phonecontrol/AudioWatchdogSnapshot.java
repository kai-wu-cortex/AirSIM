package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/** Observed OS flags, never an assertion that a physical speaker is acoustically silent. */
record AudioWatchdogSnapshot(boolean muted, int volume, int mode, boolean speaker, boolean pcm,
        String mediaEvidence, boolean minimumVolumePolicy, int minimumVolume) {
    static AudioWatchdogSnapshot parse(String value) throws IOException {
        Map<String, String> fields = new HashMap<>();
        for (String item : (value == null ? "" : value).trim().split("\\s+")) {
            String[] pair = item.split("=", 2);
            if (pair.length == 2) fields.put(pair[0], pair[1]);
        }
        try {
            int volume = Integer.parseInt(fields.get("volume"));
            int mode = Integer.parseInt(fields.get("mode"));
            if (volume < 0) throw new IllegalArgumentException();
            boolean minimumPolicy = "minimum_volume".equals(fields.get("output_policy"));
            int minimum = Integer.parseInt(fields.getOrDefault("minimum_volume", "-1"));
            if (minimum < -1 || minimum > 1000) throw new IllegalArgumentException();
            String evidence = java.util.List.of("pcm_event", "pcm_initialized", "pcm_capture", "pcm_route",
                    "pcm_down_bytes", "pcm_down_peak", "pcm_up_bytes", "pcm_up_peak", "output_policy").stream()
                .filter(key -> fields.getOrDefault(key, "").matches("[a-zA-Z0-9_]{1,32}"))
                .map(key -> key + "=" + fields.get(key)).collect(java.util.stream.Collectors.joining(" "));
            return new AudioWatchdogSnapshot(bool(fields, "muted"), volume, mode,
                    bool(fields, "speaker"), bool(fields, "pcm"), evidence, minimumPolicy, minimum);
        } catch (RuntimeException error) { throw new IOException("invalid audio snapshot", error); }
    }
    private static boolean bool(Map<String, String> fields, String key) {
        String value = fields.get(key);
        if (!"true".equals(value) && !"false".equals(value)) throw new IllegalArgumentException(key);
        return "true".equals(value);
    }
    String diagnostic() {
        return "muted=" + muted + " volume=" + volume + " mode=" + mode
                + " speaker=" + speaker + " pcm=" + pcm + " acoustic_check=unavailable " + mediaEvidence
                + (minimumVolumePolicy ? " minimum_volume=" + minimumVolume : "");
    }
    boolean targetSatisfied() { return minimumVolumePolicy ? minimumVolume >= 0 && volume == minimumVolume : muted; }
}
