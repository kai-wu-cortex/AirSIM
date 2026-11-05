package com.airsim.phonecontrol;

/** Executes the actual privileged policy switch; synthetic AudioManager, no devices/audio. */
public final class AudioVolumePolicyServiceTests {
    public static void main(String[] args) throws Exception {
        android.os.Process.uid = 2000;
        var service = new ShizukuBridgeUserService();
        var context = ShizukuBridgeUserService.class.getDeclaredField("serviceContext");
        context.setAccessible(true); context.set(service, new android.content.Context("fixture"));
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
        var operations = ShizukuBridgeUserService.class.getDeclaredField("audioOperations");
        operations.setAccessible(true); ((BoundedAudioOperation) operations.get(service)).close();
        System.out.println("AudioVolumePolicyServiceTests passed: policy/transport transitions, manual volume, restore failure");
    }
    private static void apply(ShizukuBridgeUserService service, boolean active, String transport, String policy) throws Exception {
        var method = ShizukuBridgeUserService.class.getDeclaredMethod("setLocalOutputMuted", boolean.class, String.class, String.class);
        method.setAccessible(true); method.invoke(service, active, transport, policy);
    }
    private static void check(boolean ok, String detail) { if (!ok) throw new AssertionError(detail); }
}
