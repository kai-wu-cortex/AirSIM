package com.airsim.phonecontrol;

import java.time.Instant;

/** Plain UTF-8 text, no PCM, system-wide audio dump or unredacted call data. */
final class AudioWatchdogReport {
    private AudioWatchdogReport() {}
    static String compose(String version, int sdk, String manufacturer, String model, String log) {
        return DebugRedactor.sanitize("AirSIM Android VERBOSE diagnostics\nexported_at=" + Instant.now()
                + "\napp=" + version + "\nandroid_sdk=" + sdk + "\nmanufacturer=" + manufacturer + "\nmodel=" + model
                + "\n\nWatchdog: checks every 2s during one confirmed remote PCM/native call."
                + "\nRepairs: obey the selected output policy. preserve_volume never changes user volume/mute; minimum_nonzero_volume maintains the lowest nonzero unmuted index. Recover privileged transport when unavailable."
                + "\nLimits: 3 attempts/session, 15s cooldown; no audio-service restart, PCM restart or automatic hangup."
                + "\nverified_muted reports OS stream flags only; acoustic_check=unavailable."
                + "\npreserve_volume cannot guarantee local acoustic silence; independent output attenuation is not implemented.\nverified_minimum reports the intended audible volume index only, NOT acoustic silence or PCM quality."
                + "\npcm_capture=all_zero/near_zero means cumulative PCM16 peak 0/1; byte flow or verified uplink route does NOT prove audible downlink/playback. Silence alone never triggers repair."
                + "\npcm_failure/pcm_error_phase/pcm_error_code retain the last native audio failure across client_closed and retries until actual audio READY; only bounded labels/classes are exported, never arbitrary OEM messages."
                + "\npermission_denied indicates an OS permission rejection; telephony_tx_unavailable/rejected indicates missing/rejected cellular uplink; capture/playback_* identifies endpoint initialization/start failure. Listener running is NOT audio READY."
                + "\nUnknown/OEM failures are NOT proof of successful repair."
                + "\nSnapshots are kept locally even when general Debug is off; rotated log is bounded."
                + "\n\n--- LOCAL VERBOSE LOG ---\n" + (log == null ? "" : log));
    }
}
