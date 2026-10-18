package com.airsim.phonecontrol;

import java.io.IOException;

/** One remote-call mute cycle; the backend runs with Shizuku shell/root identity. */
final class LocalOutputMuteController {
    enum Strategy { MUTE, MINIMUM_VOLUME }
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
    boolean usesMinimumVolume() { return strategy == Strategy.MINIMUM_VOLUME; }
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
                targetMinimum = minimum;
            } else { backend.prepareOutputMute(originalMuted); }
            previousMuted = originalMuted;
            previousVolume = originalVolume;
            started = true;
        }
        try {
            if (usesMinimumVolume()) {
                verifiedMinimum = false;
                // Samsung's mute flags may not affect the cellular earpiece.
                // Write its supported audible minimum explicitly, never PCM gain.
                backend.setVolume(targetMinimum);
                if (previousMuted && !backend.isMuted()) backend.setMuted(true);
                if (backend.volume() != targetMinimum || (previousMuted && !backend.isMuted()))
                    throw new IOException("系统未接受最低通话音量");
                verifiedMinimum = true;
                return "local_output_minimum_volume minimum_volume=" + targetMinimum
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
