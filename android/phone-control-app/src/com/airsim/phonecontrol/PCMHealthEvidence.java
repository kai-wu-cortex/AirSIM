package com.airsim.phonecontrol;

/** Whitelisted, non-audio evidence from the privileged helper for local TXT diagnostics. */
final class PCMHealthEvidence {
    private static final java.util.regex.Pattern FIELD = java.util.regex.Pattern.compile(
        "\"(event|error_phase|error_code|error_class|downlink_bytes|downlink_peak|uplink_bytes|uplink_peak|capability_query|tx_route|rx_route|tx_format|route_kind|capture_route|capture_silenced|profile)\"\\s*:\\s*(?:\"([A-Za-z0-9_.$]{1,64})\"|(\\d{1,18}))");
    private static final java.util.Set<String> EVENTS = java.util.Set.of("bridge_listening", "audio_initializing", "audio_initialized",
        "client_ready", "pcm_stats", "voice_tx_route_verified", "voice_tx_route_unverified",
        "session_error", "uplink_error", "downlink_error", "client_closed", "audio_capabilities", "voice_tx_route_observed", "capture_route_observed", "audio_profile");
    private String event = "waiting";
    private boolean initialized, routeVerified;
    private long downBytes, downPeak, upBytes, upPeak;
    private String failureEvent = "none", failurePhase = "unknown", failureCode = "unknown", failureClass = "unknown";
    private int failures;
    private String capabilityQuery = "unknown", txRoute = "unknown", rxRoute = "unknown", txFormat = "unknown";
    private String observedRoute = "unknown";
    private String captureRoute = "unknown", captureSilenced = "unknown", profile = "unknown";
    private final java.util.function.LongSupplier clock;
    private long readyAt, statsAt, downAdvancedAt, upAdvancedAt;
    private boolean hasStats;

    PCMHealthEvidence() { this(() -> System.nanoTime() / 1_000_000L); }
    PCMHealthEvidence(java.util.function.LongSupplier clock) { this.clock = clock; }

    synchronized void reset() {
        event = "waiting"; clearAudio(); clearFailure();
        capabilityQuery = txRoute = rxRoute = txFormat = "unknown";
    }
    private void clearAudio() {
        initialized = false; routeVerified = false;
        downBytes = 0; downPeak = 0; upBytes = 0; upPeak = 0;
        observedRoute = "unknown"; hasStats = false;
        captureRoute = captureSilenced = profile = "unknown";
        readyAt = statsAt = downAdvancedAt = upAdvancedAt = 0;
    }
    private void clearFailure() {
        failureEvent = "none"; failurePhase = "unknown"; failureCode = "unknown"; failureClass = "unknown";
        failures = 0;
    }
    synchronized void observe(String line) {
        if (line == null || line.length() > 4096 || !line.startsWith("{")) return;
        java.util.Map<String,String> fields = new java.util.HashMap<>();
        var matcher = FIELD.matcher(line);
        while (matcher.find()) fields.put(matcher.group(1), matcher.group(2) != null ? matcher.group(2) : matcher.group(3));
        String next = fields.get("event");
        if (!EVENTS.contains(next == null ? "" : next)) return;
        if (next.equals("audio_capabilities")) {
            capabilityQuery = choice(fields.get("capability_query"), "ok", "unavailable");
            txRoute = choice(fields.get("tx_route"), "samsung_tag", "telephony", "missing");
            rxRoute = choice(fields.get("rx_route"), "present", "not_exposed");
            txFormat = choice(fields.get("tx_format"), "native", "conversion");
            return; // Capability discovery must not replace the live media event.
        }
        if (next.equals("audio_profile")) {
            profile = choice(fields.get("profile"), "standard", "redmi9_mtk_experimental");
            return;
        }
        if (next.equals("capture_route_observed")) {
            captureRoute = choice(fields.get("capture_route"), "telephony", "other");
            captureSilenced = choice(fields.get("capture_silenced"), "yes", "no");
            return;
        }
        if (next.equals("bridge_listening")) reset();
        if (next.equals("audio_initializing") || next.equals("audio_initialized")) clearAudio();
        event = next;
        if (next.equals("client_ready")) {
            initialized = true; clearFailure();
            readyAt = downAdvancedAt = upAdvancedAt = clock.getAsLong();
        }
        if (next.equals("voice_tx_route_observed")) {
            observedRoute = choice(fields.get("route_kind"), "telephony", "other");
            routeVerified = "telephony".equals(observedRoute);
        }
        if (next.equals("voice_tx_route_verified")) {
            routeVerified = true;
            observedRoute = "telephony";
        }
        if (next.equals("voice_tx_route_unverified")) routeVerified = false;
        if (next.endsWith("_error")) {
            initialized = false;
            failureEvent = next;
            failurePhase = label(fields.get("error_phase"));
            failureCode = label(fields.get("error_code"));
            String type = fields.getOrDefault("error_class", "");
            failureClass = type.matches("[A-Za-z_$][A-Za-z_.$]{0,48}(Exception|Error)") ? type : "unknown";
            failures = Math.min(1000, failures + 1);
        }
        if (next.equals("client_closed")) initialized = false;
        long newDown = number(fields, "downlink_bytes", downBytes);
        long newUp = number(fields, "uplink_bytes", upBytes);
        if (next.equals("pcm_stats") && initialized) {
            statsAt = clock.getAsLong(); hasStats = true;
            if (newDown > downBytes) downAdvancedAt = statsAt;
            if (newUp > upBytes) upAdvancedAt = statsAt;
        }
        downBytes = newDown;
        downPeak = number(fields, "downlink_peak", downPeak);
        upBytes = newUp;
        upPeak = number(fields, "uplink_peak", upPeak);
    }
    private static String choice(String value, String... allowed) {
        for (String candidate : allowed) if (candidate.equals(value)) return candidate;
        return "unknown";
    }
    private static String label(String value) {
        return value != null && value.matches("[a-z][a-z_]{0,39}") ? value : "unknown";
    }
    private static long number(java.util.Map<String,String> fields, String name, long fallback) {
        try { return Long.parseLong(fields.get(name)); }
        catch (NumberFormatException ignored) { return fallback; }
    }
    synchronized String snapshot() {
        long now = clock.getAsLong();
        // Peaks are cumulative PCM16 magnitudes. 0/1 is silence/quantization noise,
        // not evidence of audible speech. A larger peak still does not prove playback.
        String capture = downBytes == 0 ? "not_observed" : downPeak == 0 ? "all_zero"
            : downPeak == 1 ? "near_zero" : "observed";
        return "pcm_event=" + event + " pcm_initialized=" + initialized + " pcm_capture=" + capture
            + " pcm_route=" + (routeVerified ? "verified" : "unverified")
            + " pcm_down_bytes=" + downBytes + " pcm_down_peak=" + downPeak
            + " pcm_up_bytes=" + upBytes + " pcm_up_peak=" + upPeak
            + " pcm_failure=" + failureEvent + " pcm_error_phase=" + failurePhase
            + " pcm_error_code=" + failureCode + " pcm_error_class=" + failureClass
            + " pcm_failure_count=" + failures
            + " pcm_cap_query=" + capabilityQuery + " pcm_cap_tx=" + txRoute
            + " pcm_cap_rx=" + rxRoute + " pcm_cap_format=" + txFormat
            + " pcm_route_observed=" + observedRoute
            + " pcm_profile=" + profile + " pcm_capture_route=" + captureRoute + " pcm_capture_silenced=" + captureSilenced
            + " pcm_session_age_ms=" + (initialized ? Math.max(0, now - readyAt) : 0)
            + " pcm_stats_age_ms=" + (hasStats ? Math.max(0, now - statsAt) : -1)
            + " pcm_down_idle_ms=" + (initialized ? Math.max(0, now - downAdvancedAt) : 0)
            + " pcm_up_idle_ms=" + (initialized ? Math.max(0, now - upAdvancedAt) : 0);
    }
}
