package com.airsim.phonecontrol;

import java.nio.file.*;

public final class IsolationRecoveryJournalTests {
    private static int checks;
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("airsim-isolation-test-");
        Path file = directory.resolve("recovery.state");
        try {
            var journal = new IsolationRecoveryJournal(file, "boot-one");
            check(journal.read() == null, "no experiment means no persisted state");
            var original = new LocalAudioIsolationController.Snapshot(false, false, 6, 9);
            journal.save(original);
            check(original.equals(journal.read()), "round trip original flags and separate indices");
            Platform audio = new Platform();
            var first = new LocalAudioIsolationController(audio, journal);
            first.setIsolated(true);
            check(audio.mic && audio.ear == 0 && audio.speaker == 0, "isolate after recovering prior snapshot");
            var restarted = new LocalAudioIsolationController(audio, new IsolationRecoveryJournal(file, "boot-one"));
            check(restarted.restoring(), "new service detects interrupted isolation");
            restarted.setIsolated(false);
            check(!audio.mic && audio.ear == 6 && audio.speaker == 9 && journal.read() == null,
                    "restart recovers original state, not the muted state seen at startup");
            journal.save(new LocalAudioIsolationController.Snapshot(true, true, 3, 4));
            audio.mic = true;
            new LocalAudioIsolationController(audio, journal).setIsolated(false);
            check(audio.mic && audio.ear == 3 && audio.speaker == 4, "never unmute an originally muted microphone");
            journal.save(original);
            check(new IsolationRecoveryJournal(file, "boot-two").read() == null && !Files.exists(file),
                    "do not replay a previous boot's snapshot");
            Files.write(file, new byte[]{1, 2, 3});
            try { journal.read(); throw new AssertionError("corrupt journal accepted"); }
            catch (java.io.IOException expected) { checks++; }
            Files.delete(file);
            Files.createSymbolicLink(file, directory.resolve("other"));
            try { journal.read(); throw new AssertionError("symlink accepted"); }
            catch (java.io.IOException expected) { checks++; }
            Files.delete(file);
            Platform denied = new Platform();
            var noStorage = new LocalAudioIsolationController(denied, new LocalAudioIsolationController.Store() {
                public LocalAudioIsolationController.Snapshot read() { return null; }
                public void save(LocalAudioIsolationController.Snapshot s) throws Exception { throw new java.io.IOException("disk denied"); }
                public void clear() { }
            });
            try { noStorage.setIsolated(true); throw new AssertionError("missing recovery storage accepted"); }
            catch (java.io.IOException expected) { }
            check(denied.writes == 0, "journal failure prevents every system audio mutation");
            var lease = new IsolationLease();
            check(lease.expired(10), "no owner has no lease");
            lease.renew(10);
            check(!lease.expired(10 + IsolationLease.DURATION_MILLIS - 1), "lease valid until deadline");
            check(lease.expired(10 + IsolationLease.DURATION_MILLIS), "owner loss expires lease");
            lease.renew(20); lease.revoke(); check(lease.expired(20), "hangup revokes lease immediately");
            for (String model : new String[]{"RMX3888", "Pixel 6", "SM-F766U", "M2004J19C"}) {
                String maker = model.equals("Pixel 6") ? "google" : model.equals("RMX3888") ? "realme" : "other";
                check(LocalOutputMuteController.configuredStrategy("auto", maker, model)
                        != LocalOutputMuteController.Strategy.ISOLATE_LOCAL, "auto stays unchanged on " + model);
                check(LocalOutputMuteController.configuredStrategy("isolate", maker, model)
                        == LocalOutputMuteController.Strategy.ISOLATE_LOCAL, "only explicit selection enables isolation");
            }
            System.out.println("IsolationRecoveryJournalTests passed: " + checks + " checks");
        } finally {
            Files.deleteIfExists(file); Files.deleteIfExists(directory);
        }
    }
    private static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); checks++; }
    private static final class Platform implements LocalAudioIsolationController.Api {
        boolean mic; int ear = 6, speaker = 9, writes;
        public boolean microphoneMuted() { return mic; }
        public void microphoneMuted(boolean value) { mic = value; writes++; }
        public boolean streamMuted() { return false; }
        public int index(int device) { return device == 1 ? ear : speaker; }
        public void set(int device, int index, boolean muted) { if (device == 1) ear = index; else speaker = index; writes++; }
    }
}
