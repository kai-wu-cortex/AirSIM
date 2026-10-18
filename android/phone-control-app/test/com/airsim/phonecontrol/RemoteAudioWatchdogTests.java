package com.airsim.phonecontrol;

import java.util.ArrayList;
import java.util.List;

public final class RemoteAudioWatchdogTests {
    public static void main(String[] args) throws Exception {
        minimumVolumeTargetIsNotMistakenForUnmutedDrift();
        RemoteCallAudioScope scope = new RemoteCallAudioScope();
        Object owner = new Object();
        check(!scope.owns(java.util.List.of("call-a")), "PCM alone is not proof of native call ownership");
        scope.bind(owner, "call-a");
        check(scope.owns(java.util.List.of("call-a")), "confirmed remote control binds this native call");
        check(!scope.owns(java.util.List.of("call-a", "call-b")), "multiple calls are ambiguous");
        check(!scope.owns(java.util.List.of("call-b")), "stale PCM may never claim the next ordinary call");
        Object replacement = new Object();
        scope.bind(replacement, "call-b");
        scope.release(owner);
        check(scope.owns(java.util.List.of("call-b")), "old cleanup cannot remove replacement call ownership");
        scope.release(replacement);
        check(!scope.owns(java.util.List.of("call-b")), "closed remote media must not own any call");
        Platform platform = new Platform();
        List<String> log = new ArrayList<>();
        RemoteAudioWatchdog watchdog = new RemoteAudioWatchdog(platform, log::add);
        watchdog.tick(0, () -> false);
        check(platform.reads == 0 && platform.repairs == 0, "ordinary calls must never be touched");
        watchdog.tick(1, () -> true);
        check(platform.repairs == 0, "one unmuted sample must not trigger repair");
        watchdog.tick(2001, () -> true);
        check(platform.repairs == 1 && platform.muted, "repair and re-probe actual mute drift");
        check(log.stream().anyMatch(value -> value.contains("verified_muted=true")), "verified snapshot must be logged");
        platform.muted = false;
        platform.ignoreRepair = true;
        for (long now = 4001; now < 180001; now += 2000) watchdog.tick(now, () -> true);
        check(platform.repairs == 3, "repair budget must not reset after a successful repair or loop forever");
        check(log.stream().anyMatch(value -> value.contains("budget_exhausted")), "persistent failure must be visible");
        platform.muted = false;
        Platform cancelled = new Platform();
        RemoteAudioWatchdog stale = new RemoteAudioWatchdog(cancelled, log::add);
        stale.tick(0, () -> true);
        stale.tick(2000, () -> cancelled.reads < 2);
        check(cancelled.repairs == 0, "ending a call during probe must cancel repair");
        Platform unavailable = new Platform();
        unavailable.unavailable = true;
        RemoteAudioWatchdog unknown = new RemoteAudioWatchdog(unavailable, log::add);
        unknown.tick(0, () -> true);
        check(unavailable.repairs == 0 && unavailable.reconnects == 1, "unknown state may reconnect but must not claim mute");
        check(log.stream().anyMatch(value -> value.contains("state=unknown")), "probe failures are unknown, never verified");
        Platform noPCM = new Platform(); noPCM.pcm = false;
        RemoteAudioWatchdog noBridge = new RemoteAudioWatchdog(noPCM, log::add);
        noBridge.tick(0, () -> true); noBridge.tick(2000, () -> true);
        check(noPCM.repairs == 0, "missing PCM bridge cannot be repaired by blindly muting");
        for (String invalid : new String[]{"", "muted=false volume=4", "muted=unknown volume=4 mode=2 speaker=false pcm=true"}) {
            try { AudioWatchdogSnapshot.parse(invalid); throw new AssertionError("malformed state accepted"); }
            catch (java.io.IOException expected) { }
        }
        String report = AudioWatchdogReport.compose("0.9.7.1 (84)", 30, "fixture", "test model", String.join("\n", log));
        String media = AudioWatchdogSnapshot.parse("muted=true volume=4 mode=2 speaker=false pcm=true "
                + "pcm_event=pcm_stats pcm_capture=all_zero pcm_route=unverified secret=never-export").diagnostic();
        check(media.contains("pcm_capture=all_zero") && media.contains("pcm_route=unverified")
                && !media.contains("secret") && !media.contains("never-export"),
                "watchdog TXT must retain only whitelisted PCM evidence");
        check(report.contains("VERBOSE") && report.contains("acoustic_check=unavailable")
                && report.contains("budget_exhausted"), "TXT must include evidence and limitations");
        System.out.println("RemoteAudioWatchdogTests passed");
    }
    private static void minimumVolumeTargetIsNotMistakenForUnmutedDrift() throws Exception {
        int[] volume = {1}, repairs = {0};
        List<String> logs = new ArrayList<>();
        RemoteAudioWatchdog monitor = new RemoteAudioWatchdog(new RemoteAudioWatchdog.Backend() {
            public AudioWatchdogSnapshot probe() throws Exception {
                return AudioWatchdogSnapshot.parse("muted=false volume=" + volume[0]
                    + " mode=2 speaker=false pcm=true output_policy=minimum_volume minimum_volume=1");
            }
            public void repair(int step) { repairs[0]++; volume[0] = 1; }
            public void reconnect() { throw new AssertionError("valid minimum snapshot must not rebind"); }
        }, logs::add);
        monitor.tick(0, () -> true); monitor.tick(2000, () -> true);
        check(repairs[0] == 0, "minimum volume is the intended target, not failed mute requiring repair");
        volume[0] = 4;
        monitor.tick(4000, () -> true); monitor.tick(6000, () -> true);
        check(repairs[0] == 1 && volume[0] == 1, "actual volume drift must reapply and verify the minimum");
        check(logs.stream().anyMatch(v -> v.contains("verified_minimum=true") && v.contains("verified_muted=false")),
                "minimum success must not claim physical or framework mute");
        check(logs.stream().anyMatch(v -> v.contains("minimum_volume=1") && v.contains("output_policy=minimum_volume")),
                "TXT needs the intended policy and actual target");
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static final class Platform implements RemoteAudioWatchdog.Backend {
        boolean muted, ignoreRepair, unavailable;
        boolean pcm = true;
        int reads, repairs, reconnects;
        public AudioWatchdogSnapshot probe() throws Exception {
            reads++;
            if (unavailable) throw new java.io.IOException("binder unavailable");
            return AudioWatchdogSnapshot.parse("muted=" + muted + " volume=4 mode=2 speaker=false pcm=" + pcm);
        }
        public void repair(int step) { repairs++; if (!ignoreRepair) muted = true; }
        public void reconnect() { reconnects++; }
    }
}
