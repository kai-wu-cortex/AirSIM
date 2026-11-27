package com.airsim.phonecontrol;

import java.lang.reflect.InvocationTargetException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/** Real service lifecycle and bounded OEM executor; no phones, calls, or audio. */
public final class IsolationRecoveryServiceTests {
    private static int checks;
    public static void main(String[] args) throws Exception {
        shutdownRetriesAfterTransientFailure();
        lateWriteIsRestoredBeforeExit();
        ownerLeaseAndLateHeartbeat();
        restartUsesOriginalSnapshot();
        coordinatorOnlyRenewsOwnedExperiment();
        System.out.println("IsolationRecoveryServiceTests passed: " + checks + " checks");
    }

    private static void shutdownRetriesAfterTransientFailure() throws Exception {
        Fixture f = new Fixture();
        f.apply(true); f.audio.rejectUnmute = true;
        f.service.shutdown();
        check(f.audio.microphone && f.store.read() != null, "failed shutdown retains state and journal");
        check(f.done().getCount() == 1, "failed restoration cannot authorize process exit");
        int attempts = f.audio.unmuteAttempts;
        f.tick();
        check(f.audio.unmuteAttempts == attempts, "restoration backs off instead of hammering OEM service");
        try { f.apply(true); throw new AssertionError("re-isolation during shutdown accepted"); }
        catch (java.io.IOException expected) { checks++; }
        f.audio.rejectUnmute = false;
        f.retryTick();
        check(!f.audio.microphone && f.store.read() == null, "cleanup retries after transient fault clears");
        check(f.done().getCount() == 0, "executor closes only after successful restoration");
        f.service.shutdown(); // Idempotent after verified cleanup.
    }

    private static void lateWriteIsRestoredBeforeExit() throws Exception {
        Fixture f = new Fixture();
        f.audio.blockMute = true;
        try { f.apply(true); throw new AssertionError("blocked OEM write should time out"); }
        catch (TimeoutException expected) { checks++; }
        f.service.shutdown();
        check(f.done().getCount() == 1, "do not close the worker with an in-flight mute");
        f.audio.release.countDown();
        check(f.audio.muteFinished.await(2, TimeUnit.SECONDS), "late OEM write finished");
        long limit = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (f.done().getCount() != 0 && System.nanoTime() < limit) { f.retryTick(); Thread.sleep(10); }
        check(f.done().getCount() == 0 && !f.audio.microphone && f.store.read() == null,
                "late mute is undone before cleanup is considered complete");
    }

    private static void ownerLeaseAndLateHeartbeat() throws Exception {
        Fixture f = new Fixture(); f.apply(true);
        f.now.addAndGet(IsolationLease.DURATION_MILLIS - 1);
        invoke(f.service, "renewIsolationLease"); f.tick();
        check(f.audio.microphone, "current authenticated owner keeps isolation active");
        f.now.addAndGet(IsolationLease.DURATION_MILLIS);
        // Diagnostic queries cannot keep an orphaned daemon muted.
        invoke(f.service, "audioSnapshot");
        invoke(f.service, "renewIsolationLease"); // Too late; must not resurrect an expired lease.
        f.tick();
        check(!f.audio.microphone && f.store.read() == null, "App loss restores without App onDestroy");
        invoke(f.service, "renewIsolationLease"); f.tick();
        check(!f.audio.microphone, "late heartbeat cannot recreate an isolation session");
        f.service.shutdown();
    }

    private static void restartUsesOriginalSnapshot() throws Exception {
        var store = new LocalAudioIsolationController.MemoryStore();
        Fixture before = new Fixture(store); before.apply(true);
        // Simulate process loss, so shutdown/onDestroy cannot restore anything.
        ((BoundedAudioOperation) field(before.service, "audioOperations")).close();
        ((ScheduledExecutorService) field(before.service, "audioRecovery")).shutdownNow();
        ((android.net.LocalServerSocket) field(before.service, "bridgeOwnership")).close();
        Fixture after = new Fixture(store, before.audio);
        invoke(after.service, "recoverInterruptedIsolation");
        check(!after.audio.microphone && android.media.AudioSystem.earpiece == 7
                && android.media.AudioSystem.speaker == 9 && store.read() == null,
                "new service restores the saved originals before allowing bridge startup");
        after.service.shutdown();
    }

    private static void coordinatorOnlyRenewsOwnedExperiment() throws Exception {
        int[] renewals = {0};
        var coordinator = new PrivilegedBridgeCoordinator();
        coordinator.connect(new PrivilegedBridgeCoordinator.Transport() {
            public String startBridge() { return "pcm=running"; }
            public String status() { return "pcm=running"; }
            public String setLocalOutputMuted(boolean muted) { return "ok"; }
            public String setLocalOutputMuted(boolean muted, String route, String policy) { return "ok"; }
            public void renewIsolationLease() { renewals[0]++; }
            public String audioSnapshot() { return "muted=false volume=5 mode=2 speaker=false pcm=true output_policy=preserve_volume"; }
        });
        coordinator.setLocalOutputMuted(true); coordinator.audioSnapshot();
        check(renewals[0] == 0, "default calls never use the experimental IPC");
        coordinator.setOutputPolicy("isolate_local"); coordinator.audioSnapshot();
        check(renewals[0] == 1, "active experimental owner renews");
        coordinator.setLocalOutputMuted(false); coordinator.audioSnapshot();
        check(renewals[0] == 1, "hangup immediately stops client renewals");
    }

    private static final class Fixture {
        final ShizukuBridgeUserService service = new ShizukuBridgeUserService();
        final AtomicLong now = new AtomicLong(100);
        final LocalAudioIsolationController.MemoryStore store;
        final FlakyAudio audio;
        Fixture() throws Exception { this(new LocalAudioIsolationController.MemoryStore()); }
        Fixture(LocalAudioIsolationController.MemoryStore store) throws Exception { this(store, new FlakyAudio()); }
        Fixture(LocalAudioIsolationController.MemoryStore store, FlakyAudio audio) throws Exception {
            this.store = store; this.audio = audio;
            android.os.Process.uid = 2000;
            android.content.Context.audio = audio;
            if (store.read() == null) { android.media.AudioSystem.earpiece = 7; android.media.AudioSystem.speaker = 9; }
            set(service, "serviceContext", new android.content.Context("fixture"));
            set(service, "bridgeOwnership", new android.net.LocalServerSocket("isolation-fixture"));
            set(service, "isolationStore", store);
            set(service, "isolationClock", (java.util.function.LongSupplier) now::get);
        }
        void apply(boolean active) throws Exception {
            var method = ShizukuBridgeUserService.class.getDeclaredMethod("setLocalOutputMuted", boolean.class, String.class, String.class);
            method.setAccessible(true);
            try { method.invoke(service, active, "vowlan", "isolate_local"); }
            catch (InvocationTargetException e) { throw (Exception) e.getCause(); }
        }
        void tick() throws Exception { invoke(service, "recoverAudioTick"); }
        void retryTick() throws Exception { now.addAndGet(10_000); tick(); }
        CountDownLatch done() throws Exception { return (CountDownLatch) field(service, "shutdownComplete"); }
    }
    private static final class FlakyAudio extends android.media.AudioManager {
        volatile boolean rejectUnmute, blockMute;
        volatile int unmuteAttempts;
        final CountDownLatch release = new CountDownLatch(1), muteFinished = new CountDownLatch(1);
        @Override public void setMicrophoneMute(boolean value) {
            if (!value) unmuteAttempts++;
            if (!value && rejectUnmute) throw new IllegalStateException("transient OEM unmute failure");
            if (value && blockMute) {
                for (;;) { try { release.await(); break; } catch (InterruptedException ignored) { } }
            }
            super.setMicrophoneMute(value);
            if (value) muteFinished.countDown();
        }
    }
    private static Object field(Object object, String name) throws Exception {
        var f = object.getClass().getDeclaredField(name); f.setAccessible(true); return f.get(object);
    }
    private static void set(Object object, String name, Object value) throws Exception {
        var f = object.getClass().getDeclaredField(name); f.setAccessible(true); f.set(object, value);
    }
    private static Object invoke(Object object, String name) throws Exception {
        var m = object.getClass().getDeclaredMethod(name); m.setAccessible(true);
        try { return m.invoke(object); } catch (InvocationTargetException e) { throw (Exception) e.getCause(); }
    }
    private static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); checks++; }
}
