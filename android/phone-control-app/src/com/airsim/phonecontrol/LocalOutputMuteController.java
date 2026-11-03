package com.airsim.phonecontrol;

import java.io.IOException;

/** One remote-call mute cycle; the backend runs with Shizuku shell/root identity. */
final class LocalOutputMuteController {
    enum Strategy { MUTE, MINIMUM_VOLUME, MINIMUM_NONZERO_VOLUME }
    static Strategy strategyForManufacturer(String manufacturer) {
        // Some vendor HALs expose VOICE_DOWNLINK capture that is coupled to the
        // call stream mute/zero index: setting muted=true or volume=0 produces
        // all-zero downlink, so neither side hears the remote party. Do not use a
        // real mute on any manufacturer; always use the lowest NONZERO index and
        // keep the capture stream unmuted.
        return Strategy.MINIMUM_NONZERO_VOLUME;
    }

    /** Every remote-audio path uses the same capture-safe minimum-volume policy. */
    static Strategy vobleStrategy() {
        return strategyForManufacturer(android.os.Build.MANUFACTURER);
    }

    static Strategy vowlanStrategy() {
        return strategyForManufacturer(android.os.Build.MANUFACTURER);
    }
    interface Backend {
        boolean isMuted() throws Exception;
        int volume() throws Exception;
        void setMuted(boolean muted) throws Exception;
        void setVolume(int volume) throws Exception;
        default int minimumVolume() throws Exception { throw new IOException("minimum volume unsupported"); }
        default void prepareOutputMute(boolean originalMuted) throws Exception {}
        default void applyOutputMute() throws Exception {}
        default void restoreOutputMute() throws Exception {}
    }

    private final Backend backend;
    private final Strategy strategy;
    private boolean started;
    private boolean previousMuted;
    private int previousVolume;
    private volatile boolean verifiedMuted;
    private volatile boolean verifiedMinimum;
    private volatile int targetMinimum = -1;

    LocalOutputMuteController(Backend backend) { this(backend, Strategy.MUTE); }
    LocalOutputMuteController(Backend backend, Strategy strategy) {
        this.backend = backend; this.strategy = strategy;
    }
    boolean isVerifiedMuted() { return verifiedMuted; }
    boolean isVerifiedMinimum() { return verifiedMinimum; }
    boolean usesMinimumVolume() { return strategy != Strategy.MUTE; }
    /** Exposes the exact OS boundary this controller owns (tests and diagnostics). */
    Backend backend() { return backend; }
    private boolean requiresUnmutedCapture() { return strategy == Strategy.MINIMUM_NONZERO_VOLUME; }
    static String policyName(Strategy strategy) {
        return switch (strategy) {
            case MUTE -> "mute";
            case MINIMUM_VOLUME -> "minimum_volume";
            case MINIMUM_NONZERO_VOLUME -> "minimum_nonzero_volume";
        };
    }
    String policyName() { return policyName(strategy); }
    int targetMinimumVolume() { return targetMinimum; }
    String setMuted(boolean muted) throws Exception {
        if (!muted) return restore();
        if (!started) {
            // Finish all reads before marking the snapshot usable or changing system audio.
            boolean originalMuted = backend.isMuted();
            int originalVolume = backend.volume();
            if (usesMinimumVolume()) {
                int minimum = backend.minimumVolume();
                if (minimum < 0 || minimum > 1000) throw new IOException("invalid call minimum volume");
                targetMinimum = requiresUnmutedCapture() ? Math.max(1, minimum) : minimum;
            } else { backend.prepareOutputMute(originalMuted); }
            previousMuted = originalMuted;
            previousVolume = originalVolume;
            started = true;
        }
        try {
            if (usesMinimumVolume()) {
                verifiedMinimum = false;
                // Samsung: OS minimum. Capture-coupled HAL: lowest NONZERO unmuted
                // stream, otherwise suppressing the earpiece also suppresses VOICE_DOWNLINK.
                // Neither path changes PCM gain or the microphone.
                backend.setVolume(targetMinimum);
                if (requiresUnmutedCapture()) {
                    if (backend.isMuted()) backend.setMuted(false);
                } else if (previousMuted && !backend.isMuted()) backend.setMuted(true);
                if (backend.volume() != targetMinimum || (requiresUnmutedCapture()
                        ? backend.isMuted() : previousMuted && !backend.isMuted()))
                    throw new IOException("系统未接受最低通话音量");
                verifiedMinimum = true;
                return "local_output_" + policyName() + " minimum_volume=" + targetMinimum
                    + (requiresUnmutedCapture() ? " capture_stream_unmuted=true" : "")
                    + " volume_verified=true acoustic_check=unavailable";
            }
            // A previous call's framework flag is not proof that this call's HAL is muted.
            backend.setMuted(true);
            backend.applyOutputMute();
            verifiedMuted = backend.isMuted();
            if (!verifiedMuted) throw new IOException("系统不支持已验证的本机通话静音");
            return "local_output_muted previous_muted=" + previousMuted + " framework_verified=true acoustic_check=unavailable";
        } catch (Exception failure) {
            verifiedMuted = false;
            verifiedMinimum = false;
            try { restore(); }
            catch (Exception restoreFailure) { failure.addSuppressed(restoreFailure); }
            throw failure;
        }
    }

    /** Drops this controller's snapshot when another policy now owns the same stream. */
    void suspend() {
        started = false;
        verifiedMuted = false;
        verifiedMinimum = false;
        targetMinimum = -1;
    }

    private String restore() throws Exception {
        if (!started) return "local_output_unchanged";
        verifiedMuted = false;
        verifiedMinimum = false;
        Exception policyFailure = null;
        try { if (!usesMinimumVolume()) backend.restoreOutputMute(); }
        catch (Exception error) { policyFailure = error; }
        // Keep the snapshot until EVERY restoration check succeeds so disconnect/destroy can retry.
        // A positive volume write may unmute the stream: restore its mute bit LAST.
        try {
            if (backend.volume() != previousVolume) backend.setVolume(previousVolume);
        } catch (Exception error) {
            if (policyFailure == null) policyFailure = error;
            else policyFailure.addSuppressed(error);
        }
        try {
            if (backend.isMuted() != previousMuted) backend.setMuted(previousMuted);
        } catch (Exception error) {
            if (policyFailure == null) policyFailure = error;
            else policyFailure.addSuppressed(error);
        }
        if (backend.isMuted() != previousMuted || backend.volume() != previousVolume) {
            throw new IOException("本机通话声音状态恢复未通过校验");
        }
        if (policyFailure != null) throw policyFailure;
        boolean restoredMuted = previousMuted;
        started = false;
        verifiedMuted = false;
        targetMinimum = -1;
        return "local_output_restored previous_muted=" + restoredMuted + " verified=true";
    }
}
