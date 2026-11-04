package com.airsim.phonecontrol;

/** Expiring local evidence, scoped to a privileged-service connection. */
final class AudioHealthReportCache {
    private record Snapshot(String report, long generation, long at) {}
    private volatile Snapshot snapshot;

    void update(String report, long generation, long now) {
        snapshot = new Snapshot(report, generation, now);
    }
    void clear() { snapshot = null; }
    String current(long generation, long now) {
        Snapshot value = snapshot;
        return value != null && value.generation == generation && now >= value.at
                && now - value.at <= 5_000 ? value.report : "";
    }
}
