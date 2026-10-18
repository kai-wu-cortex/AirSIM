package com.airsim.phonecontrol;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

public final class CallOutputPolicyMuteTests {
    public static void main(String[] args) throws Exception {
        Platform platform = new Platform();
        CallOutputPolicyMute mute = new CallOutputPolicyMute(platform);
        mute.prepare(false);
        mute.apply();
        check(platform.calls.equals(List.of("1:0:true", "2:0:true")),
                "mute only built-in call sinks, with an explicit muted policy");
        check(mute.applied(), "accepted commands and zero readbacks must be recorded");
        mute.restore();
        check(platform.earpiece == 7 && platform.speaker == 15 && !mute.applied(),
                "restore exact pre-call device indices, not a guessed gain");
        check(platform.calls.subList(2, 4).equals(List.of("1:7:false", "2:15:false")),
                "restore original mute policy for both devices");
        int idleCalls = platform.calls.size();
        mute.restore();
        check(platform.calls.size() == idleCalls, "idle restore must not touch audio");

        platform = new Platform();
        platform.earpiece = platform.speaker = 0;
        mute = new CallOutputPolicyMute(platform);
        mute.prepare(true);
        mute.apply();
        check(platform.calls.size() == 2, "old zero indices must not skip a new call's mute");
        mute.restore();
        check(platform.calls.subList(2, 4).equals(List.of("1:0:true", "2:0:true")),
                "pre-existing mute must survive restoration");

        platform = new Platform();
        platform.ignoreMute = true;
        mute = new CallOutputPolicyMute(platform);
        mute.prepare(false);
        try { mute.apply(); throw new AssertionError("ignored policy command must fail"); }
        catch (IOException expected) { /* a returned command is not sufficient */ }
        check(!mute.applied(), "failed readback must not claim policy applied");
        mute.restore();

        platform = new Platform();
        mute = new CallOutputPolicyMute(platform);
        mute.prepare(false);
        mute.apply();
        platform.rejectRestore = true;
        try { mute.restore(); throw new AssertionError("restore failure must surface"); }
        catch (IOException expected) { /* keep the original snapshot for retry */ }
        platform.rejectRestore = false;
        mute.restore();
        check(platform.earpiece == 7 && platform.speaker == 15,
                "a failed restore must not discard the pre-call snapshot");
        frameworkVariants();
        delayedPreparationCannotLeakIntoNextCall();
        System.out.println("CallOutputPolicyMuteTests passed");
    }

    private static void delayedPreparationCannotLeakIntoNextCall() throws Exception {
        var entered = new java.util.concurrent.CountDownLatch(1);
        var release = new java.util.concurrent.CountDownLatch(1);
        var returned = new java.util.concurrent.CountDownLatch(1);
        Platform platform = new Platform();
        var delayed = new CallOutputPolicyMute.Api() {
            public int index(int device) throws Exception {
                int captured = platform.index(device);
                if (device == 1) { entered.countDown(); release.await(); }
                if (device == 2) returned.countDown();
                return captured;
            }
            public void set(int device, int index, boolean muted) throws Exception { platform.set(device, index, muted); }
        };
        try (var operations = new BoundedAudioOperation(30)) {
            try {
                CallOutputPolicyMute.prepareWithin(operations, delayed, false);
                throw new AssertionError("delayed preparation must time out without publishing state");
            } catch (java.util.concurrent.TimeoutException expected) { /* no live owner received the snapshot */ }
            finally { release.countDown(); }
            check(entered.await(1, java.util.concurrent.TimeUnit.SECONDS)
                    && returned.await(1, java.util.concurrent.TimeUnit.SECONDS), "delayed read must finish");
            platform.earpiece = 11; platform.speaker = 12;
            CallOutputPolicyMute next = null;
            long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(1);
            while (next == null && System.nanoTime() < deadline) {
                try { next = CallOutputPolicyMute.prepareWithin(operations, platform, false); }
                catch (IOException busy) { Thread.yield(); }
            }
            check(next != null, "next call must acquire its own preparation");
            next.apply(); next.restore();
            check(platform.earpiece == 11 && platform.speaker == 12,
                    "late preparation must not restore previous call settings into a later call");
        }
    }

    private static void frameworkVariants() throws Exception {
        var current = new SystemCallOutputPolicy(CurrentFramework.class);
        current.set(1, 0, true);
        check(CurrentFramework.last.equals("0:0:true:1"),
                "four-argument framework requires an explicit true mute bit before the device");
        check(current.index(1) == 0, "query the same stream/device used by the setter");
        var legacy = new SystemCallOutputPolicy(LegacyFramework.class);
        legacy.set(2, 0, true);
        check(LegacyFramework.last.equals("0:0:2"), "legacy three-argument framework must remain usable");
        CurrentFramework.rejected = true;
        try { current.set(1, 0, true); throw new AssertionError("non-zero native status must fail"); }
        catch (IOException expected) { /* permission/OEM rejection is not success */ }
        CurrentFramework.rejected = false;
        try { new SystemCallOutputPolicy(String.class); throw new AssertionError("missing API must fail closed"); }
        catch (NoSuchMethodException expected) { /* no guessed Binder transaction fallback */ }
    }

    public static final class CurrentFramework {
        static String last = "";
        static boolean rejected;
        public static int setStreamVolumeIndexAS(int stream, int index, boolean muted, int device) {
            last = stream + ":" + index + ":" + muted + ":" + device;
            return rejected ? -1 : 0;
        }
        public static int getStreamVolumeIndex(int stream, int device) {
            if (stream != 0 || device != 1) throw new AssertionError("wrong policy query");
            return 0;
        }
    }
    public static final class LegacyFramework {
        static String last = "";
        public static int setStreamVolumeIndexAS(int stream, int index, int device) {
            last = stream + ":" + index + ":" + device;
            return 0;
        }
        public static int getStreamVolumeIndex(int stream, int device) { return 0; }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static final class Platform implements CallOutputPolicyMute.Api {
        int earpiece = 7, speaker = 15;
        boolean ignoreMute, rejectRestore;
        final List<String> calls = new ArrayList<>();
        public int index(int device) { return device == 1 ? earpiece : speaker; }
        public void set(int device, int index, boolean muted) throws IOException {
            if (index > 0 && rejectRestore) throw new IOException("restore unavailable");
            calls.add(device + ":" + index + ":" + muted);
            if (muted && ignoreMute) return;
            if (device == 1) earpiece = index;
            else if (device == 2) speaker = index;
            else throw new AssertionError("must not modify telephony TX or Bluetooth devices");
        }
    }
}
