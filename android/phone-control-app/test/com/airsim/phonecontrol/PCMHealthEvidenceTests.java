package com.airsim.phonecontrol;

public final class PCMHealthEvidenceTests {
    public static void main(String[] args) {
        PCMHealthEvidence health = new PCMHealthEvidence();
        health.observe("{\"event\":\"client_ready\",\"result\":\"audio_initialized\"}");
        health.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":320,\"downlink_peak\":0,\"uplink_bytes\":640,\"uplink_peak\":900,\"number\":\"private\",\"secret\":\"secret-value\"}");
        String silent = health.snapshot();
        check(silent.contains("pcm_capture=all_zero"), "zero PCM incorrectly reported as usable capture");
        check(silent.contains("pcm_route=unverified"), "handshake is not route verification");
        check(!silent.contains("private") && !silent.contains("secret"), "private values entered TXT diagnostics");
        health.observe("{\"event\":\"voice_tx_route_verified\"}");
        check(health.snapshot().contains("pcm_route=verified"), "observed route verification missing");
        health.observe("{\"event\":\"audio_initialized\"}");
        check(health.snapshot().contains("pcm_capture=not_observed"), "new call retained old capture evidence");
        check(health.snapshot().contains("pcm_route=unverified"), "new call retained old route verification");
        health.observe("{\"event\":\"session_error\",\"error_message\":\"private exception\"}");
        check(health.snapshot().contains("pcm_event=session_error"), "initialization failure missing");
        health.observe("unstructured stack trace with private data");
        check(!health.snapshot().contains("private"), "unknown log was persisted");
        System.out.println("PCM health evidence tests passed");
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
