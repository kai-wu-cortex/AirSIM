package com.airsim.phonecontrol;

import java.util.function.BooleanSupplier;

/** Process-local request coalescing; Android remains the owner of service instances. */
public final class ServiceStartGate {
    public enum Result { RUNNING, PENDING, REQUESTED, REJECTED }
    private boolean pending;
    private Object owner;

    public synchronized Result request(BooleanSupplier launch) {
        if (owner != null) return Result.RUNNING;
        if (pending) return Result.PENDING;
        pending = true;
        try {
            if (!launch.getAsBoolean()) { pending = false; return Result.REJECTED; }
            return Result.REQUESTED;
        } catch (RuntimeException | Error error) {
            pending = false;
            throw error;
        }
    }
    public synchronized void created(Object service) { owner = service; pending = false; }
    public synchronized void destroyed(Object service) {
        if (owner == service) { owner = null; pending = false; }
    }
}
