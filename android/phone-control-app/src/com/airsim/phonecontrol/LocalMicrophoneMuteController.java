package com.airsim.phonecontrol;

import java.io.IOException;

/** Owns only the Android microphone mute bit, never the injected iPhone PCM track. */
final class LocalMicrophoneMuteController {
    interface Backend {
        boolean muted() throws Exception;
        void setMuted(boolean muted) throws Exception;
    }
    private final Backend backend;
    private boolean started, original;
    private volatile boolean verified;
    LocalMicrophoneMuteController(Backend backend) { this.backend = backend; }
    boolean verified() { return verified; }
    String setMuted(boolean muted) throws Exception {
        if (!muted) return restore();
        if (!started) { original = backend.muted(); started = true; }
        verified = false;
        try {
            if (!backend.muted()) backend.setMuted(true);
            if (!backend.muted()) throw new IOException("Android microphone mute was not accepted");
            verified = true;
            return "android_microphone_muted=true microphone_verified=true";
        } catch (Exception error) {
            try { restore(); } catch (Exception failure) { error.addSuppressed(failure); }
            throw error;
        }
    }
    private String restore() throws Exception {
        verified = false;
        if (!started) return "android_microphone_unchanged=true";
        if (backend.muted() != original) backend.setMuted(original);
        if (backend.muted() != original) throw new IOException("Android microphone restoration failed");
        started = false;
        return "android_microphone_restored=true previous_microphone_muted=" + original;
    }
}
