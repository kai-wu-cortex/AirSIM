package com.airsim.phonecontrol;

import java.io.IOException;

/** Owns physical call sinks and microphone, never the PCM track or stream-wide mute. */
final class LocalAudioIsolationController {
    interface Api extends CallOutputPolicyMute.Api {
        boolean microphoneMuted() throws Exception;
        void microphoneMuted(boolean muted) throws Exception;
        boolean streamMuted() throws Exception;
    }
    record Snapshot(boolean microphone, boolean streamMuted, int earpiece, int speaker) {
        Snapshot {
            if (earpiece < 0 || earpiece > 1000 || speaker < 0 || speaker > 1000)
                throw new IllegalArgumentException("invalid isolation snapshot");
        }
    }
    interface Store {
        Snapshot read() throws Exception;
        void save(Snapshot snapshot) throws Exception;
        void clear() throws Exception;
    }
    static final class MemoryStore implements Store {
        private Snapshot snapshot;
        public Snapshot read() { return snapshot; }
        public void save(Snapshot value) { snapshot = value; }
        public void clear() { snapshot = null; }
    }

    private final Api api;
    private final CallOutputPolicyMute outputs;
    private final Store store;
    private boolean started, originalMicrophone, restoring;
    private volatile boolean verified;

    LocalAudioIsolationController(Api api) throws Exception { this(api, new MemoryStore()); }

    LocalAudioIsolationController(Api api, Store store) throws Exception {
        this.api = api;
        this.store = store;
        outputs = new CallOutputPolicyMute(api);
        Snapshot saved = store.read();
        if (saved != null) {
            outputs.prepare(saved.streamMuted(), saved.earpiece(), saved.speaker());
            originalMicrophone = saved.microphone();
            started = restoring = true;
        }
    }

    boolean verified() { return verified; }
    boolean pendingRestore() { return started; }
    boolean restoring() { return restoring; }

    String setIsolated(boolean isolate) throws Exception {
        if (!isolate) return restore();
        // A partially restored cycle must finish before acquiring another snapshot.
        if (restoring) restore();
        if (!started) {
            boolean microphone = api.microphoneMuted();
            Snapshot snapshot = new Snapshot(microphone, api.streamMuted(), api.index(1), api.index(2));
            // Durable recovery must succeed BEFORE changing any system audio state.
            store.save(snapshot);
            outputs.prepare(snapshot.streamMuted(), snapshot.earpiece(), snapshot.speaker());
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
        store.clear(); // A failed clear must not lose the recoverable original snapshot.
        started = false;
        restoring = false;
        return "local_audio_isolation_restored verified=true";
    }
}
