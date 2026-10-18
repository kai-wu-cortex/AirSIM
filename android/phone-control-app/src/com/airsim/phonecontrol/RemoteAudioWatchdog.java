package com.airsim.phonecontrol;

import java.util.function.BooleanSupplier;
import java.util.function.Consumer;

/** One remote-session generation; called on the privileged-command serial executor, never PCM/UI. */
final class RemoteAudioWatchdog {
    interface Backend {
        AudioWatchdogSnapshot probe() throws Exception;
        void repair(int step) throws Exception;
        void reconnect() throws Exception;
    }
    private final Backend backend;
    private final Consumer<String> logger;
    private int anomalies, attempts;
    private long lastAttempt;
    private boolean attempted, exhaustedLogged;

    RemoteAudioWatchdog(Backend backend, Consumer<String> logger) {
        this.backend = backend; this.logger = logger;
    }

    void tick(long now, BooleanSupplier eligible) {
        if (!eligible.getAsBoolean()) return;
        AudioWatchdogSnapshot before;
        long start = System.nanoTime();
        try {
            before = backend.probe();
            if (!eligible.getAsBoolean()) return;
            log("sample " + before.diagnostic());
        } catch (Exception error) {
            if (!eligible.getAsBoolean()) return;
            log("state=unknown operation=probe error=" + error.getClass().getSimpleName());
            if (mayAttempt(now) && eligible.getAsBoolean()) {
                countAttempt(now);
                try {
                    backend.reconnect();
                    log("action=reconnect_requested attempt=" + attempts + " verified_muted=unknown");
                } catch (Exception failure) {
                    log("action=reconnect_failed error=" + failure.getClass().getSimpleName());
                }
            }
            return;
        }
        if (before.targetSatisfied()) { anomalies = 0; return; }
        if (!before.pcm()) {
            anomalies = 0;
            log("state=unverified reason=pcm_not_running repair=skipped");
            return;
        }
        if (++anomalies < 2 || !mayAttempt(now) || !eligible.getAsBoolean()) return;
        countAttempt(now);
        try {
            log("action=repair_begin step=" + attempts);
            backend.repair(attempts);
            if (!eligible.getAsBoolean()) { log("action=repair_obsolete"); return; }
            AudioWatchdogSnapshot after = backend.probe();
            if (!eligible.getAsBoolean()) return;
            log("action=recheck step=" + attempts + " verified_muted=" + after.muted()
                    + " verified_minimum=" + (after.minimumVolumePolicy() && after.targetSatisfied())
                    + " elapsed_ms=" + (System.nanoTime() - start) / 1_000_000 + " " + after.diagnostic());
            anomalies = after.targetSatisfied() ? 0 : 2;
        } catch (Exception error) {
            log("action=repair_failed step=" + attempts + " verified_muted=unknown error="
                    + error.getClass().getSimpleName());
        }
    }
    private boolean mayAttempt(long now) {
        if (attempts >= 3) {
            if (!exhaustedLogged) { log("state=unresolved reason=budget_exhausted repair=stopped"); exhaustedLogged = true; }
            return false;
        }
        return !attempted || now - lastAttempt >= 15_000;
    }
    private void countAttempt(long now) { attempts++; lastAttempt = now; attempted = true; }
    private void log(String value) { logger.accept("audio_watchdog " + value); }
}
