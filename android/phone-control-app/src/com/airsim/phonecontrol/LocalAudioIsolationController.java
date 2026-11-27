package com.airsim.phonecontrol;

import java.io.IOException;

/** Owns physical call sinks and microphone, never the PCM track or stream-wide mute. */
final class LocalAudioIsolationController {
    interface Api extends CallOutputPolicyMute.Api {
        boolean microphoneMuted() throws Exception;
        void microphoneMuted(boolean muted) throws Exception;
        boolean streamMuted() throws Exception;
    }

    private final Api api;
    private final CallOutputPolicyMute outputs;
    private boolean started, originalMicrophone, restoring;
    private volatile boolean verified;

    LocalAudioIsolationController(Api api) {
        this.api = api;
        outputs = new CallOutputPolicyMute(api);
    }

    boolean verified() { return verified; }

    String setIsolated(boolean isolate) throws Exception {
        if (!isolate) return restore();
        // A partially restored cycle must finish before acquiring another snapshot.
        if (restoring) restore();
        if (!started) {
            boolean microphone = api.microphoneMuted();
            outputs.prepare(api.streamMuted());
            originalMicrophone = microphone;
            started = true;
        }
        verified = false;
        try {
            if (!api.microphoneMuted()) api.microphoneMuted(true);
            outputs.apply();
            if (!api.microphoneMuted()) throw new IOException("本机麦克风静音回读失败");
            verified = true;
            return "local_audio_isolated mic_muted=true earpiece_index=0 speaker_index=0"
                    + " framework_stream_unchanged=true acoustic_check=unavailable";
        } catch (Exception error) {
            try { restore(); }
            catch (Exception cleanup) { error.addSuppressed(cleanup); }
            throw error;
        }
    }

    private String restore() throws Exception {
        verified = false;
        if (!started) return "local_audio_isolation_unchanged";
        restoring = true;
        Exception failure = null;
        try { outputs.restore(); }
        catch (Exception error) { failure = error; }
        try {
            if (api.microphoneMuted() != originalMicrophone) api.microphoneMuted(originalMicrophone);
            if (api.microphoneMuted() != originalMicrophone)
                throw new IOException("本机麦克风状态恢复回读失败");
        } catch (Exception error) {
            if (failure == null) failure = error;
            else failure.addSuppressed(error);
        }
        if (failure != null) throw failure; // Keep snapshots for disconnect/destroy retry.
        started = false;
        restoring = false;
        return "local_audio_isolation_restored verified=true";
    }
}
