package com.airsim.phonecontrol;

import java.io.IOException;

public final class LocalOutputMuteControllerTests {
    public static void main(String[] args) throws Exception {
        minimumVolumeIsAppliedAndRestored();
        minimumVolumePreservesExistingMuteAndRejectsIgnoredWrites();
        Platform audio = new Platform();
        LocalOutputMuteController controller = new LocalOutputMuteController(audio);
        controller.setMuted(true);
        check(audio.muted && controller.isVerifiedMuted(), "mute must be verified");
        controller.setMuted(true);
        audio.volume = 1; // OEM changed the index during the remote session.
        controller.setMuted(false);
        check(!audio.muted && audio.volume == 4, "restore the original index after repeated mute");
        check(!controller.isVerifiedMuted(), "restored status must not remain muted");

        audio.muted = true;
        int beforeAlreadyMuted = audio.changes;
        controller.setMuted(true);
        check(audio.changes > beforeAlreadyMuted,
                "a new call must reapply output mute even when an old framework flag is true");
        controller.setMuted(false);
        check(audio.muted, "pre-existing user mute must survive the call");

        audio.muted = false;
        audio.supportsMute = false;
        try { controller.setMuted(true); throw new AssertionError("ignored mute must fail visibly"); }
        catch (IOException expected) { /* unsupported OEM implementation */ }
        check(!controller.isVerifiedMuted() && !audio.muted, "no false successful mute");

        audio.supportsMute = true;
        controller.setMuted(true);
        audio.rejectRestore = true;
        try { controller.setMuted(false); throw new AssertionError("failed restoration must surface"); }
        catch (IOException expected) { /* retain the original snapshot for retry */ }
        audio.rejectRestore = false;
        controller.setMuted(false);
        check(!audio.muted && audio.volume == 4, "restore retry must retain original state");

        controller.setMuted(true);
        audio.volume = 1;
        audio.rejectVolume = true;
        try { controller.setMuted(false); throw new AssertionError("partial restore must surface"); }
        catch (IOException expected) { /* unmuted successfully, volume restoration failed */ }
        check(!audio.muted && !controller.isVerifiedMuted(), "partial restore must not claim muted");
        audio.rejectVolume = false;
        controller.setMuted(false);
        check(audio.volume == 4, "partial restoration must remain retryable");
        int changes = audio.changes;
        controller.setMuted(false);
        check(audio.changes == changes, "idle restore must not touch user audio");
        Platform volumeUnmutes = new Platform();
        volumeUnmutes.muted = true;
        volumeUnmutes.unmuteOnVolume = true;
        LocalOutputMuteController preserved = new LocalOutputMuteController(volumeUnmutes);
        preserved.setMuted(true);
        volumeUnmutes.volume = 1;
        preserved.setMuted(false);
        check(volumeUnmutes.muted && volumeUnmutes.volume == 4,
                "restoring volume must not cancel a pre-existing mute");
        System.out.println("LocalOutputMuteControllerTests passed");
    }

    private static void minimumVolumeIsAppliedAndRestored() throws Exception {
        for (int minimum : new int[]{0, 1, 2}) {
            Platform audio = new Platform();
            audio.minimum = minimum;
            LocalOutputMuteController controller = new LocalOutputMuteController(audio,
                    LocalOutputMuteController.Strategy.MINIMUM_VOLUME);
            String result = controller.setMuted(true);
            check(audio.volume == minimum, "remote call must explicitly use the OS minimum, not a mute flag");
            check(controller.isVerifiedMinimum() && !controller.isVerifiedMuted(),
                    "lowest-volume verification must never be reported as verified mute");
            check(!audio.muted && audio.policyPreparations == 0,
                    "minimum-volume path must not depend on the failed native mute strategy");
            check(result.contains("minimum_volume") && result.contains("acoustic_check=unavailable"),
                    "diagnostics must distinguish reduction from physical silence");
            audio.volume = 3;
            controller.setMuted(true);
            check(audio.volume == minimum, "drift repair must reapply the minimum");
            controller.setMuted(false);
            check(audio.volume == 4 && !audio.muted && !controller.isVerifiedMinimum(),
                    "repeated reduction must preserve the first original volume for hangup/media-loss restore");
        }
    }

    private static void minimumVolumePreservesExistingMuteAndRejectsIgnoredWrites() throws Exception {
        Platform audio = new Platform();
        audio.muted = true; audio.unmuteOnVolume = true;
        LocalOutputMuteController controller = new LocalOutputMuteController(audio,
                LocalOutputMuteController.Strategy.MINIMUM_VOLUME);
        controller.setMuted(true);
        check(audio.volume == 1 && audio.muted, "positive volume writes must not cancel original user mute");
        controller.setMuted(false);
        check(audio.volume == 4 && audio.muted, "restore original volume and mute bit");
        Platform ignored = new Platform(); ignored.ignoreVolume = true;
        LocalOutputMuteController rejected = new LocalOutputMuteController(ignored,
                LocalOutputMuteController.Strategy.MINIMUM_VOLUME);
        try { rejected.setMuted(true); throw new AssertionError("ignored minimum write must be an error"); }
        catch (IOException expected) { }
        check(!rejected.isVerifiedMinimum() && ignored.volume == 4 && !ignored.muted,
                "failed reduction must roll back without claiming success");
        ignored.ignoreVolume = false;
        rejected.setMuted(true);
        ignored.rejectVolume = true;
        try { rejected.setMuted(false); throw new AssertionError("failed restore must surface"); }
        catch (IOException expected) { }
        ignored.rejectVolume = false;
        rejected.setMuted(false);
        check(ignored.volume == 4 && !ignored.muted, "failed minimum-volume restore must remain retryable");
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static final class Platform implements LocalOutputMuteController.Backend {
        boolean muted;
        boolean supportsMute = true;
        boolean rejectRestore;
        boolean rejectVolume;
        boolean unmuteOnVolume;
        boolean ignoreVolume;
        int minimum = 1, policyPreparations;
        int volume = 4;
        int changes;
        public boolean isMuted() { return muted; }
        public int volume() { return volume; }
        public int minimumVolume() { return minimum; }
        public void prepareOutputMute(boolean originalMuted) { policyPreparations++; }
        public void setVolume(int value) throws IOException {
            if (rejectVolume) throw new IOException("volume restore temporarily unavailable");
            if (!ignoreVolume) volume = value;
            changes++;
            if (unmuteOnVolume && value > 0) muted = false;
        }
        public void setMuted(boolean value) throws IOException {
            if (!value && rejectRestore) throw new IOException("platform temporarily unavailable");
            if (supportsMute) muted = value;
            changes++;
        }
    }
}
