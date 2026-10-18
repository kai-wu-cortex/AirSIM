package com.airsim.phonecontrol;

import android.content.ComponentName;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.pm.PackageManager;
import com.airsim.phonecontrol.voble.VoBLEGatewayService;
import com.airsim.phonecontrol.voble.VoBLEProtocol;
import java.util.Arrays;

/** Run via app_process with the actual APK on Android; no calls or user credentials are needed. */
public final class VoBLECompatibilityDeviceTests {
    public static void main(String[] args) throws Exception {
        try {
            if (args.length != 1) throw new IllegalArgumentException("fragments, crypto or service required");
            if ("fragments".equals(args[0])) fragments();
            else if ("service".equals(args[0])) service();
            else if ("crypto".equals(args[0])) crypto();
            else if ("apis".equals(args[0])) apis();
            else if ("audio-readonly".equals(args[0])) audioReadOnly();
            else throw new IllegalArgumentException("unknown test");
            System.out.println("PASS VoBLE Android runtime " + args[0]);
        } catch (Throwable failure) {
            failure.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static void apis() throws Exception {
        var request = StandaloneLongPoll.parse("/api/events?%61fter=7&timeout_ms=100", 1_000);
        if (request.after() != 7 || request.timeoutMillis() != 100) {
            throw new AssertionError("encoded local event queries must decode on Android 10+");
        }
        var inputMethod = VoWLANPCMRelay.class.getDeclaredMethod("activeInternalInput", java.net.Socket.class);
        inputMethod.setAccessible(true);
        try (var socket = new java.net.Socket();
             var input = (java.io.InputStream) inputMethod.invoke(null, socket)) {
            if (input.read() != -1) throw new AssertionError("failed PCM socket must end cleanly");
        }
        var service = new ShizukuBridgeUserService();
        var command = ShizukuBridgeUserService.class.getDeclaredMethod("runCommand", String[].class);
        command.setAccessible(true);
        String output = (String) command.invoke(service,
                (Object) new String[]{"/system/bin/sh", "-c", "echo first; echo second"});
        if (!"first\nsecond".equals(output)) throw new AssertionError("privileged output lost line boundaries");
    }

    private static void audioReadOnly() throws Exception {
        if (android.os.Looper.getMainLooper() == null) android.os.Looper.prepareMainLooper();
        var service = new ShizukuBridgeUserService();
        var factory = ShizukuBridgeUserService.class.getDeclaredMethod("audioBackend");
        factory.setAccessible(true);
        var audio = (LocalOutputMuteController.Backend) factory.invoke(service);
        audio.isMuted();
        audio.volume();
        // Never change live-device audio outside a coordinated call test.
    }

    private static void fragments() {
        byte[] payload = "pairing-regression-fixture".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        var reassembler = new VoBLEProtocol.MessageReassembler();
        VoBLEProtocol.Message result = null;
        for (byte[] fragment : VoBLEProtocol.encodeMessageFragments(
                payload, 20, VoBLEProtocol.MESSAGE_PAIRING, 7)) {
            result = reassembler.append(fragment, 1_000);
        }
        if (result == null || !Arrays.equals(payload, result.payload())) {
            throw new AssertionError("pairing message must survive Android runtime reassembly");
        }
    }

    private static void service() {
        LaunchContext context = new LaunchContext();
        try { VoBLEGatewayService.start(context); }
        catch (IllegalStateException error) {
            throw new AssertionError("background FGS denial must not crash application startup", error);
        }
        context.blocked = false;
        VoBLEGatewayService.start(context);
        if (context.attempts != 2) throw new AssertionError("foreground retry must not be latched off");
        context.blocked = true;
        context.rejection = new SecurityException("permission revoked between check and start");
        try { VoBLEGatewayService.start(context); }
        catch (SecurityException error) { throw new AssertionError("permission race must not crash", error); }
        context.granted = false;
        VoBLEGatewayService.start(context);
        if (context.attempts != 3) throw new AssertionError("revoked Bluetooth permission must not start FGS");
        context.granted = true;
        context.rejection = new IllegalArgumentException("invalid service configuration");
        try {
            VoBLEGatewayService.start(context);
            throw new AssertionError("unexpected configuration errors must remain visible");
        } catch (IllegalArgumentException expected) { /* not a background restriction */ }
    }

    private static void crypto() throws Exception {
        byte[] androidPrivate = new byte[32];
        byte[] iphonePrivate = new byte[32];
        for (int index = 0; index < 32; index++) {
            androidPrivate[index] = (byte) (index + 1);
            iphonePrivate[index] = (byte) (index + 33);
        }
        byte[] androidPublic = com.airsim.phonecontrol.voble.VoBLEPairingManager.publicKey(androidPrivate);
        byte[] iphonePublic = com.airsim.phonecontrol.voble.VoBLEPairingManager.publicKey(iphonePrivate);
        byte[] firstNonce = new byte[32];
        byte[] secondNonce = new byte[32];
        Arrays.fill(firstNonce, (byte) 0x11);
        Arrays.fill(secondNonce, (byte) 0x22);
        var transcript = new com.airsim.phonecontrol.voble.VoBLEPairingManager.Transcript(
                "samsung-test", androidPublic, iphonePublic, firstNonce, secondNonce);
        var pairing = com.airsim.phonecontrol.voble.VoBLEPairingManager.derivePairing(
                androidPrivate, iphonePublic, transcript);
        if (!"41cef6294f3575441997664149bd8a014c8db026ad3a5312410be90f7d76c48a".equals(
                PairingCrypto.hex(pairing.pairingKey()))) throw new AssertionError("pairing vector changed");
        var keys = com.airsim.phonecontrol.voble.VoBLEPairingManager.deriveSessionKeys(
                pairing.pairingKey(), new byte[]{1, 2, 3}, "fixture-call", 1);
        if (keys.control().length != 32 || Arrays.equals(keys.control(), keys.media())) {
            throw new AssertionError("session keys must be separated");
        }
        byte[] plain = "fixture".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        if (!Arrays.equals(plain, PairingCrypto.open(
                PairingCrypto.seal(plain, keys.media(), "fixture"), keys.media(), "fixture"))) {
            throw new AssertionError("authenticated encryption round trip failed");
        }
    }

    private static final class LaunchContext extends ContextWrapper {
        boolean blocked = true;
        boolean granted = true;
        int attempts;
        RuntimeException rejection = new IllegalStateException("background start not allowed");
        LaunchContext() { super(null); }
        @Override public String getPackageName() { return "com.airsim.phonecontrol.standalone"; }
        @Override public int checkSelfPermission(String permission) {
            return granted ? PackageManager.PERMISSION_GRANTED : PackageManager.PERMISSION_DENIED;
        }
        @Override public ComponentName startForegroundService(Intent intent) {
            attempts++;
            if (blocked) throw rejection;
            return new ComponentName("com.airsim.test", "VoBLEGatewayService");
        }
    }
}
