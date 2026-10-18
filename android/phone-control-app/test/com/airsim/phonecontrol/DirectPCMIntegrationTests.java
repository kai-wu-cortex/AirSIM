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
                    ready.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
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
