package com.airsim.phonecontrol;

import java.io.IOException;

public final class LocalAudioIsolationControllerTests {
    public static void main(String[] args) throws Exception {
        for (boolean initialMic : new boolean[]{false, true}) {
            Platform p = new Platform(); p.mic = initialMic;
            LocalAudioIsolationController c = new LocalAudioIsolationController(p);
            c.setIsolated(true);
            check(c.verified() && p.mic && p.ear == 0 && p.speaker == 0, "isolate all physical endpoints");
            p.ear = 4; p.mic = false; c.setIsolated(true);
            check(p.mic && p.ear == 0, "repair route and mic drift");
            c.setIsolated(false);
            check(p.mic == initialMic && p.ear == 6 && p.speaker == 9, "restore exact original endpoints");
            int calls = p.writes; c.setIsolated(false);
            check(p.writes == calls && !c.verified(), "idle restore is inert");
        }
        Platform ignored = new Platform(); ignored.ignoreMic = true;
        LocalAudioIsolationController reject = new LocalAudioIsolationController(ignored);
        fails(() -> reject.setIsolated(true));
        check(!reject.verified() && ignored.ear == 6 && ignored.speaker == 9, "ignored mic mute rolls back outputs");
        Platform partial = new Platform(); partial.failSpeakerMute = true;
        LocalAudioIsolationController rollback = new LocalAudioIsolationController(partial);
        fails(() -> rollback.setIsolated(true));
        check(!partial.mic && partial.ear == 6 && partial.speaker == 9, "partial sink failure restores microphone and first sink");
        for (boolean failMic : new boolean[]{false, true}) {
            Platform p = new Platform(); LocalAudioIsolationController c = new LocalAudioIsolationController(p);
            c.setIsolated(true); p.failMicRestore = failMic; p.failEarRestore = !failMic;
            fails(() -> c.setIsolated(false));
            check(!c.verified(), "partial restore cannot report isolation success");
            check(failMic ? p.ear == 6 && p.speaker == 9 : !p.mic && p.speaker == 9,
                    "failure of one endpoint does not skip restoration of the others");
            p.failMicRestore = p.failEarRestore = false; c.setIsolated(false);
            check(!p.mic && p.ear == 6 && p.speaker == 9, "retry retains original state");
            c.setIsolated(true); c.setIsolated(false);
            check(!p.mic && p.ear == 6 && p.speaker == 9, "next call has a fresh snapshot");
        }
        String base = "muted=false volume=9 mode=2 speaker=false pcm=true output_policy=isolate_local";
        check(AudioWatchdogSnapshot.parse(base + " mic_muted=true earpiece_index=0 speaker_index=0").targetSatisfied(),
                "physical isolation keeps framework stream and PCM volume intact");
        check(!AudioWatchdogSnapshot.parse(base + " mic_muted=false earpiece_index=0 speaker_index=0").targetSatisfied(), "mic drift detected");
        check(!AudioWatchdogSnapshot.parse(base + " mic_muted=true earpiece_index=1 speaker_index=0").targetSatisfied(), "earpiece drift detected");
        check(!AudioWatchdogSnapshot.parse(base + " mic_muted=true earpiece_index=0 speaker_index=9").targetSatisfied(), "speaker drift detected");
        fails(() -> AudioWatchdogSnapshot.parse(base));
        check(LocalOutputMuteController.configuredStrategy("auto", "realme", "RMX3888")
                == LocalOutputMuteController.Strategy.ISOLATE_LOCAL, "verified model selects isolation");
        check(LocalOutputMuteController.configuredStrategy("auto", "realme", "different")
                == LocalOutputMuteController.Strategy.MINIMUM_NONZERO_VOLUME, "do not infer support across a vendor");
        check(LocalOutputMuteController.configuredStrategy("preserve", "realme", "RMX3888")
                == LocalOutputMuteController.Strategy.PRESERVE_VOLUME, "explicit volume preference wins");
        System.out.println("LocalAudioIsolationControllerTests passed");
    }
    interface Action { Object run() throws Exception; }
    private static void fails(Action a) throws Exception {
        try { a.run(); throw new AssertionError("expected rejection"); } catch (IOException expected) { }
    }
    private static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); }
    private static final class Platform implements LocalAudioIsolationController.Api {
        boolean mic, ignoreMic, failSpeakerMute, failEarRestore, failMicRestore;
        int ear = 6, speaker = 9, writes;
        public boolean microphoneMuted() { return mic; }
        public void microphoneMuted(boolean value) throws IOException {
            writes++;
            if (!value && failMicRestore) throw new IOException("restore denied");
            if (!ignoreMic) mic = value;
        }
        public boolean streamMuted() { return false; }
        public int index(int device) { return device == 1 ? ear : speaker; }
        public void set(int device, int index, boolean muted) throws IOException {
            check(device == 1 || device == 2, "never target telephony TX or another device");
            writes++;
            if (device == 2 && muted && failSpeakerMute || device == 1 && !muted && failEarRestore)
                throw new IOException("output denied");
            if (device == 1) ear = index; else speaker = index;
        }
    }
}
