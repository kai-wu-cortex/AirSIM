package com.airsim.phonecontrol;

import android.content.Context;

import java.io.BufferedInputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public final class VoWLANPCMRelay implements Closeable {
    private final Context context;
    private static final VoWLANReplayCache replayCache = new VoWLANReplayCache(30);
    private static final VoWLANPCMProtocol.SessionGate gate = new VoWLANPCMProtocol.SessionGate();
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private volatile ServerSocket server;
    private volatile InetSocketAddress shellPCM;
    private volatile boolean activeSession;
    private final java.util.Set<Socket> sockets = java.util.concurrent.ConcurrentHashMap.newKeySet();

    public VoWLANPCMRelay(Context context) {
        this.context = context.getApplicationContext();
    }

    public synchronized int start(Inet4Address hotspot, int port, InetSocketAddress internal) throws IOException {
        if (server != null) return server.getLocalPort();
        if (internal.getPort() != 7580 || internal.getAddress() == null
                || !(internal.getAddress().isSiteLocalAddress() || internal.getAddress().isLoopbackAddress())) {
            throw new IllegalArgumentException("shell PCM must be loopback or AVF-private port 7580");
        }
        ServerSocket created = VoWLANPortBinder.bind(hotspot, port, 2);
        shellPCM = internal;
        server = created;
        workers.execute(() -> acceptLoop(created));
        BridgeLog.info("vowlan_pcm_listening port=" + created.getLocalPort());
        return created.getLocalPort();
    }

    public int localPort() { return server == null || server.isClosed() ? -1 : server.getLocalPort(); }

    private void acceptLoop(ServerSocket active) {
        VoWLANAcceptLoop.run(active, peer -> {
            if (track(peer)) workers.execute(() -> handle(peer));
        },
                error -> BridgeLog.error("vowlan_pcm_accept_failed", error));
    }

    private void handle(Socket peer) {
        String owner = UUID.randomUUID().toString();
        boolean proxied = peer.getLocalAddress().isLoopbackAddress();
        boolean acquired = false;
        Socket internal = null;
        DirectCallOwnership.Lease callLease = null;
        PCMStats uplink = new PCMStats();
        PCMStats downlink = new PCMStats();
        try (peer) {
            peer.setSoTimeout(5_000);
            if (!VoWLANNetworkPolicy.permitsPeer(peer.getInetAddress().getHostAddress(),
                    peer.getLocalAddress().getHostAddress())) {
                throw new SecurityException("private peer required");
            }
            BufferedInputStream peerInput = new BufferedInputStream(peer.getInputStream());
            String line = readLine(peerInput);
            if (line.startsWith("AIRSIMWATCH2 ")) {
                handleWatch(peer, peerInput, line, owner);
                return;
            }
            if (line.startsWith("AIRSIMEM1 ")) {
                handleEarly(peer, peerInput, line, owner);
                return;
            }
            VoWLANPCMProtocol.Preface preface = VoWLANPCMProtocol.parse(line);
            long now = System.currentTimeMillis() / 1000L;
            String canonical = VoWLANPCMProtocol.canonical(preface);
            VoWLANPairingStore.Record matched = VoWLANPairingStore.match(
                    context, preface.signature(), canonical, preface.timestamp(), now);
            if (matched == null || !replayCache.accept(preface.nonce(), now)) {
                throw new SecurityException("authentication failed");
            }
            acquired = gate.tryAcquire(owner);
            if (!acquired) throw new IllegalStateException("PCM session busy");
            callLease = DirectCallOwnership.begin(peer.getLocalAddress().getHostAddress());
            activeSession = true;
            internal = new Socket();
            if (!track(internal)) return;
            internal.connect(shellPCM, 3_000);
            internal.setSoTimeout(3_000);
            internal.setTcpNoDelay(true);
            internal.getOutputStream().write("AIRSIMPCM1\n".getBytes(StandardCharsets.US_ASCII));
            if (!VoWLANPCMProtocol.acceptReady(internal.getInputStream())) {
                throw new IOException("shell PCM handshake failed");
            }
            peer.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
            peer.getOutputStream().flush();
            DirectCallOwnership.pcmReady(callLease);
            RemoteAudioSessionRegistry.setVoWLAN(true);
            peer.setSoTimeout(0);
            internal.setSoTimeout(0);
            Socket activeInternal = internal;
            CountDownLatch finished = new CountDownLatch(2);
            workers.execute(() -> copy(peerInput, activeInternal, uplink, peer, activeInternal, finished));
            workers.execute(() -> copy(activeInternalInput(activeInternal), peer, downlink, peer, activeInternal, finished));
            finished.await();
        } catch (SecurityException error) {
            BridgeLog.info("vowlan_pcm_rejected reason=authentication");
        } catch (Exception error) {
            BridgeLog.error("vowlan_pcm_session_failed", error);
        } finally {
            closeQuietly(internal);
            sockets.remove(peer);
            if (internal != null) sockets.remove(internal);
            if (acquired) activeSession = false;
            try {
                if (acquired) RemoteAudioSessionRegistry.setVoWLAN(false);
            } finally {
                try { DirectCallOwnership.end(callLease, proxied); }
                finally { if (acquired) gate.release(owner); }
            }
            BridgeLog.info("vowlan_pcm_closed uplink_bytes=" + uplink.bytes.get()
                    + " uplink_frames=" + uplink.frames.get() + " uplink_peak=" + uplink.peak.get()
                    + " downlink_bytes=" + downlink.bytes.get() + " downlink_frames=" + downlink.frames.get()
                    + " downlink_peak=" + downlink.peak.get());
        }
    }

    private void handleEarly(Socket peer, BufferedInputStream input, String line, String owner) throws Exception {
        if (!AndroidEarlyMedia.supported(context)) throw new SecurityException("early media unsupported");
        var preface = VoWLANPCMProtocol.parseEarly(line);
        long now = System.currentTimeMillis()/1000L;
        var matched = VoWLANPairingStore.match(context, preface.signature(), VoWLANPCMProtocol.canonical(preface), preface.timestamp(), now);
        if (matched == null || !replayCache.accept(preface.nonce(), now)) throw new SecurityException("early media authentication");
        String androidID = AndroidEarlyMedia.LEASES.authorize(matched.id(), preface.binding(), now);
        if (androidID == null || CallRepository.state(androidID) != android.telecom.Call.STATE_DIALING || !gate.tryAcquire(owner)) throw new SecurityException("early media expired or busy");
        String[] binding = preface.binding().split("\n", -1);
        Socket internal = new Socket();
        java.util.concurrent.atomic.AtomicBoolean running = new java.util.concurrent.atomic.AtomicBoolean(true);
        PCMStats stats = new PCMStats();
        Object audioOwner = new Object();
        Thread guard = new Thread(() -> {
            try {
                while (running.get() && CallRepository.state(androidID) == android.telecom.Call.STATE_DIALING && AndroidEarlyMedia.LEASES.live(matched.id(), binding[1], binding[2], System.currentTimeMillis()/1000L)
                        && AndroidEarlyMedia.paired(context, matched.id())) Thread.sleep(100);
            } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
            finally { closeQuietly(peer); closeQuietly(internal); }
        }, "airsim-early-lease");
        try (internal) {
            activeSession = true;
            if (!track(internal)) return;
            guard.start();
            internal.connect(shellPCM, 3000); internal.setSoTimeout(3000); internal.setTcpNoDelay(true);
            internal.getOutputStream().write("AIRSIMRX01\n".getBytes(StandardCharsets.US_ASCII));
            if (!VoWLANPCMProtocol.acceptReady(internal.getInputStream())) throw new IOException("early capture unavailable");
            if (CallRepository.state(androidID) != android.telecom.Call.STATE_DIALING
                    || !AndroidEarlyMedia.LEASES.live(matched.id(), binding[1], binding[2], System.currentTimeMillis()/1000L)) return;
            peer.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
            peer.getOutputStream().flush(); peer.setSoTimeout(0); internal.setSoTimeout(0);
            // No uplink forwarding: even one byte from the peer revokes this channel.
            Thread rejectUplink = new Thread(() -> {
                try { input.read(); } catch (IOException ignored) {}
                finally { closeQuietly(peer); closeQuietly(internal); }
            }, "airsim-early-recvonly");
            rejectUplink.setDaemon(true); rejectUplink.start();
            RemoteCallAudioScope.SHARED.bind(audioOwner, androidID);
            RemoteAudioSessionRegistry.setVoWLAN(true);
            BridgeLog.info("vowlan_early_media_started direction=recvonly");
            copy(internal.getInputStream(), peer, stats, peer, internal, new CountDownLatch(1));
        } finally {
            running.set(false); guard.interrupt();
            closeQuietly(internal); sockets.remove(internal);
            RemoteCallAudioScope.SHARED.release(audioOwner);
            RemoteAudioSessionRegistry.setVoWLAN(false);
            activeSession = false;
            gate.release(owner);
            BridgeLog.info("vowlan_early_media_closed uplink_bytes=0 downlink_bytes=" + stats.bytes.get());
        }
    }

    private void handleWatch(Socket peer, InputStream input, String line, String owner) throws Exception {
        String[] fields = line.trim().split(" ", -1);
        if (fields.length != 5) throw new SecurityException("watch preface");
        String grant = fields[1]; long timestamp = Long.parseLong(fields[2]);
        long now = System.currentTimeMillis()/1000L;
        WatchMediaGrant entry = WatchMediaSessions.media(context, grant, now, true);
        if (entry == null) throw new SecurityException("watch grant");
        byte[] key = WatchMediaSessions.mediaKey(context, entry);
        try {
            if (fields[3].isEmpty() || !VoWLANAuth.verify(key, fields[4], WatchMediaGrant.pcmCanonical(grant, timestamp, fields[3]), timestamp, now)
                    || !replayCache.accept(fields[3], now)) throw new SecurityException("watch authentication");
        } finally { Arrays.fill(key, (byte)0); }
        if (!gate.tryAcquire(owner)) throw new IllegalStateException("PCM session busy");
        Socket internal = new Socket();
        Object scope = new Object();
        java.util.concurrent.atomic.AtomicBoolean running = new java.util.concurrent.atomic.AtomicBoolean(true);
        Thread guard = new Thread(() -> {
            try {
                while (running.get() && WatchMediaSessions.media(context, grant, System.currentTimeMillis()/1000L, false) != null)
                    Thread.sleep(100);
            } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
            finally { closeQuietly(peer); closeQuietly(internal); }
        }, "airsim-watch-grant");
        try (internal) {
            if (!track(internal)) return;
            activeSession = true;
            internal.connect(shellPCM, 3000); internal.setSoTimeout(3000); internal.setTcpNoDelay(true);
            internal.getOutputStream().write("AIRSIMPCM1\n".getBytes(StandardCharsets.US_ASCII));
            if (!VoWLANPCMProtocol.acceptReady(internal.getInputStream())
                    || WatchMediaSessions.media(context, grant, System.currentTimeMillis()/1000L, true) == null)
                throw new SecurityException("watch call no longer active");
            guard.start();
            peer.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII)); peer.getOutputStream().flush();
            peer.setSoTimeout(0); internal.setSoTimeout(0);
            RemoteCallAudioScope.SHARED.bind(scope, entry.instance);
            RemoteCallHangupGuard.ownerBound(entry.instance);
            RemoteAudioSessionRegistry.setVoWLAN(true);
            CountDownLatch finished = new CountDownLatch(2);
            workers.execute(() -> copy(input, internal, new PCMStats(), peer, internal, finished));
            workers.execute(() -> copy(activeInternalInput(internal), peer, new PCMStats(), peer, internal, finished));
            finished.await();
        } finally {
            running.set(false); guard.interrupt();
            closeQuietly(internal); sockets.remove(internal);
            RemoteCallAudioScope.SHARED.release(scope);
            RemoteCallHangupGuard.ownerLost(entry.instance);
            RemoteAudioSessionRegistry.setVoWLAN(false);
            activeSession = false; gate.release(owner);
        }
    }

    private static InputStream activeInternalInput(Socket socket) {
        try { return socket.getInputStream(); }
        catch (IOException error) { return new java.io.ByteArrayInputStream(new byte[0]); }
    }

    private static void copy(
            InputStream input, Socket destination, PCMStats stats,
            Socket peer, Socket internal, CountDownLatch finished) {
        byte[] buffer = new byte[320];
        try {
            OutputStream output = destination.getOutputStream();
            int count;
            while ((count = input.read(buffer)) >= 0) {
                if (count == 0) continue;
                output.write(buffer, 0, count);
                stats.add(buffer, count);
            }
        } catch (IOException ignored) {
        } finally {
            Arrays.fill(buffer, (byte) 0);
            closeQuietly(peer);
            closeQuietly(internal);
            finished.countDown();
        }
    }

    private static String readLine(InputStream input) throws IOException {
        byte[] bytes = new byte[4096];
        int count = 0;
        while (count < bytes.length) {
            int value = input.read();
            if (value < 0) throw new EOFException("PCM preface incomplete");
            bytes[count++] = (byte) value;
            if (value == '\n') return new String(bytes, 0, count, StandardCharsets.US_ASCII);
        }
        throw new IOException("PCM preface too large");
    }

    private static void closeQuietly(Closeable value) {
        if (value == null) return;
        try { value.close(); } catch (IOException ignored) {}
    }

    private synchronized boolean track(Socket socket) {
        if (server == null || server.isClosed()) { closeQuietly(socket); return false; }
        sockets.add(socket);
        return true;
    }

    @Override public synchronized void close() throws IOException {
        ServerSocket active = server;
        server = null;
        if (active != null) active.close();
        for (Socket socket : sockets) closeQuietly(socket);
        sockets.clear();
        workers.shutdownNow();
    }

    public boolean hasActiveSession() { return activeSession; }

    private static final class PCMStats {
        final AtomicLong bytes = new AtomicLong();
        final AtomicLong frames = new AtomicLong();
        final AtomicInteger peak = new AtomicInteger();

        void add(byte[] data, int count) {
            bytes.addAndGet(count);
            frames.addAndGet(count / 320);
            int localPeak = 0;
            for (int offset = 0; offset + 1 < count; offset += 2) {
                int bits = (data[offset] & 0xff) | ((data[offset + 1] & 0xff) << 8);
                int sample = (short) bits;
                localPeak = Math.max(localPeak, sample == Short.MIN_VALUE ? 32768 : Math.abs(sample));
            }
            peak.accumulateAndGet(localPeak, Math::max);
        }
    }
}
