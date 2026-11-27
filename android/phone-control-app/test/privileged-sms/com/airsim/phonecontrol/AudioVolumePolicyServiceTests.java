package com.airsim.phonecontrol;

/** Executes the actual privileged policy switch; synthetic AudioManager, no devices/audio. */
public final class AudioVolumePolicyServiceTests {
    public static void main(String[] args) throws Exception {
        android.os.Process.uid = 2000;
        var service = new ShizukuBridgeUserService();
        var context = ShizukuBridgeUserService.class.getDeclaredField("serviceContext");
        context.setAccessible(true); context.set(service, new android.content.Context("fixture"));
        var store = ShizukuBridgeUserService.class.getDeclaredField("isolationStore");
        store.setAccessible(true); store.set(service, new LocalAudioIsolationController.MemoryStore());
        var audio = android.content.Context.audio;
        apply(service, true, "vowlan", "minimum_nonzero_volume");
        check(audio.volume == 1, "minimum did not reduce volume");
        apply(service, true, "voble", "minimum_nonzero_volume");
        apply(service, true, "voble", "preserve_volume");
        check(audio.volume == 5, "policy switch must restore pre-reduction volume, across transport changes");
        audio.volume = 7;
        int writes = audio.writes;
        apply(service, true, "vowlan", "preserve_volume");
        apply(service, false, "vowlan", "preserve_volume");
        check(audio.volume == 7 && audio.writes == writes, "preserve watchdog/hangup rewrote manual volume");
        apply(service, true, "voble", "minimum_nonzero_volume");
        audio.rejectWrites = true;
        try {
            apply(service, true, "voble", "preserve_volume");
            throw new AssertionError("failed restore must reject switching");
        } catch (java.lang.reflect.InvocationTargetException expected) { }
        audio.rejectWrites = false;
        apply(service, true, "voble", "preserve_volume");
        check(audio.volume == 7, "failed restore lost original snapshot");
        apply(service, false, "voble", "preserve_volume");
        int frameworkWrites = audio.writes;
        try { apply(service, true, "vowlan", "isolate_local"); throw new AssertionError("non-owner isolated call"); }
        catch (java.lang.reflect.InvocationTargetException expected) { }
        check(!audio.microphone && audio.writes == frameworkWrites, "non-owner must not touch audio");
        var ownership = ShizukuBridgeUserService.class.getDeclaredField("bridgeOwnership");
        ownership.setAccessible(true);
        ownership.set(service, new android.net.LocalServerSocket("audio-volume-fixture"));
        apply(service, true, "vowlan", "isolate_local");
        check(audio.microphone && android.media.AudioSystem.earpiece == 0 && android.media.AudioSystem.speaker == 0,
                "production service must apply all physical isolation endpoints");
        check(audio.volume == 7 && !audio.muted && audio.writes == frameworkWrites,
                "isolation must not change global stream/PCM volume");
        var snapshot = ShizukuBridgeUserService.class.getDeclaredMethod("audioSnapshot");
        snapshot.setAccessible(true);
        check(AudioWatchdogSnapshot.parse((String) snapshot.invoke(service)).targetSatisfied(),
                "actual service snapshot verifies physical endpoints instead of global mute");
        audio.microphone = false; android.media.AudioSystem.speaker = 5;
        check(!AudioWatchdogSnapshot.parse((String) snapshot.invoke(service)).targetSatisfied(), "snapshot detects drift");
        apply(service, true, "voble", "isolate_local");
        check(audio.microphone && android.media.AudioSystem.speaker == 0, "transport/route reassertion repairs drift");
        apply(service, true, "voble", "preserve_volume");
        check(!audio.microphone && android.media.AudioSystem.earpiece == 7 && android.media.AudioSystem.speaker == 9,
                "leaving isolation restores original mic and independent sink snapshots");
        apply(service, false, "voble", "preserve_volume");
        audio.mode = 0;
        try { apply(service, true, "vowlan", "isolate_local"); throw new AssertionError("idle isolation accepted"); }
        catch (java.lang.reflect.InvocationTargetException expected) { }
        check(!audio.microphone && audio.writes == frameworkWrites, "idle rejection must not touch user audio");
        audio.mode = 2;
        service.shutdown(); service.awaitShutdown();
        System.out.println("AudioVolumePolicyServiceTests passed: policy/transport transitions, manual volume, restore failure");
    }
    private static void apply(ShizukuBridgeUserService service, boolean active, String transport, String policy) throws Exception {
        var method = ShizukuBridgeUserService.class.getDeclaredMethod("setLocalOutputMuted", boolean.class, String.class, String.class);
        method.setAccessible(true); method.invoke(service, active, transport, policy);
    }
    private static void check(boolean ok, String detail) { if (!ok) throw new AssertionError(detail); }
}
