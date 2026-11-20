package com.airsim.phonecontrol;

import android.content.Context;
import android.telecom.Call;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.*;

/** Real TCP relay; replace only Android credential storage and audio-policy OS boundary. */
public final class DirectPCMIntegrationTests {
    public static void main(String[] args) throws Exception {
        earlyCaptureRecoversWithoutChangingCarrierPCM();
        Inet4Address loopback = (Inet4Address) InetAddress.getByName("127.0.0.1");
        ExecutorService worker = Executors.newSingleThreadExecutor();
        try (ServerSocket shell = new ServerSocket(7580, 4, loopback)) {
            CountDownLatch firstAccepted = new CountDownLatch(1);
            Future<?> backend = worker.submit(() -> {
                try (Socket stalled = shell.accept()) {
                    firstAccepted.countDown();
                    // Accept but never return READY. Closing the gateway must unblock it.
                    while (stalled.getInputStream().read() >= 0) {}
                } catch (Exception error) { throw new RuntimeException(error); }
                try (Socket ready = shell.accept()) {
                    acceptBridgeHello(ready, false);
                    ready.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
                    ready.getOutputStream().flush();
                    byte[] uplink = new byte[320];
                    new java.io.DataInputStream(ready.getInputStream()).readFully(uplink);
                    ready.getOutputStream().write(uplink);
                    ready.getOutputStream().flush();
                    while (ready.getInputStream().read() >= 0) {}
                } catch (Exception error) { throw new RuntimeException(error); }
            });
            VoWLANPCMRelay old = new VoWLANPCMRelay(new Context());
            int port = old.start(loopback, 0, new InetSocketAddress(loopback, 7580));
            try (Socket peer = authenticatedPeer(loopback, port)) {
                if (!firstAccepted.await(2, TimeUnit.SECONDS)) throw new AssertionError("shell never accepted");
                old.close();
                peer.setSoTimeout(1_000);
                if (peer.getInputStream().read() != -1) throw new AssertionError("old peer remained open");
            } finally { old.close(); }
            // Exercise the process-global gate across two real relay instances.
            VoWLANPCMRelay next = new VoWLANPCMRelay(new Context());
            int nextPort = next.start(loopback, 0, new InetSocketAddress(loopback, 7580));
            Socket peer = null;
            Call owned = new Call(Call.STATE_ACTIVE);
            Call unrelated = new Call(Call.STATE_RINGING);
            String ownedID = CallRepository.add(owned);
            CallRepository.add(unrelated);
            try {
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                do {
                    if (peer != null) peer.close();
                    peer = authenticatedPeer(loopback, nextPort);
                    peer.setSoTimeout(1_000);
                    if (VoWLANPCMProtocol.acceptReady(peer.getInputStream())) break;
                    Thread.sleep(20);
                } while (System.nanoTime() < deadline);
                DirectCallOwnership.record("127.0.0.1", ownedID);
                byte[] microphone = new byte[320];
                for (int i = 0; i < microphone.length; i++) microphone[i] = (byte)(i * 31 + 7);
                peer.getOutputStream().write(microphone);
                byte[] downlink = new byte[320];
                new java.io.DataInputStream(peer.getInputStream()).readFully(downlink);
                if (!java.util.Arrays.equals(microphone, downlink)) {
                    throw new AssertionError("duplex iPhone PCM was altered by Android isolation");
                }
                peer.close();
                deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                while (owned.getState() != Call.STATE_DISCONNECTED && System.nanoTime() < deadline) Thread.sleep(10);
                if (owned.getState() != Call.STATE_DISCONNECTED) throw new AssertionError("proxy loss left carrier call active");
                if (unrelated.getState() != Call.STATE_RINGING) throw new AssertionError("proxy loss ended unrelated call");
            } finally {
                if (peer != null) peer.close();
                next.close();
                DirectCallOwnership.end(DirectCallOwnership.capture("127.0.0.1"), false);
                CallRepository.remove(owned);
                CallRepository.remove(unrelated);
            }
            backend.get(3, TimeUnit.SECONDS);
        } finally { worker.shutdownNow(); }
        System.out.println("Direct PCM integration passed: stalled handshake cleanup, global gate recovery, scoped proxy-loss hangup");
    }

    private static void earlyCaptureRecoversWithoutChangingCarrierPCM() throws Exception {
        Inet4Address loopback = (Inet4Address) InetAddress.getByName("127.0.0.1");
        ExecutorService worker = Executors.newSingleThreadExecutor();
        Call call = new Call(Call.STATE_DIALING, Call.Details.DIRECTION_OUTGOING, "10086");
        String callID = CallRepository.add(call);
        long now = System.currentTimeMillis() / 1000;
        String session = UUID.randomUUID().toString();
        var lease = new EarlyMediaSessions.Lease("test-pairing", "test-agent", "test-backend", callID,
                session, now + 120, now + 25);
        var field = EarlyMediaSessions.class.getDeclaredField("leases");
        field.setAccessible(true);
        @SuppressWarnings("unchecked")
        var leases = (java.util.Map<String, EarlyMediaSessions.Lease>) field.get(null);
        leases.put("test-pairing\ntest-backend", lease);
        byte[] expected = new byte[320];
        for (int i = 0; i < expected.length; i++) expected[i] = (byte)(i * 17 + 1);
        try (ServerSocket shell = new ServerSocket(7580, 4, loopback);
             VoWLANPCMRelay relay = new VoWLANPCMRelay(new Context())) {
            Future<?> backend = worker.submit(() -> {
                try {
                    try (Socket stalled = shell.accept()) {
                        acceptBridgeHello(stalled, true);
                        stalled.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
                        while (stalled.getInputStream().read() >= 0) {}
                    }
                    try (Socket silent = shell.accept()) {
                        acceptBridgeHello(silent, true);
                        silent.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
                        byte[] zero = new byte[320];
                        try {
                            while (true) { silent.getOutputStream().write(zero); Thread.sleep(20); }
                        } catch (java.io.IOException closedForRecovery) {}
                    }
                    try (Socket audible = shell.accept()) {
                        acceptBridgeHello(audible, true);
                        audible.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
                        audible.getOutputStream().write(expected);
                        while (audible.getInputStream().read() >= 0) {}
                    }
                } catch (Exception error) { throw new RuntimeException(error); }
            });
            int port = relay.start(loopback, 0, new InetSocketAddress(loopback, 7580));
            try (Socket peer = new Socket(loopback, port)) {
                peer.setSoTimeout(12_000);
                String binding = "test-agent\ntest-backend\n" + session + "\n" + (now + 25)
                        + "\nrecvonly\ns16le-8000-mono";
                String nonce = UUID.randomUUID().toString();
                String signed = VoWLANAuth.sign(new byte[32],
                        VoWLANAuth.canonicalRequest("PCM", "/v1/pcm/early-media",
                                binding.getBytes(StandardCharsets.UTF_8), now, nonce));
                String preface = "AIRSIMEM1 " + now + " " + nonce + " " + signed + " "
                        + java.util.Base64.getEncoder().encodeToString(binding.getBytes(StandardCharsets.UTF_8)) + "\n";
                peer.getOutputStream().write(preface.getBytes(StandardCharsets.US_ASCII));
                if (!VoWLANPCMProtocol.acceptReady(peer.getInputStream())) throw new AssertionError("early handshake failed");
                if (!callID.equals(RemoteAudioSessionRegistry.reserved)) throw new AssertionError("early handshake did not reserve isolation");
                byte[] received = new byte[320];
                new java.io.DataInputStream(peer.getInputStream()).readFully(received);
                if (!java.util.Arrays.equals(expected, received)) throw new AssertionError("carrier PCM was altered or silence was forwarded");
                if (call.getState() != Call.STATE_DIALING) throw new AssertionError("early playback answered or ended the call");
                call.setStateForTest(Call.STATE_ACTIVE);
                peer.setSoTimeout(2_000);
                if (peer.getInputStream().read() != -1) throw new AssertionError("early stream survived answer");
            }
            backend.get(3, TimeUnit.SECONDS);
        } finally {
            worker.shutdownNow();
            CallRepository.remove(call);
            leases.remove("test-pairing\ntest-backend");
        }
        int retries = 0;
        while (EarlyMediaSessions.retryCapture(lease)) retries++;
        if (retries > 3 || EarlyMediaSessions.captureAvailable(lease)) throw new AssertionError("capture retries were not bounded");
        System.out.println("Early media integration passed: authenticated isolation, stalled and silent capture recovery, exact PCM, answer revocation");
    }

    private static void acceptBridgeHello(Socket socket, boolean receiveOnly) throws Exception {
        // Exercise the production shell-bridge parser across the real TCP connection.
        var protocol = Class.forName("com.airsim.bridge.BridgeProtocol");
        var read = protocol.getDeclaredMethod("readReceiveOnlyHello", java.io.InputStream.class);
        read.setAccessible(true);
        boolean actual = (boolean) read.invoke(null, socket.getInputStream());
        if (actual != receiveOnly) throw new AssertionError("unexpected PCM direction");
    }

    private static Socket authenticatedPeer(Inet4Address host, int port) throws Exception {
        Socket peer = new Socket(host, port);
        long now = System.currentTimeMillis() / 1000;
        String nonce = UUID.randomUUID().toString();
        String signature = VoWLANAuth.sign(new byte[32], VoWLANAuth.canonicalRequest("PCM", "/v1/pcm", new byte[0], now, nonce));
        peer.getOutputStream().write(("AIRSIMVWL1 " + now + " " + nonce + " " + signature + "\n").getBytes(StandardCharsets.US_ASCII));
        peer.getOutputStream().flush();
        return peer;
    }
}
