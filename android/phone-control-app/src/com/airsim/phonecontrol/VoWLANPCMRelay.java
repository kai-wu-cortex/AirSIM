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
    private final VoWLANReplayCache replayCache = new VoWLANReplayCache(30);
    private final VoWLANPCMProtocol.SessionGate gate = new VoWLANPCMProtocol.SessionGate();
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private volatile ServerSocket server;
    private volatile InetSocketAddress shellPCM;
    private volatile boolean activeSession;

    public VoWLANPCMRelay(Context context) {
        this.context = context.getApplicationContext();
    }

    public synchronized int start(Inet4Address hotspot, int port, InetSocketAddress internal) throws IOException {
        if (server != null) return server.getLocalPort();
        if (internal.getPort() != 7580 || internal.getAddress() == null
                || !internal.getAddress().isSiteLocalAddress()) {
            throw new IllegalArgumentException("shell PCM must be AVF-private port 7580");
        }
        ServerSocket created = new ServerSocket();
        created.setReuseAddress(true);
        created.bind(new InetSocketAddress(hotspot, port), 2);
        shellPCM = internal;
        server = created;
        workers.execute(() -> acceptLoop(created));
        BridgeLog.info("vowlan_pcm_listening port=" + created.getLocalPort());
        return created.getLocalPort();
    }

    private void acceptLoop(ServerSocket active) {
        while (!active.isClosed()) {
            try {
                Socket peer = active.accept();
                workers.execute(() -> handle(peer));
            } catch (IOException error) {
                if (!active.isClosed()) BridgeLog.error("vowlan_pcm_accept_failed", error);
            }
        }
    }

    private void handle(Socket peer) {
        String owner = UUID.randomUUID().toString();
        boolean acquired = false;
        Socket internal = null;
        PCMStats uplink = new PCMStats();
        PCMStats downlink = new PCMStats();
        try (peer) {
            peer.setSoTimeout(5_000);
            if (!(peer.getInetAddress().isSiteLocalAddress() || peer.getInetAddress().isLinkLocalAddress())) {
                throw new SecurityException("private peer required");
            }
            BufferedInputStream peerInput = new BufferedInputStream(peer.getInputStream());
            String line = readLine(peerInput);
            VoWLANPCMProtocol.Preface preface = VoWLANPCMProtocol.parse(line);
            byte[] secret = VoWLANPairingStore.load(context);
            try {
                long now = System.currentTimeMillis() / 1000L;
                if (!VoWLANAuth.verify(secret, preface.signature(), VoWLANPCMProtocol.canonical(preface),
                        preface.timestamp(), now) || !replayCache.accept(preface.nonce(), now)) {
                    throw new SecurityException("authentication failed");
                }
            } finally {
                Arrays.fill(secret, (byte) 0);
            }
            acquired = gate.tryAcquire(owner);
            if (!acquired) throw new IllegalStateException("PCM session busy");
            activeSession = true;
            internal = new Socket();
            internal.connect(shellPCM, 3_000);
            internal.setTcpNoDelay(true);
            internal.getOutputStream().write("AIRSIMPCM1\n".getBytes(StandardCharsets.US_ASCII));
            if (!VoWLANPCMProtocol.acceptReady(internal.getInputStream())) {
                throw new IOException("shell PCM handshake failed");
            }
            peer.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
            peer.getOutputStream().flush();
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
            if (acquired) gate.release(owner);
            if (acquired) activeSession = false;
            BridgeLog.info("vowlan_pcm_closed uplink_bytes=" + uplink.bytes.get()
                    + " uplink_frames=" + uplink.frames.get() + " uplink_peak=" + uplink.peak.get()
                    + " downlink_bytes=" + downlink.bytes.get() + " downlink_frames=" + downlink.frames.get()
                    + " downlink_peak=" + downlink.peak.get());
        }
    }

    private static InputStream activeInternalInput(Socket socket) {
        try { return socket.getInputStream(); }
        catch (IOException error) { return InputStream.nullInputStream(); }
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
        byte[] bytes = new byte[1024];
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

    @Override public synchronized void close() throws IOException {
        ServerSocket active = server;
        server = null;
        if (active != null) active.close();
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
