package com.airsim.bridge;

final class BridgeSessionGate {
    private Object owner;

    synchronized boolean tryAcquire(Object candidate) {
        if (candidate == null || owner != null) {
            return false;
        }
        owner = candidate;
        return true;
    }

    synchronized void release(Object candidate) {
        if (owner == candidate) {
            owner = null;
        }
    }
}
