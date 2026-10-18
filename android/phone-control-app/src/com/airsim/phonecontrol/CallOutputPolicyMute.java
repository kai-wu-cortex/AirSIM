package com.airsim.phonecontrol;

import java.io.IOException;

/** Built-in cellular downlink policy only; never controls PCM track gain or microphone mute. */
final class CallOutputPolicyMute {
    interface Api {
        int index(int device) throws Exception;
        void set(int device, int index, boolean muted) throws Exception;
    }
    private static final int[] DEVICES = {1, 2}; // AudioSystem OUT_EARPIECE, OUT_SPEAKER
    private final Api api;
    private int[] previous;
    private boolean previousMuted;
    private volatile boolean applied;

    CallOutputPolicyMute(Api api) { this.api = api; }
    static CallOutputPolicyMute prepareWithin(BoundedAudioOperation operations, Api api, boolean muted)
            throws Exception {
        // A timed-out read may finish, but its private candidate can never become a live owner.
        return operations.run(() -> {
            CallOutputPolicyMute candidate = new CallOutputPolicyMute(api);
            candidate.prepare(muted);
            return candidate;
        });
    }
    void prepare(boolean muted) throws Exception {
        if (previous != null) return;
        int[] snapshot = new int[DEVICES.length];
        for (int i = 0; i < DEVICES.length; i++) {
            snapshot[i] = api.index(DEVICES[i]);
            if (snapshot[i] < 0 || snapshot[i] > 1000) throw new IOException("invalid call policy index");
        }
        previous = snapshot;
        previousMuted = muted;
    }
    void apply() throws Exception {
        applied = false;
        if (previous == null) throw new IOException("call policy snapshot missing");
        for (int device : DEVICES) api.set(device, 0, true);
        for (int device : DEVICES) {
            if (api.index(device) != 0) throw new IOException("call policy mute readback failed");
        }
        // This is API/readback evidence, never a claim of physical silence.
        applied = true;
    }
    void restore() throws Exception {
        applied = false;
        if (previous == null) return;
        Exception failure = null;
        for (int i = 0; i < DEVICES.length; i++) {
            try {
                api.set(DEVICES[i], previous[i], previousMuted);
                if (api.index(DEVICES[i]) != previous[i]) throw new IOException("call policy restore readback failed");
            } catch (Exception error) {
                if (failure == null) failure = error;
                else failure.addSuppressed(error);
            }
        }
        if (failure != null) throw failure; // retain snapshot for restoration retry
        previous = null;
    }
    boolean applied() { return applied; }
}
