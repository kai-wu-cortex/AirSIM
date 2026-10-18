package com.airsim.phonecontrol;

/** Keeps late NSD callbacks from reviving a retired network registration. */
final class VoWLANAdvertisementEpoch {
    private long generation;
    private boolean ready;

    synchronized long begin() {
        ready = false;
        return ++generation;
    }

    synchronized void invalidate() {
        generation++;
        ready = false;
    }

    synchronized void completed(long token, boolean success) {
        if (token == generation) ready = success;
    }

    synchronized boolean isReady() { return ready; }
}
