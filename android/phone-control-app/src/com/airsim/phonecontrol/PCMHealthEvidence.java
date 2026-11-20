package com.airsim.phonecontrol;

/** Whitelisted, non-audio evidence from the privileged helper for local TXT diagnostics. */
final class PCMHealthEvidence {
    private static final java.util.regex.Pattern FIELD = java.util.regex.Pattern.compile(
        "\"(event|error_phase|error_code|error_class|downlink_bytes|downlink_peak|uplink_bytes|uplink_peak)\"\\s*:\\s*(?:\"([A-Za-z0-9_.$]{1,64})\"|(\\d{1,18}))");
    private static final java.util.Set<String> EVENTS = java.util.Set.of("bridge_listening", "listener_restarting", "audio_initializing", "audio_initialized",
        "client_ready", "pcm_stats", "voice_tx_route_verified", "voice_tx_route_unverified",
        "session_error", "uplink_error", "downlink_error", "client_closed");
    private String event = "waiting";
    private boolean listening, initialized, routeVerified;
    private long downBytes, downPeak, upBytes, upPeak;
    private String failureEvent = "none", failurePhase = "unknown", failureCode = "unknown", failureClass = "unknown";
    private int failures;
    private String stage = "waiting", recovery = "none";
    private int recoveryAttempts;
    private long recoveryStartedAt, recoveryElapsedMs;
    private String lastFailure = "none", lastPhase = "unknown", lastClass = "unknown";

    synchronized void reset() {
        event = "waiting"; stage = "waiting"; listening = false; clearAudio(); clearFailure();
    }
    private void clearAudio() {
        initialized = false; routeVerified = false;
        downBytes = 0; downPeak = 0; upBytes = 0; upPeak = 0;
    }
    private void clearFailure() {
        failureEvent = "none"; failurePhase = "unknown"; failureCode = "unknown"; failureClass = "unknown";
        failures = 0;
    }
    synchronized void observe(String line) { observe(line, 0); }
    synchronized void observe(String line, long now) {
        if (line == null || line.length() > 4096 || !line.startsWith("{")) return;
        java.util.Map<String,String> fields = new java.util.HashMap<>();
        var matcher = FIELD.matcher(line);
        while (matcher.find()) fields.put(matcher.group(1), matcher.group(2) != null ? matcher.group(2) : matcher.group(3));
        String next = fields.get("event");
        if (!EVENTS.contains(next == null ? "" : next)) return;
        if (next.equals("bridge_listening")) {
            reset();
            listening = true;
        } else if (next.equals("listener_restarting")) {
            listening = false;
            clearAudio();
        }
        if (next.equals("audio_initializing") || next.equals("audio_initialized")) clearAudio();
        event = next;
        if (next.equals("bridge_listening")) stage = "listening";
        if (next.equals("listener_restarting")) stage = "recovering";
        if (next.equals("audio_initializing") || next.equals("audio_initialized")) stage = "initializing";
        if (next.equals("client_ready")) {
            initialized = true; stage = "handshake_ready";
            downBytes = 0; upBytes = 0; downPeak = 0; upPeak = 0; clearFailure();
        }
        if (next.equals("voice_tx_route_verified")) routeVerified = true;
        if (next.equals("voice_tx_route_unverified")) routeVerified = false;
        if (next.endsWith("_error")) {
            initialized = false; stage = "failed";
            failureEvent = next;
            failurePhase = label(fields.get("error_phase"));
            failureCode = label(fields.get("error_code"));
            String type = fields.getOrDefault("error_class", "");
            failureClass = type.matches("[A-Za-z_$][A-Za-z_.$]{0,48}(Exception|Error)") ? type : "unknown";
            lastFailure = failureEvent; lastPhase = failurePhase; lastClass = failureClass;
            failures = Math.min(1000, failures + 1);
        }
        if (next.equals("client_closed")) { initialized = false; stage = "listening"; clearAudio(); }
        downBytes = number(fields, "downlink_bytes", downBytes);
        downPeak = number(fields, "downlink_peak", downPeak);
        upBytes = number(fields, "uplink_bytes", upBytes);
        upPeak = number(fields, "uplink_peak", upPeak);
        if (initialized && downBytes > 0 && upBytes > 0) {
            // Zero amplitude is valid silence; byte flow is not proof of audible sound.
            stage = "media_flow";
            if (recovery.equals("pending")) {
                recovery = "verified";
                recoveryElapsedMs = Math.max(0, now - recoveryStartedAt);
            }
        }
    }
    synchronized void processExited(int code) {
        listening = false; clearAudio(); stage = "failed"; event = "process_exit";
        failureEvent = "process_exit"; failurePhase = "helper_process";
        failureCode = code < 0 ? "exit_unknown" : "exit_" + code;
        failureClass = "unknown"; failures = Math.min(1000, failures + 1);
        lastFailure = failureEvent; lastPhase = failurePhase; lastClass = failureClass;
    }
    synchronized void recoveryScheduled(long now) {
        recovery = "pending"; stage = "recovering";
        recoveryAttempts = Math.min(1000, recoveryAttempts + 1); recoveryStartedAt = now;
    }
    private static String label(String value) {
        return value != null && value.matches("[a-z][a-z_]{0,39}") ? value : "unknown";
    }
    private static long number(java.util.Map<String,String> fields, String name, long fallback) {
        try { return Long.parseLong(fields.get(name)); }
        catch (NumberFormatException ignored) { return fallback; }
    }
    synchronized boolean isListening() { return listening; }

    synchronized String snapshot() {
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
            + " pcm_last_failure=" + lastFailure + " pcm_last_error_phase=" + lastPhase
            + " pcm_last_error_class=" + lastClass
            + " pcm_stage=" + stage + " pcm_recovery=" + recovery
            + " pcm_recovery_attempts=" + recoveryAttempts + " pcm_recovery_ms=" + recoveryElapsedMs;
    }
}
