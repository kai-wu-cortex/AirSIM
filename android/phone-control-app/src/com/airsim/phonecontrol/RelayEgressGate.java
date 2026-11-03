package com.airsim.phonecontrol;

import java.io.Closeable;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.TimeUnit;

/** Process-wide fail-closed admission and lifetime tracking for Relay I/O. */
public final class RelayEgressGate {
    public static final RelayEgressGate shared = new RelayEgressGate(true);
    private static final java.util.concurrent.ExecutorService CANCELLATIONS =
            java.util.concurrent.Executors.newFixedThreadPool(2, runnable -> {
                Thread thread = new Thread(runnable, "AirSIMRelayCancel");
                thread.setDaemon(true);
                return thread;
            });
    private final Set<Lease> active = new HashSet<>();
    private boolean blocked;
    private long epoch;
    private int pendingCancellations;

    public RelayEgressGate(boolean blocked) { this.blocked = blocked; }
    public synchronized boolean isBlocked() { return blocked; }
    public synchronized Generation generation() { return new Generation(epoch, !blocked); }
    /** A queued callback may outlive its socket; it must still belong to this allowed generation. */
    public final class Generation {
        private final RelayEgressGate owner = RelayEgressGate.this;
        private final long value;
        private final boolean admitted;
        private Generation(long value, boolean admitted) { this.value = value; this.admitted = admitted; }
        public boolean isCurrent() {
            synchronized (RelayEgressGate.this) { return admitted && !blocked && value == epoch; }
        }
    }
    public synchronized Lease acquire(Closeable cancellation) throws IOException {
        if (blocked) throw new IOException("pure_local_relay_disabled");
        if (cancellation == null) throw new IllegalArgumentException("cancellation required");
        Lease lease = new Lease(epoch, cancellation);
        active.add(lease);
        return lease;
    }
    public synchronized Lease acquire(Generation generation, Closeable cancellation) throws IOException {
        if (generation == null || generation.owner != this || !generation.isCurrent()) {
            throw new IOException("stale_relay_operation");
        }
        return acquire(cancellation);
    }

    public boolean disableAndDrain(long timeoutMillis) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(Math.max(0, timeoutMillis));
        ArrayList<Lease> cancelling;
        synchronized (this) {
            if (!blocked) { blocked = true; epoch++; }
            cancelling = new ArrayList<>(active);
        }
        for (Lease lease : cancelling) lease.cancelOnce();
        synchronized (this) {
            while (!active.isEmpty() || pendingCancellations != 0) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) return false;
                TimeUnit.NANOSECONDS.timedWait(this, remaining);
            }
            return true;
        }
    }

    public synchronized void enableAfterRestore() {
        if (!active.isEmpty() || pendingCancellations != 0) throw new IllegalStateException("relay_still_draining");
        if (blocked) { epoch++; blocked = false; }
    }

    public final class Lease implements Closeable {
        private final long generation;
        private final Closeable cancellation;
        private boolean closed, cancelled;
        private Lease(long generation, Closeable cancellation) { this.generation = generation; this.cancellation = cancellation; }
        public boolean isCurrent() {
            synchronized (RelayEgressGate.this) { return !closed && !blocked && generation == epoch; }
        }
        public void checkCurrent() throws IOException { if (!isCurrent()) throw new IOException("stale_relay_operation"); }
        private void cancelOnce() {
            synchronized (RelayEgressGate.this) {
                if (cancelled || closed) return;
                cancelled = true;
                pendingCancellations++;
            }
            CANCELLATIONS.execute(() -> {
                try { cancellation.close(); }
                catch (Exception ignored) { /* Still wait for actual operation completion. */ }
                finally {
                    synchronized (RelayEgressGate.this) {
                        pendingCancellations--;
                        RelayEgressGate.this.notifyAll();
                    }
                }
            });
        }
        @Override public void close() {
            synchronized (RelayEgressGate.this) {
                closed = true;
                active.remove(this);
                RelayEgressGate.this.notifyAll();
            }
        }
    }
}
