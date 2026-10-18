package com.airsim.phonecontrol;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public final class BoundedAudioOperationTests {
    public static void main(String[] args) throws Exception {
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch entered = new CountDownLatch(1);
        try (BoundedAudioOperation operations = new BoundedAudioOperation(30)) {
            long start = System.nanoTime();
            try {
                operations.run(() -> { entered.countDown(); release.await(); return true; });
                throw new AssertionError("stalled OEM call must time out");
            } catch (java.util.concurrent.TimeoutException expected) { }
            if (!entered.await(1, TimeUnit.SECONDS) || System.nanoTime() - start > 1_000_000_000L) {
                throw new AssertionError("operation did not return promptly");
            }
            try { operations.run(() -> true); throw new AssertionError("must not queue behind live stalled operation"); }
            catch (java.io.IOException expected) { }
            release.countDown();
            boolean recovered = false;
            for (int i = 0; i < 100 && !recovered; i++) {
                try { recovered = operations.run(() -> true); }
                catch (java.io.IOException busy) { Thread.sleep(2); }
            }
            if (!recovered) throw new AssertionError("subsequent restore must be able to run after OEM recovery");
        } finally { release.countDown(); }
        delayedMuteDoesNotLoseRestoreSnapshot();
        delayedMinimumWriteRestoresAfterMediaLossAndInvalidatesOldRetry();
        System.out.println("BoundedAudioOperationTests passed");
    }

    private static void delayedMinimumWriteRestoresAfterMediaLossAndInvalidatesOldRetry() throws Exception {
        var volume = new java.util.concurrent.atomic.AtomicInteger(4);
        var muted = new java.util.concurrent.atomic.AtomicBoolean();
        var stall = new java.util.concurrent.atomic.AtomicBoolean();
        var minimumWrites = new java.util.concurrent.atomic.AtomicInteger();
        CountDownLatch release = new CountDownLatch(1);
        try (BoundedAudioOperation operations = new BoundedAudioOperation(30)) {
            LocalOutputMuteController controller = new LocalOutputMuteController(new LocalOutputMuteController.Backend() {
                public boolean isMuted() throws Exception { return operations.run(muted::get); }
                public int volume() throws Exception { return operations.run(volume::get); }
                public int minimumVolume() throws Exception { return operations.run(() -> 1); }
                public void setMuted(boolean value) throws Exception {
                    operations.run(() -> { muted.set(value); return null; });
                }
                public void setVolume(int value) throws Exception {
                    operations.run(() -> {
                        if (stall.getAndSet(false)) release.await();
                        volume.set(value);
                        if (value == 1) minimumWrites.incrementAndGet();
                        return null;
                    });
                }
            }, LocalOutputMuteController.Strategy.MINIMUM_VOLUME);
            PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
            coordinator.connect(new PrivilegedBridgeCoordinator.Transport() {
                public String startBridge() { return "uid=2000 pcm=running"; }
                public String status() { return "uid=2000 pcm=running"; }
                public String setLocalOutputMuted(boolean value) throws Exception { return controller.setMuted(value); }
            });
            java.util.ArrayDeque<Runnable> ready = new java.util.ArrayDeque<>();
            java.util.ArrayDeque<Runnable> retries = new java.util.ArrayDeque<>();
            var restored = new java.util.concurrent.atomic.AtomicBoolean();
            MuteRequestRetrier retrier = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
                public void execute(Runnable task) { ready.add(task); }
                public void schedule(Runnable task, long delay) { retries.add(task); }
            }, coordinator::setLocalOutputMuted, (target, error) -> {
                if (!target && error == null) restored.set(true);
            });
            retrier.request(true); ready.remove().run();
            if (volume.get() != 1) throw new AssertionError("initial minimum was not applied");
            volume.set(4); stall.set(true);
            retrier.request(true); ready.remove().run(); // timed-out repair; OEM write still in flight
            retrier.request(false); ready.remove().run(); // media loss queues restoration, supersedes old repair
            release.countDown();
            boolean free = false;
            for (int i = 0; i < 100 && !free; i++) {
                try { free = operations.run(() -> true); }
                catch (java.io.IOException busy) { Thread.sleep(2); }
            }
            if (!free) throw new AssertionError("OEM write did not release");
            for (int i = 0; i < 10 && !retries.isEmpty(); i++) retries.remove().run();
            if (!restored.get() || volume.get() != 4 || muted.get() || coordinator.desiredMuted()
                    || controller.isVerifiedMinimum() || minimumWrites.get() != 2)
                throw new AssertionError("media-loss restore must win after late minimum write and obsolete repair retry");
        } finally { release.countDown(); }
    }

    private static void delayedMuteDoesNotLoseRestoreSnapshot() throws Exception {
        java.util.concurrent.atomic.AtomicBoolean muted = new java.util.concurrent.atomic.AtomicBoolean();
        java.util.concurrent.atomic.AtomicBoolean stall = new java.util.concurrent.atomic.AtomicBoolean();
        CountDownLatch release = new CountDownLatch(1);
        try (BoundedAudioOperation operations = new BoundedAudioOperation(30)) {
            LocalOutputMuteController controller = new LocalOutputMuteController(new LocalOutputMuteController.Backend() {
                public boolean isMuted() throws Exception { return operations.run(muted::get); }
                public int volume() throws Exception { return operations.run(() -> 4); }
                public void setVolume(int value) { }
                public void setMuted(boolean value) throws Exception {
                    operations.run(() -> { if (stall.getAndSet(false)) release.await(); muted.set(value); return null; });
                }
            });
            controller.setMuted(true);
            muted.set(false); stall.set(true);
            try { controller.setMuted(true); throw new AssertionError("repair should time out"); }
            catch (java.util.concurrent.TimeoutException expected) { }
            release.countDown();
            boolean restored = false;
            for (int i = 0; i < 100 && !restored; i++) {
                try { controller.setMuted(false); restored = true; }
                catch (java.io.IOException busy) { Thread.sleep(2); }
            }
            if (!restored || muted.get()) throw new AssertionError("original unmuted state must survive timed-out late repair");
        } finally { release.countDown(); }
    }
}
