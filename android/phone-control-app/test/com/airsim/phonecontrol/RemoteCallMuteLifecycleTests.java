package com.airsim.phonecontrol;

import android.telecom.Call;

/** Real InCallService, ownership registry and mute controller; only OS/Binder boundaries are doubled. */
public final class RemoteCallMuteLifecycleTests {
    private static int passed;
    public static void main(String[] args) throws Exception {
        dialingWaitsForAnswerBeforeReducingSamsungOutput();
        ordinaryCallsStayAudible();
        routeChangePreservesUserCaptureVolume();
        for (String mode : new String[]{"remote_silent", "local_and_push"}) {
            for (String transport : new String[]{"vowlan", "voble", "cloud"}) {
                remoteLifecycle(mode, transport);
            }
        }
        ringingIsNotAnsweredOwnership();
        extraNativeCallRestoresOutput();
        disconnectingRetainsUntilRemoval();
        destroyRestoresOriginalVolume();
        deadBLEPCMRestoresOutput();
        queuedRefreshCannotRemuteAfterDestroy();
        minimumVolumeUsesAnsweredOwnershipAndRestoresOnMediaLoss();
        for (String transport : new String[]{"voble", "cloud"}) {
            wireDecodedCallIdentityTriggersMinimumVolume(transport);
        }
        differentDecodedCallCannotLowerVolume();
        vobleKeepsDownlinkCaptureAlive();
        transportSwitchRestoresPreviousPolicySnapshot();
        System.out.println("RemoteCallMuteLifecycleTests passed: " + passed + " scenarios");
    }

    /**
     * Regression (0.9.7.2 / VoBLE): Samsung used the OS minimum voice-call index, which on
     * this capture-coupled HAL also silenced VOICE_DOWNLINK. The iPhone then heard nothing
     * until the user raised the Android volume, at which point Android also played the call.
     * The fix must always target a NONZERO index so downlink capture survives.
     */
    private static void vobleKeepsDownlinkCaptureAlive() {
        ShizukuBridgeManager manager = ShizukuBridgeManager.INSTANCE;
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            manager.output = new LocalOutputMuteController(f.audio,
                    LocalOutputMuteController.vobleStrategy());
            Object media = new Object();
            RemoteAudioSessionRegistry.setVoBLE(true);
            check(RemoteAudioSessionRegistry.streamPolicy().equals(
                            PrivilegedBridgeProtocol.TRANSPORT_VOBLE),
                    "a VoBLE-only owner must select the voble stream policy");
            RemoteAudioSessionRegistry.ownCall(media, f.id);
            check(RemoteAudioSessionRegistry.ownsCall(java.util.List.of(f.id)),
                    "VoBLE owner must own the answered call");
            check(manager.lastTransport.equals(PrivilegedBridgeProtocol.TRANSPORT_VOBLE),
                    "VoBLE ownership must reach the privileged side as the voble transport");
            waitForDispatch();
            check(f.audio.volume >= 1,
                    "VoBLE must never target index 0, which also silences downlink capture: volume="
                            + f.audio.volume + " policy=" + manager.output.policyName());
            check(manager.output.policyName().equals("minimum_nonzero_volume"),
                    "Samsung must select the capture-safe nonzero policy, got "
                            + manager.output.policyName());
            RemoteAudioSessionRegistry.setVoBLE(false);
            RemoteAudioSessionRegistry.releaseCall(media);
            AirSIMInCallService.refreshAudioPolicy();
            waitForDispatch();
            check(!f.audio.muted && f.audio.volume == 6,
                    "VoBLE hangup must restore the original volume");
            check(f.call.getState() == Call.STATE_ACTIVE, "volume restoration must never disconnect");
        } finally { manager.output = new LocalOutputMuteController(manager.platform); }
        passed++;
    }

    /**
     * A suspended policy snapshot must never overwrite a volume the user raised between
     * transports; the next policy snapshots (and restores) that raised value.
     */
    private static void transportSwitchRestoresPreviousPolicySnapshot() throws Exception {
        ShizukuBridgeManager manager = ShizukuBridgeManager.INSTANCE;
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            LocalOutputMuteController vowlan = new LocalOutputMuteController(f.audio,
                    LocalOutputMuteController.vowlanStrategy());
            manager.output = vowlan;
            vowlan.setMuted(true);
            check(f.audio.volume == vowlan.targetMinimumVolume() && f.audio.volume >= 1,
                    "VoWLAN policy lowers to the capture-safe nonzero minimum");
            vowlan.suspend();
            // The user raises the volume by hand between transports (the exact recovery
            // action reported on device). The next policy must snapshot THIS value.
            f.audio.volume = 10;
            LocalOutputMuteController voble = new LocalOutputMuteController(f.audio,
                    LocalOutputMuteController.vobleStrategy());
            manager.output = voble;
            voble.setMuted(true);
            check(f.audio.volume == 1,
                    "the new policy reduces to its own nonzero minimum, not a stale snapshot");
            voble.setMuted(false);
            check(f.audio.volume == 10,
                    "release must restore the raised value, never the suspended stale index");
        } finally {
            manager.output = new LocalOutputMuteController(manager.platform);
        }
        passed++;
    }

    private static void wireDecodedCallIdentityTriggersMinimumVolume(String transport) {
        ShizukuBridgeManager manager = ShizukuBridgeManager.INSTANCE;
        manager.output = new LocalOutputMuteController(manager.platform,
                LocalOutputMuteController.Strategy.MINIMUM_VOLUME);
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            Object media = new Object();
            // JSON/BLE parsing produces equal text, not the repository's String object.
            String decodedID = new String(f.id.toCharArray());
            if ("voble".equals(transport)) {
                RemoteAudioSessionRegistry.setVoBLE(true);
                RemoteAudioSessionRegistry.ownCall(media, decodedID);
            } else RemoteAudioSessionRegistry.setCloud(media, true, decodedID);
            try {
                check(f.audio.volume == 1 && manager.output.isVerifiedMinimum(),
                        "ready " + transport + " media with a wire-decoded native call ID must lower Samsung output");
                check(!f.audio.muted && manager.watchdog,
                        "minimum policy must start its watchdog without claiming a mute bit");
                if ("voble".equals(transport)) RemoteAudioSessionRegistry.releaseCall(media);
                else RemoteAudioSessionRegistry.setCloud(media, false, "");
                check(f.audio.volume == 6 && !manager.output.isVerifiedMinimum(),
                        "releasing the exact media owner must restore the original volume");
            } finally {
                RemoteAudioSessionRegistry.releaseCall(media);
                RemoteAudioSessionRegistry.setVoBLE(false);
                RemoteAudioSessionRegistry.setCloud(media, false, "");
            }
        } finally { manager.output = new LocalOutputMuteController(manager.platform); }
        passed++;
    }

    private static void differentDecodedCallCannotLowerVolume() {
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            Object media = new Object();
            Object nonOwner = new Object();
            RemoteAudioSessionRegistry.setVoBLE(true);
            RemoteAudioSessionRegistry.ownCall(media, f.id + "-other-call");
            try {
                check(f.audio.volume == 6 && !f.audio.muted && !ShizukuBridgeManager.INSTANCE.watchdog,
                        "ready media belonging to a different call must not lower an ordinary call");
                RemoteAudioSessionRegistry.releaseCall(media);
                RemoteAudioSessionRegistry.ownCall(media, new String(f.id.toCharArray()));
                RemoteAudioSessionRegistry.releaseCall(nonOwner);
                check(f.audio.muted, "releasing a different owner must not revoke the actual owner's policy");
                RemoteAudioSessionRegistry.releaseCall(media);
                check(f.audio.volume == 6 && !f.audio.muted, "exact owner release must restore output");
            } finally {
                RemoteAudioSessionRegistry.releaseCall(media);
                RemoteAudioSessionRegistry.setVoBLE(false);
            }
        }
        passed++;
    }

    private static void minimumVolumeUsesAnsweredOwnershipAndRestoresOnMediaLoss() {
        ShizukuBridgeManager manager = ShizukuBridgeManager.INSTANCE;
        manager.output = new LocalOutputMuteController(manager.platform,
                LocalOutputMuteController.Strategy.MINIMUM_VOLUME);
        try (Fixture f = new Fixture(Call.STATE_DIALING)) {
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            check(f.audio.volume == 6 && !f.audio.muted, "dialing alone must preserve Samsung volume");
            f.call.setStateForTest(Call.STATE_ACTIVE);
            check(f.audio.volume == 1 && !f.audio.muted && manager.output.isVerifiedMinimum(),
                    "answered remote-owned call must lower the actual stream index, not claim mute");
            f.audio.volume = 3;
            RemoteAudioSessionRegistry.setCloud(owner, false, "");
            check(f.audio.volume == 6 && !f.audio.muted && !manager.output.isVerifiedMinimum(),
                    "lost remote audio must restore the original index while carrier call remains active");
            check(f.call.getState() == Call.STATE_ACTIVE, "volume restoration must never disconnect the call");
        } finally { manager.output = new LocalOutputMuteController(manager.platform); }
        passed++;
    }

    private static void dialingWaitsForAnswerBeforeReducingSamsungOutput() {
        try (Fixture f = new Fixture(Call.STATE_DIALING)) {
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            check(!f.audio.muted && f.audio.volume == 6,
                    "prepared remote audio must not lower Samsung output before the call is answered");
            f.call.setStateForTest(Call.STATE_ACTIVE);
            check(f.audio.muted, "answered remote audio may apply the selected suppression strategy");
            RemoteAudioSessionRegistry.setCloud(owner, false, "");
            check(!f.audio.muted && f.audio.volume == 6, "media loss must restore the original output");
        }
        passed++;
    }

    private static void ordinaryCallsStayAudible() {
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            check(!f.audio.muted, "default remote_silent must not silence an ordinary Android call without remote media");
            check(!ShizukuBridgeManager.INSTANCE.watchdog, "ordinary call must not start mute repair");
        }
        passed++;
    }

    private static void remoteLifecycle(String mode, String transport) {
        AppConfig.audioMode = mode;
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            check(!f.audio.muted, "pairing or native active state alone must not mute");
            Object owner = new Object();
            DirectCallOwnership.Lease lease = null;
            if ("cloud".equals(transport)) {
                RemoteAudioSessionRegistry.setCloud(owner, true, "");
                check(!f.audio.muted, "cloud PCM without the confirmed Android ID must not mute");
                RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            } else if ("voble".equals(transport)) {
                RemoteAudioSessionRegistry.setVoBLE(true);
                check(!f.audio.muted, "Bluetooth media alone must not own an arbitrary call");
                RemoteAudioSessionRegistry.ownCall(owner, f.id);
            } else {
                lease = DirectCallOwnership.begin("fixture-host");
                DirectCallOwnership.record("fixture-host", f.id, lease);
                RemoteAudioSessionRegistry.setVoWLAN(true);
                check(!f.audio.muted, "VoWLAN control without PCM readiness must not mute");
                DirectCallOwnership.pcmReady(lease);
                AirSIMInCallService.refreshAudioPolicy();
            }
            check(f.audio.muted && ShizukuBridgeManager.INSTANCE.watchdog,
                    transport + " ready and owned call must mute using the Shizuku backend in " + mode);
            f.audio.volume = 2;
            if ("cloud".equals(transport)) RemoteAudioSessionRegistry.setCloud(owner, false, "");
            else if ("voble".equals(transport)) {
                RemoteAudioSessionRegistry.releaseCall(owner);
                RemoteAudioSessionRegistry.setVoBLE(false);
            } else {
                DirectCallOwnership.end(lease, false);
                RemoteAudioSessionRegistry.setVoWLAN(false);
            }
            check(!f.audio.muted && f.audio.volume == 6,
                    transport + " media loss must restore the original output while the carrier call is still active");
            check(!ShizukuBridgeManager.INSTANCE.watchdog, "media loss must stop repair");
            check(f.call.getState() == Call.STATE_ACTIVE, "audio policy must not hang up the carrier call");
        } finally { AppConfig.audioMode = "remote_silent"; }
        passed++;
    }

    private static void routeChangePreservesUserCaptureVolume() {
        ShizukuBridgeManager manager = ShizukuBridgeManager.INSTANCE;
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            manager.output = new LocalOutputMuteController(f.audio,
                    LocalOutputMuteController.Strategy.PRESERVE_VOLUME);
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            f.audio.volume = 9;
            f.service.onCallAudioStateChanged(null);
            check(f.audio.volume == 9 && !f.audio.muted,
                    "route reassertion must respect preserve-volume instead of globally muting");
            f.call.setStateForTest(Call.STATE_DISCONNECTING);
            RemoteAudioSessionRegistry.setCloud(owner, false, "");
            check(f.audio.volume == 9, "teardown hold must not turn preserve into suppression");
            f.service.onCallRemoved(f.call);
            check(f.audio.volume == 9 && !f.audio.muted, "manual capture volume survives hangup");
        } finally { manager.output = new LocalOutputMuteController(manager.platform); }
        passed++;
    }

    private static void ringingIsNotAnsweredOwnership() {
        try (Fixture f = new Fixture(Call.STATE_RINGING)) {
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            check(!f.audio.muted, "preparing incoming cloud PCM must not claim an unanswered call");
            f.call.answer(0);
            check(f.audio.muted, "answer state must activate remote output mute");
            f.call.disconnect();
            check(f.audio.muted, "confirmed teardown retains previous output policy briefly");
            f.service.onCallRemoved(f.call);
            check(!f.audio.muted, "native removal restores output immediately");
            RemoteAudioSessionRegistry.setCloud(owner, false, "");
        }
        passed++;
    }

    private static void extraNativeCallRestoresOutput() {
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            check(f.audio.muted, "remote call should initially mute");
            Call ordinary = new Call(Call.STATE_RINGING);
            f.service.onCallAdded(ordinary);
            check(!f.audio.muted, "global stream mute must not silence a second ordinary call");
            f.service.onCallRemoved(ordinary);
            check(f.audio.muted, "remaining unique remote call may resume mute");
            RemoteAudioSessionRegistry.setCloud(owner, false, "");
        }
        passed++;
    }

    private static void disconnectingRetainsUntilRemoval() {
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            check(f.audio.muted, "remote call should initially mute");
            f.call.setStateForTest(Call.STATE_DISCONNECTING);
            check(f.audio.muted, "disconnecting retains only its previously owned output policy");
            RemoteAudioSessionRegistry.setCloud(owner, false, "");
            check(f.audio.muted, "PCM release during confirmed teardown must not briefly leak audio");
            f.service.onCallRemoved(f.call);
            check(!f.audio.muted && f.audio.volume == 6, "removal restores original volume");
        }
        passed++;
    }

    private static void destroyRestoresOriginalVolume() {
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            check(f.audio.muted, "remote call should initially mute");
            f.audio.volume = 1;
            f.destroy();
            check(!f.audio.muted && f.audio.volume == 6, "InCallService destruction must restore the original output");
            RemoteAudioSessionRegistry.setCloud(owner, false, "");
        }
        passed++;
    }

    private static void deadBLEPCMRestoresOutput() throws Exception {
        // A successful handshake followed by real TCP EOF must revoke mute ownership,
        // even when the Bluetooth control connection and carrier call remain alive.
        try (Fixture f = new Fixture(Call.STATE_ACTIVE);
                java.net.ServerSocket server = new java.net.ServerSocket(0, 1,
                        java.net.InetAddress.getLoopbackAddress())) {
            var callbackCount = new java.util.concurrent.atomic.AtomicInteger();
            var stopped = new java.util.concurrent.CountDownLatch(1);
            java.util.function.Consumer<com.airsim.phonecontrol.voble.VoBLEMediaSession> listener = owner -> {
                callbackCount.incrementAndGet();
                RemoteAudioSessionRegistry.releaseCall(owner);
                stopped.countDown();
            };
            var media = new com.airsim.phonecontrol.voble.VoBLEMediaSession(
                    new java.net.InetSocketAddress(server.getInetAddress(), server.getLocalPort()),
                    endpoint -> com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.open(endpoint,
                            com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.socketConnector()),
                    packet -> true, listener);
            java.util.concurrent.ExecutorService backend = java.util.concurrent.Executors.newSingleThreadExecutor();
            var peer = backend.submit(() -> {
                java.net.Socket socket = server.accept();
                socket.getInputStream().readNBytes(11); // AIRSIMPCM1 + newline
                socket.getOutputStream().write("AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                socket.getOutputStream().flush();
                return socket;
            });
            try (media) {
                media.start(new com.airsim.phonecontrol.voble.VoBLEMediaSession.Identity(f.id, 1), new byte[32]);
                RemoteAudioSessionRegistry.ownCall(media, f.id);
                RemoteAudioSessionRegistry.setVoBLE(true);
                check(f.audio.muted, "live BLE PCM must first mute output");
                peer.get(2, java.util.concurrent.TimeUnit.SECONDS).close();
                check(stopped.await(2, java.util.concurrent.TimeUnit.SECONDS), "PCM EOF must notify without waiting for GATT disconnect");
                check(!f.audio.muted && !media.ready(), "PCM EOF must restore local output immediately");
                check(callbackCount.get() == 1, "both pumps failing may release this owner only once");
                check(f.call.getState() == Call.STATE_ACTIVE, "PCM failure must not end the carrier call");
            } finally {
                backend.shutdownNow();
                RemoteAudioSessionRegistry.releaseCall(media);
                RemoteAudioSessionRegistry.setVoBLE(false);
            }
        }
        passed++;
    }

    private static void queuedRefreshCannotRemuteAfterDestroy() {
        try (Fixture f = new Fixture(Call.STATE_ACTIVE)) {
            Object owner = new Object();
            RemoteAudioSessionRegistry.setCloud(owner, true, f.id);
            check(f.audio.muted, "remote call should initially mute");
            android.os.Handler.deferForTest = true;
            try {
                AirSIMInCallService.refreshAudioPolicy();
                f.destroy();
                android.os.Handler.runPendingForTest();
                check(!f.audio.muted, "queued policy refresh must not re-mute after service destruction restored output");
            } finally {
                android.os.Handler.deferForTest = false;
                RemoteAudioSessionRegistry.setCloud(owner, false, "");
            }
        }
        passed++;
    }

    private static final class Fixture implements AutoCloseable {
        final AirSIMInCallService service = new AirSIMInCallService();
        final ShizukuBridgeManager.Platform audio = ShizukuBridgeManager.INSTANCE.platform;
        final Call call;
        final String id;
        boolean destroyed;
        Fixture(int state) {
            RemoteAudioSessionRegistry.resetForTests();
            audio.muted = false; audio.volume = 6;
            call = new Call(state);
            service.onCallAdded(call);
            id = CallRepository.id(call);
        }
        public void close() {
            if (!destroyed) service.onCallRemoved(call);
            else CallRepository.remove(call);
            if (!destroyed) destroy();
            RemoteAudioSessionRegistry.resetForTests();
        }
        void destroy() { service.onDestroy(); destroyed = true; }
    }
    /** The fixture dispatches mute requests on a real worker thread. */
    private static void waitForDispatch() {
        try { Thread.sleep(200); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
