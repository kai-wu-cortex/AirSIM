package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;

public final class RelayEgressGateTests {
    public static void main(String[] args) throws Exception {
        RelayEgressGate gate = new RelayEgressGate(true);
        AtomicInteger sends = new AtomicInteger(), cancels = new AtomicInteger();
        try { try (var lease = gate.acquire(() -> {})) { sends.incrementAndGet(); } throw new AssertionError(); }
        catch (IOException expected) {}
        assert sends.get() == 0;
        gate.enableAfterRestore();
        var generation = gate.generation();
        var old = gate.acquire(cancels::incrementAndGet);
        assert old.isCurrent();
        assert !gate.disableAndDrain(100) : "cancel requested is not completion";
        assert cancels.get() == 1 && !old.isCurrent();
        try { gate.enableAfterRestore(); throw new AssertionError("undrained restore"); }
        catch (IllegalStateException expected) {}
        try { gate.acquire(() -> {}); throw new AssertionError(); } catch (IOException expected) {}
        old.close();
        assert gate.disableAndDrain(1000);
        gate.enableAfterRestore();
        assert !generation.isCurrent() : "queued work from before pure-local entry revived after exit";
        try { gate.acquire(generation, () -> {}); throw new AssertionError("stale request admitted after exit"); }
        catch (IOException expected) {}
        assert !old.isCurrent() : "old response cannot revive on exit";
        try (var fresh = gate.acquire(() -> {})) { assert fresh.isCurrent(); sends.incrementAndGet(); }
        assert sends.get() == 1;
        // Cancellation is invoked outside the monitor: release from another
        // thread must not deadlock against the caller waiting for drain.
        final RelayEgressGate.Lease[] active = new RelayEgressGate.Lease[1];
        active[0] = gate.acquire(() -> {
            Thread release = new Thread(() -> active[0].close());
            release.start();
            try { release.join(1000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            if (release.isAlive()) throw new IOException("gate monitor held across cancellation");
        });
        assert gate.disableAndDrain(1000);
        gate.enableAfterRestore();
        var slow = gate.acquire(() -> {
            try { Thread.sleep(300); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        });
        long started = System.nanoTime();
        assert !gate.disableAndDrain(10);
        assert java.util.concurrent.TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 200
                : "a blocking disconnect defeated the drain deadline";
        slow.close();
        assert gate.disableAndDrain(1000);
        System.out.println("RelayEgressGateTests passed");
    }
}
