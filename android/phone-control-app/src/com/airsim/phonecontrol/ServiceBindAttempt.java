package com.airsim.phonecontrol;

/** A missing framework callback must not leave binding stuck or cause retry storms. */
final class ServiceBindAttempt {
    private long sequence, started;
    private boolean pending, failed;
    synchronized long begin(long now) {
        if (pending || failed) return -1;
        pending = true; started = now; return ++sequence;
    }
    synchronized boolean connected(long id) {
        if (!pending || id != sequence) return false;
        pending = false; return true;
    }
    synchronized boolean expire(long id, long now) {
        if (!pending || id != sequence || now - started < 35_000) return false;
        pending = false; failed = true; return true;
    }
    synchronized void cancel() { sequence++; pending = false; failed = false; }
    synchronized boolean timedOut() { return failed; }
}
