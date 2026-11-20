package com.airsim.phonecontrol;

public final class PCMHealthEvidenceTests {
    public static void main(String[] args) {
        recoveryRequiresFreshDuplexFlowAndRetainsExitCause();
        startupFailureSurvivesCloseAndRetryUntilReady();
        listenerReadinessTracksSuccessfulBind();
        PCMHealthEvidence health = new PCMHealthEvidence();
        health.observe("{\"event\":\"client_ready\",\"result\":\"audio_initialized\"}");
        health.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":320,\"downlink_peak\":0,\"uplink_bytes\":640,\"uplink_peak\":900,\"number\":\"private\",\"secret\":\"secret-value\"}");
        String silent = health.snapshot();
        check(silent.contains("pcm_capture=all_zero"), "zero PCM incorrectly reported as usable capture");
        check(silent.contains("pcm_route=unverified"), "handshake is not route verification");
        check(!silent.contains("private") && !silent.contains("secret"), "private values entered TXT diagnostics");
        health.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":30720,\"downlink_peak\":1}");
        check(health.snapshot().contains("pcm_capture=near_zero"),
                "peak 1 quantization noise must not be presented as usable downlink evidence");
        health.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":216960,\"downlink_peak\":6280}");
        check(health.snapshot().contains("pcm_capture=observed"), "nonzero amplitude evidence must remain visible");
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
    private static void recoveryRequiresFreshDuplexFlowAndRetainsExitCause() {
        PCMHealthEvidence h = new PCMHealthEvidence();
        h.observe("{\"event\":\"bridge_listening\"}");
        h.observe("{\"event\":\"client_ready\"}");
        h.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":320,\"uplink_bytes\":320}");
        check(h.snapshot().contains("pcm_stage=media_flow"), "silent frames still prove byte flow");
        h.processExited(137);
        check(!h.isListening() && h.snapshot().contains("pcm_initialized=false"), "dead process retained readiness");
        check(h.snapshot().contains("pcm_error_code=exit_137"), "exit code missing");
        h.recoveryScheduled(1000); h.reset();
        h.observe("{\"event\":\"bridge_listening\"}", 1010);
        h.observe("{\"event\":\"client_ready\"}", 1020);
        check(h.snapshot().contains("pcm_recovery=pending"), "ACK prematurely marked recovery complete");
        h.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":320,\"uplink_bytes\":0}", 1030);
        check(h.snapshot().contains("pcm_recovery=pending"), "one direction incorrectly verified duplex");
        h.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":640,\"uplink_bytes\":320}", 1040);
        check(h.snapshot().contains("pcm_recovery=verified") && h.snapshot().contains("pcm_recovery_ms=40"), "fresh duplex not verified");
        check(h.snapshot().contains("pcm_last_failure=process_exit"), "recovery erased the failure cause");
        try {
            String txt = AudioWatchdogSnapshot.parse("muted=true volume=0 mode=2 speaker=false pcm=true " + h.snapshot()).diagnostic();
            check(txt.contains("pcm_recovery=verified") && txt.contains("pcm_stage=media_flow"), "diagnostic export lost stages");
        } catch (java.io.IOException e) { throw new AssertionError(e); }
    }

    private static void listenerReadinessTracksSuccessfulBind() {
        PCMHealthEvidence health = new PCMHealthEvidence();
        check(!health.isListening(), "spawned process has not yet bound its port");
        health.observe("{\"event\":\"listener_restarting\",\"error_class\":\"java.net.BindException\"}");
        check(!health.isListening(), "a bind retry is not a listener");
        health.observe("{\"event\":\"bridge_listening\"}");
        health.observe("{\"event\":\"client_closed\"}");
        check(health.isListening(), "closing one call does not stop the listener");
        health.observe("{\"event\":\"listener_restarting\"}");
        check(!health.isListening(), "failed listener must be marked unavailable");
    }

    private static void startupFailureSurvivesCloseAndRetryUntilReady() {
        PCMHealthEvidence health = new PCMHealthEvidence();
        health.observe("{\"event\":\"session_error\",\"error_phase\":\"create_capture\","
                + "\"error_code\":\"permission_denied\",\"error_class\":\"SecurityException\","
                + "\"error_message\":\"token=private-value phone=12345678901\"}");
        health.observe("{\"event\":\"client_closed\",\"downlink_bytes\":0,\"uplink_bytes\":0}");
        String closed = health.snapshot();
        check(closed.contains("pcm_failure=session_error") && closed.contains("pcm_error_phase=create_capture")
                && closed.contains("pcm_error_code=permission_denied")
                && closed.contains("pcm_error_class=SecurityException"),
                "client_closed erased the actual audio startup failure needed to diagnose Huawei resets");
        check(!closed.contains("private") && !closed.contains("12345678901") && !closed.contains("token"),
                "failure export must never include arbitrary native error messages");
        try {
            String exported = AudioWatchdogSnapshot.parse("muted=false volume=4 mode=2 speaker=false pcm=true " + closed).diagnostic();
            check(exported.contains("pcm_error_code=permission_denied") && exported.contains("pcm_error_phase=create_capture"),
                    "final Watchdog TXT dropped the retained native failure at the Binder snapshot boundary");
        } catch (java.io.IOException error) { throw new AssertionError(error); }
        health.observe("{\"event\":\"audio_initializing\"}");
        health.observe("{\"event\":\"audio_initialized\"}");
        check(health.snapshot().contains("pcm_error_code=permission_denied"),
                "resource initialization alone does not prove a failed route has recovered");
        health.observe("{\"event\":\"client_ready\"}");
        check(!health.snapshot().contains("pcm_error_code=permission_denied"),
                "successful audio READY must clear the earlier failure, not mislabel the new session");
        health.observe("{\"event\":\"session_error\",\"error_phase\":\"private=secret\",\"error_code\":\"12345678901\","
                + "\"error_class\":\"https://private.example\",\"error_message\":\"private-value\"}");
        check(!health.snapshot().contains("secret") && !health.snapshot().contains("12345678901")
                && !health.snapshot().contains("private"), "malformed diagnostic labels leaked private error text");
        health.reset();
        check(health.snapshot().contains("pcm_failure=none") && health.snapshot().contains("pcm_failure_count=0"),
                "helper process restart retained a previous process failure");
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
