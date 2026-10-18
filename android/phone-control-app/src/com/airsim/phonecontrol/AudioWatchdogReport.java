package com.airsim.phonecontrol;

import java.time.Instant;

/** Plain UTF-8 text, no PCM, system-wide audio dump or unredacted call data. */
final class AudioWatchdogReport {
    private AudioWatchdogReport() {}
    static String compose(String version, int sdk, String manufacturer, String model, String log) {
        return DebugRedactor.sanitize("AirSIM Android VERBOSE diagnostics\nexported_at=" + Instant.now()
                + "\napp=" + version + "\nandroid_sdk=" + sdk + "\nmanufacturer=" + manufacturer + "\nmodel=" + model
                + "\n\nWatchdog: checks every 2s during one confirmed remote PCM/native call."
                + "\nRepairs: reapply output target (Samsung minimum call volume, other devices stream mute); refresh policy; recover privileged transport when unavailable."
                + "\nLimits: 3 attempts/session, 15s cooldown; no audio-service restart, PCM restart or automatic hangup."
                + "\nverified_muted reports OS stream flags only; acoustic_check=unavailable."
                + "\nverified_minimum reports the intended audible volume index only, NOT acoustic silence or PCM quality."
                + "\nUnknown/OEM failures are NOT proof of successful repair."
                + "\nSnapshots are kept locally even when general Debug is off; rotated log is bounded."
                + "\n\n--- LOCAL VERBOSE LOG ---\n" + (log == null ? "" : log));
    }
}
