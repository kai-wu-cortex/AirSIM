package com.airsim.bridge;

import java.io.IOException;
import java.util.Map;

/** Stable, non-private error evidence across the privileged-process boundary. */
final class AudioStartupFailure extends IOException {
    private static final long serialVersionUID = 1L;
    private final String phase;
    private final String code;

    AudioStartupFailure(String phase, Throwable cause) {
        super("PCM startup failed at " + phase, cause);
        this.phase = phase;
        Throwable origin = origin(cause);
        this.code = origin instanceof SecurityException ? "permission_denied"
            : origin instanceof LinkageError ? "platform_api_unavailable"
            : phase.equals("select_uplink_route") && (origin instanceof NoSuchMethodException
                || origin instanceof IllegalAccessException) ? "telephony_query_unavailable"
            : phase.equals("select_uplink_route") && origin != cause ? "telephony_query_failed" : switch (phase) {
            case "buffer_sizes" -> "invalid_buffer_sizes";
            case "create_capture" -> "capture_create_failed";
            case "select_capture_route" -> "capture_route_unavailable";
            case "bind_capture_route" -> "capture_route_rejected";
            case "select_playback_format" -> "playback_format_unsupported";
            case "create_attributes" -> "attributes_create_failed";
            case "select_uplink_route" -> "telephony_tx_unavailable";
            case "create_playback" -> "playback_create_failed";
            case "bind_uplink_route" -> "telephony_tx_rejected";
            case "validate_capture" -> "capture_uninitialized";
            case "validate_playback" -> "playback_uninitialized";
            case "handshake" -> "handshake_failed";
            case "send_ready" -> "handshake_write_failed";
            case "start_capture" -> "capture_start_failed";
            case "start_playback" -> "playback_start_failed";
            case "verify_capture" -> "capture_not_recording";
            default -> "media_session_failed";
        };
    }

    Map<String, Object> diagnosticFields() {
        // Never export an OEM exception's arbitrary message, addresses, or call data.
        return Map.of("error_phase", phase, "error_code", code,
                "error_class", origin(getCause()).getClass().getSimpleName(), "result", "error");
    }

    private static Throwable origin(Throwable error) {
        for (int depth = 0; depth < 4 && error.getCause() != null && error.getCause() != error; depth++)
            error = error.getCause();
        return error;
    }
}
