package com.airsim.bridge;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;

public final class BridgeUnitTests {
    private static int checks;

    private BridgeUnitTests() {}

    public static void main(String[] args) throws Exception {
        testArguments();
        testArgumentFailures();
        testHandshake();
        testStats();
        testSessionGate();
        testSamsungAudioContract();
        testListenerRecoveryPolicy();
        testVoiceTxRouteTimeoutPolicy();
        System.out.println("PASS BridgeUnitTests checks=" + checks);
    }

    private static void testArguments() {
        BridgeArguments loopback = BridgeArguments.parse(new String[] {
            "--listen-host", "127.0.0.1", "--listen-port", "7580"
        });
        check(loopback.listenHost().equals("127.0.0.1"), "loopback host");
        check(loopback.listenPort() == 7580, "listen port");

        BridgeArguments avfPrivate = BridgeArguments.parse(new String[] {
            "--listen-host", "192.168.240.1"
        });
        check(avfPrivate.listenHost().equals("192.168.240.1"), "private host");
        check(avfPrivate.listenPort() == 7580, "default port");

        BridgeArguments dynamicAVF = BridgeArguments.parse(new String[] {
            "--listen-interface", "avf_tap_fixed", "--listen-port", "7580"
        });
        check(dynamicAVF.listenInterface().equals("avf_tap_fixed"), "dynamic AVF interface");
        check(dynamicAVF.listenHost() == null, "dynamic AVF host is resolved at bind time");
    }

    private static void testArgumentFailures() {
        expectFailure(new String[] {}, "missing host");
        expectFailure(new String[] {"--listen-host", "0.0.0.0"}, "wildcard host");
        expectFailure(new String[] {"--listen-host", "8.8.8.8"}, "public host");
        expectFailure(new String[] {"--listen-host", "::1"}, "unsupported IPv6 host");
        expectFailure(new String[] {"--listen-host", "127.0.0.1", "--listen-port", "1023"},
            "privileged port");
        expectFailure(new String[] {"--listen-host", "127.0.0.1", "--listen-port", "65536"},
            "port too large");
        expectFailure(new String[] {"--listen-host", "127.0.0.1", "--unknown", "x"},
            "unknown option");
        expectFailure(new String[] {"--listen-interface", "wlan0"},
            "externally reachable interface");
        expectFailure(new String[] {"--listen-host", "127.0.0.1", "--listen-interface", "avf_tap_fixed"},
            "host and interface are mutually exclusive");
    }

    private static void testHandshake() throws Exception {
        ByteArrayOutputStream response = new ByteArrayOutputStream();
        BridgeProtocol.acceptHandshake(
            new ByteArrayInputStream(BridgeProtocol.CLIENT_HELLO), response);
        check(response.toString(StandardCharsets.US_ASCII).equals("AIRSIMREADY"),
            "ready response");
        check(BridgeProtocol.FRAME_BYTES == 320, "frame bytes");

        boolean failed = false;
        try {
            BridgeProtocol.acceptHandshake(
                new ByteArrayInputStream("AIRSIMPCM2\n".getBytes(StandardCharsets.US_ASCII)),
                new ByteArrayOutputStream());
        } catch (IllegalArgumentException expected) {
            failed = true;
        }
        check(failed, "malformed hello rejected");
    }

    private static void testStats() {
        BridgeStats stats = new BridgeStats();
        byte[] twoFrames = new byte[BridgeProtocol.FRAME_BYTES * 2];
        twoFrames[0] = 0;
        twoFrames[1] = (byte) 0x80;
        stats.recordDownlink(twoFrames, twoFrames.length);
        stats.recordUplink(new byte[BridgeProtocol.FRAME_BYTES], BridgeProtocol.FRAME_BYTES);
        stats.recordRejectedClient();

        BridgeStats.Snapshot snapshot = stats.snapshot();
        check(snapshot.downlinkBytes() == 640, "downlink bytes");
        check(snapshot.downlinkFrames() == 2, "downlink frames");
        check(snapshot.downlinkPeak() == 32768, "downlink peak");
        check(snapshot.uplinkBytes() == 320, "uplink bytes");
        check(snapshot.uplinkFrames() == 1, "uplink frames");
        check(snapshot.uplinkPeak() == 0, "silent uplink peak");
        check(snapshot.rejectedClients() == 1, "rejected clients");
        for (Field field : BridgeStats.class.getDeclaredFields()) {
            check(!field.getType().isArray(), "stats retain no frame payloads");
        }
    }

    private static void testSessionGate() {
        BridgeSessionGate gate = new BridgeSessionGate();
        Object first = new Object();
        Object second = new Object();
        check(gate.tryAcquire(first), "first client accepted");
        check(!gate.tryAcquire(second), "second client rejected");
        gate.release(second);
        check(!gate.tryAcquire(second), "non-owner cannot release session");
        gate.release(first);
        check(gate.tryAcquire(second), "next client accepted after release");
    }

    private static void testSamsungAudioContract() {
        check(PhoneAudioBridge.captureSource() == 3, "VOICE_DOWNLINK capture source");
        check(PhoneAudioBridge.playbackUsage() == 2,
            "VOICE_TX uses voice communication usage");
        String[] tags = PhoneAudioBridge.playbackTags();
        check(tags.length == 1 && tags[0].equals("VOICE_TX"), "Samsung VOICE_TX tag");
        check(PhoneAudioBridge.playbackRoute(true, true)
                == PhoneAudioBridge.PlaybackRoute.SAMSUNG_TAG,
            "Samsung tag remains preferred when available");
        check(PhoneAudioBridge.playbackRoute(false, true)
                == PhoneAudioBridge.PlaybackRoute.TELEPHONY_DEVICE,
            "non-Samsung devices select the Android Telephony Tx output");
        check(PhoneAudioBridge.playbackRoute(false, false)
                == PhoneAudioBridge.PlaybackRoute.UNSUPPORTED,
            "missing Samsung tag and Telephony Tx is rejected");
    }

    private static void testListenerRecoveryPolicy() {
        check(PhoneAudioBridge.listenerRetryDelayMillis(1) == 250,
            "first listener recovery retry is prompt");
        check(PhoneAudioBridge.listenerRetryDelayMillis(2) == 500,
            "listener recovery backs off");
        check(PhoneAudioBridge.listenerRetryDelayMillis(20) == 5000,
            "listener recovery delay is capped");
    }

    private static void testVoiceTxRouteTimeoutPolicy() {
        check(!PhoneAudioBridge.voiceTxRouteTimedOut(true, 1000, 10000),
            "verified Telephony route survives an uplink gap");
        check(!PhoneAudioBridge.voiceTxRouteTimedOut(false, 0, 10000),
            "route timer waits for first playback");
        check(!PhoneAudioBridge.voiceTxRouteTimedOut(false, 1000, 2999),
            "unverified route remains inside grace period");
        check(PhoneAudioBridge.voiceTxRouteTimedOut(false, 1000, 3000),
            "unverified route fails after grace period");
    }

    private static void expectFailure(String[] args, String name) {
        boolean failed = false;
        try {
            BridgeArguments.parse(args);
        } catch (IllegalArgumentException expected) {
            failed = true;
        }
        check(failed, name);
    }

    private static void check(boolean condition, String name) {
        checks++;
        if (!condition) {
            throw new AssertionError(name);
        }
    }
}
