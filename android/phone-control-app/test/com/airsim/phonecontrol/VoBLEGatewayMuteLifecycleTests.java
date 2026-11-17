package com.airsim.phonecontrol;

import com.airsim.phonecontrol.voble.*;
import java.net.*;
import java.util.concurrent.*;

/** Actual gateway methods with real TCP PCM handshakes; no Bluetooth radio or real calls. */
public final class VoBLEGatewayMuteLifecycleTests {
    public static void main(String[] args) throws Exception {
        earlySetupRejectionIsExplicitAndNeverStartsPCM();
        reconnectReplaysOnlyCurrentRingingIdentity();
        foregroundStartRecoversWithoutRestartingMedia();
        failedMediaCannotBeReownedByQueuedCallState();
        handshakeAfterDestroyCannotPublishOwnership();
        var destroyed = new VoBLEGatewayService();
        destroyed.onDestroy();
        destroyed.onDisconnected("retired-peer"); // must not submit work to a terminated executor
        destroyed.onAdvertisingFailed(-3);
        System.out.println("VoBLEGatewayMuteLifecycleTests passed: failed PCM rebind and post-destroy handshake");
    }

    private static void earlySetupRejectionIsExplicitAndNeverStartsPCM() throws Exception {
        var gateway = new VoBLEGatewayService();
        var call = new android.telecom.Call(android.telecom.Call.STATE_CONNECTING,
                android.telecom.Call.Details.DIRECTION_OUTGOING, "fixture");
        String id = CallRepository.add(call);
        var calls = new VoBLECallController(request -> { throw new AssertionError("must not dial"); });
        calls.observeCall(id, 4, "dialing"); set(gateway, "calls", calls);
        var envelope = new VoBLEProtocol.ControlEnvelope("start_early_media", id, 4,
                new byte[16], new byte[12], new byte[0], new byte[16]);
        try {
            var response = (VoBLECallController.Result) invoke(gateway, "startMedia",
                    new Class<?>[]{String.class, String.class, VoBLEProtocol.ControlEnvelope.class}, "peer", "fixture", envelope);
            check(!response.success() && response.code().equals("early_media_not_ready"),
                    "CONNECTING must explicitly permit a media-only retry before opening PCM");
            call.setStateForTest(android.telecom.Call.STATE_DISCONNECTED);
            response = (VoBLECallController.Result) invoke(gateway, "startMedia",
                    new Class<?>[]{String.class, String.class, VoBLEProtocol.ControlEnvelope.class}, "peer", "fixture", envelope);
            check(response.code().equals("early_media_unavailable"), "ended call must not invite retries");
            check(!RemoteAudioSessionRegistry.active(), "no PCM ownership without admission");
        } finally { CallRepository.remove(call); gateway.onDestroy(); }
    }

    private static void reconnectReplaysOnlyCurrentRingingIdentity() throws Exception {
        var gateway = new VoBLEGatewayService();
        var ring = new android.telecom.Call(android.telecom.Call.STATE_RINGING);
        var ended = new android.telecom.Call(android.telecom.Call.STATE_DISCONNECTED);
        String id = CallRepository.add(ring), dead = CallRepository.add(ended);
        var calls = new VoBLECallController(request -> { throw new AssertionError("snapshot is read-only"); });
        set(gateway, "calls", calls);
        try {
            invoke(gateway, "replayRingingCalls", new Class<?>[]{});
            long generation = calls.currentGeneration();
            check(calls.ownsCall(id, generation), "reconnect must restore live incoming call identity");
            invoke(gateway, "replayRingingCalls", new Class<?>[]{});
            check(calls.currentGeneration() == generation, "refresh must not create a new generation");
            check(!calls.ownsCall(dead, generation), "ended call cannot be replayed");
            check(ring.getState() == android.telecom.Call.STATE_RINGING, "snapshot must not answer");
        } finally { CallRepository.remove(ring); CallRepository.remove(ended); gateway.onDestroy(); }
    }

    private static void foregroundStartRecoversWithoutRestartingMedia() throws Exception {
        var gateway = new VoBLEGatewayService();
        var context = new android.content.Context() {
            @Override public android.content.ComponentName startForegroundService(android.content.Intent intent) {
                throw new AssertionError("running BLE service must not request another OS start");
            }
        };
        context.grant(android.Manifest.permission.BLUETOOTH_CONNECT);
        context.grant(android.Manifest.permission.BLUETOOTH_ADVERTISE);
        var gateField = VoBLEGatewayService.class.getDeclaredField("START_GATE");
        gateField.setAccessible(true);
        var gate = (ServiceStartGate) gateField.get(null);
        var instanceField = VoBLEGatewayService.class.getDeclaredField("instance");
        instanceField.setAccessible(true); instanceField.set(null, gateway); gate.created(gateway);
        var retryField = VoBLEGatewayService.class.getDeclaredField("advertisingRetries");
        retryField.setAccessible(true);
        var retries = (java.util.concurrent.atomic.AtomicLong) retryField.get(gateway);
        var identity = new VoBLEMediaSession.Identity("ongoing-call", 7);
        set(gateway, "mediaIdentity", identity);
        try {
            retries.set(4);
            VoBLEGatewayService.start(context);
            check(retries.get() == 0, "foreground start must recover exhausted advertising retry budget");
            var mediaField = VoBLEGatewayService.class.getDeclaredField("mediaIdentity");
            mediaField.setAccessible(true);
            check(mediaField.get(gateway) == identity, "advertising recovery cannot replace active media identity");
        } finally { gateway.onDestroy(); }
    }

    private static void failedMediaCannotBeReownedByQueuedCallState() throws Exception {
        var gateway = new VoBLEGatewayService();
        var call = new android.telecom.Call(android.telecom.Call.STATE_ACTIVE);
        String id = CallRepository.add(call);
        var calls = new VoBLECallController(request -> VoBLECallController.Result.success("accepted"));
        calls.observeCall(id, 1, "active");
        set(gateway, "calls", calls);
        var generationsField = VoBLEGatewayService.class.getDeclaredField("callGenerations");
        generationsField.setAccessible(true);
        @SuppressWarnings("unchecked")
        var generations = (java.util.Map<String, Long>) generationsField.get(gateway);
        generations.put(id, 1L);
        ExecutorService backend = Executors.newSingleThreadExecutor();
        try (ServerSocket server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            Future<Socket> peer = backend.submit(() -> {
                Socket socket = server.accept();
                socket.getInputStream().readNBytes(11);
                socket.getOutputStream().write("AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                socket.getOutputStream().flush();
                return socket;
            });
            CountDownLatch stopped = new CountDownLatch(1);
            try (var media = new VoBLEMediaSession(new InetSocketAddress(server.getInetAddress(), server.getLocalPort()),
                    endpoint -> VoBLEPCMBridgeSession.open(endpoint, VoBLEPCMBridgeSession.socketConnector()),
                    packet -> true, failed -> {
                        RemoteAudioSessionRegistry.releaseCall(failed);
                        stopped.countDown();
                    })) {
                var identity = new VoBLEMediaSession.Identity(id, 1);
                media.start(identity, new byte[32]);
                set(gateway, "media", media); set(gateway, "mediaIdentity", identity);
                RemoteAudioSessionRegistry.ownCall(media, id);
                RemoteAudioSessionRegistry.setVoBLE(true);
                peer.get(2, TimeUnit.SECONDS).close();
                check(stopped.await(2, TimeUnit.SECONDS), "PCM failure notification never arrived");
                check(!RemoteAudioSessionRegistry.ownsCall(java.util.List.of(id)), "failure must release exact owner");
                invoke(gateway, "publishCallState", new Class<?>[]{String.class, String.class, String.class, String.class},
                        id, "outgoing", "active", "");
                check(!RemoteAudioSessionRegistry.ownsCall(java.util.List.of(id)),
                        "queued call state must not resurrect ownership of failed BLE PCM before cleanup");
            }
        } finally {
            gateway.onDestroy(); backend.shutdownNow(); CallRepository.remove(call);
        }
    }

    private static void handshakeAfterDestroyCannotPublishOwnership() throws Exception {
        var gateway = new VoBLEGatewayService();
        var call = new android.telecom.Call(android.telecom.Call.STATE_ACTIVE);
        String id = CallRepository.add(call);
        var calls = new VoBLECallController(request -> VoBLECallController.Result.success("accepted"));
        calls.observeCall(id, 1, "active"); set(gateway, "calls", calls);
        var values = new java.util.HashMap<String, String>();
        var credentials = new VoBLECredentialStore(new VoBLECredentialStore.ProtectedBackend() {
            public String load(String key) { return values.get(key); }
            public void save(String key, String value) { values.put(key, value); }
            public void remove(String key) { values.remove(key); }
        });
        credentials.save("peer-fixture", new byte[32]);
        set(gateway, "pairingManager", new VoBLEPairingManager(credentials));
        set(gateway, "gatt", new VoBLEGattServer(new android.content.Context(),
                new VoBLEGattServer.Listener() {
                    public void onPairingWrite(String d, byte[] v) {} public void onControlWrite(String d, byte[] v) {}
                    public void onAudioWrite(String d, byte[] v) {} public void onDisconnected(String d) {}
                }, new VoBLEControlChannel()));
        ExecutorService opener = Executors.newSingleThreadExecutor();
        try (ServerSocket server = new ServerSocket(7580, 1, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(2000);
            var envelope = new VoBLEProtocol.ControlEnvelope("start_media", id, 1,
                    new byte[16], new byte[12], "{}".getBytes(java.nio.charset.StandardCharsets.UTF_8), new byte[16]);
            Future<Object> result = opener.submit(() -> invoke(gateway, "startMedia",
                    new Class<?>[]{String.class, String.class, VoBLEProtocol.ControlEnvelope.class},
                    "device-fixture", "peer-fixture", envelope));
            try (Socket peer = server.accept()) {
                peer.setSoTimeout(2000);
                check(peer.getInputStream().readNBytes(11).length == 11, "late startup never entered handshake");
                gateway.onDestroy();
                peer.getOutputStream().write("AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                peer.getOutputStream().flush();
                var response = (VoBLECallController.Result) result.get(2, TimeUnit.SECONDS);
                check(!RemoteAudioSessionRegistry.ownsCall(java.util.List.of(id)),
                        "handshake completing after gateway destruction must never publish mute ownership");
                check(!response.success(), "destroyed gateway cannot report media ready");
                check(!RemoteAudioSessionRegistry.active(), "destroyed gateway must not reactivate VoBLE media");
            }
        } finally {
            gateway.onDestroy(); opener.shutdownNow(); CallRepository.remove(call);
        }
    }

    private static void set(Object object, String field, Object value) throws Exception {
        var member = object.getClass().getDeclaredField(field);
        member.setAccessible(true); member.set(object, value);
    }
    private static Object invoke(Object object, String method, Class<?>[] types, Object... values) throws Exception {
        var member = object.getClass().getDeclaredMethod(method, types);
        member.setAccessible(true); return member.invoke(object, values);
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
