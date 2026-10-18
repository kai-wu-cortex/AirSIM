package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Timeout releases policy locks, not a promise to cancel an already running system Binder call. */
final class BoundedAudioOperation implements AutoCloseable {
    private final AtomicBoolean busy = new AtomicBoolean();
    private final ExecutorService worker = Executors.newSingleThreadExecutor(task -> {
        Thread thread = new Thread(task, "AirSIM-OEM-audio"); thread.setDaemon(true); return thread;
    });
    private final long timeoutMillis;
    BoundedAudioOperation(long timeoutMillis) { this.timeoutMillis = timeoutMillis; }
    <T> T run(Callable<T> action) throws Exception {
        if (!busy.compareAndSet(false, true)) throw new IOException("OEM audio operation still pending");
        Future<T> result;
        try {
            result = worker.submit(() -> { try { return action.call(); } finally { busy.set(false); } });
        } catch (RuntimeException error) { busy.set(false); throw error; }
        try { return result.get(timeoutMillis, TimeUnit.MILLISECONDS); }
        catch (java.util.concurrent.ExecutionException error) {
            if (error.getCause() instanceof Exception cause) throw cause;
            throw error;
        }
    }
    @Override public void close() { worker.shutdownNow(); }
}
