package com.airsim.phonecontrol;

/** First successful privileged catch-up suppresses old rows without blocking cursor progress. */
final class SMSInboxCatchUp {
    private final boolean completed;
    private final long cutoff;
    SMSInboxCatchUp(boolean completed, long savedCutoff, long now) {
        this.completed = completed;
        cutoff = savedCutoff > 0 ? savedCutoff : now - 15L * 60L * 1000L;
    }
    long cutoff() { return cutoff; }
    boolean completed() { return completed; }
    boolean shouldForward(long receivedAt, long sentAt) {
        long timestamp = receivedAt > 0 ? receivedAt : sentAt;
        return completed || timestamp > 0 && timestamp >= cutoff;
    }
    boolean drained(int rows, int limit) { return rows < limit; }
}
