package com.airsim.phonecontrol.voble;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** One authenticated call-scoped PCM/G.711 BLE media session. */
public final class VoBLEMediaSession implements Closeable {
    public record Identity(String callId, long generation) {
        public Identity {
            if (callId == null || callId.isBlank() || generation <= 0) {
                throw new IllegalArgumentException("valid call identity is required");
            }
        }
    }
    public record Encrypted(byte[] payload, byte[] authenticationTag) {
        public Encrypted {
            payload = payload.clone();
            authenticationTag = authenticationTag.clone();
        }
        @Override public byte[] payload() { return payload.clone(); }
        @Override public byte[] authenticationTag() { return authenticationTag.clone(); }
    }
    public record Stats(long downlinkFrames, long uplinkFrames, long droppedFrames) {}
    public interface BridgeFactory {
        VoBLEPCMBridgeSession open(InetSocketAddress endpoint) throws IOException;
    }
    public interface DownlinkSink { boolean offer(VoBLEProtocol.AudioPacket packet); }

    private final InetSocketAddress endpoint;
    private final BridgeFactory bridgeFactory;
    private final DownlinkSink downlink;
    private final java.util.function.Consumer<VoBLEMediaSession> onFailure;
    private VoBLEProtocol.AudioReassembler uplinkReassembler =
            new VoBLEProtocol.AudioReassembler();
    private final VoBLEAudioQueue uplinkQueue = new VoBLEAudioQueue(8);
    private final Map<Integer, Long> uplinkSequences = new HashMap<>();
    private final AtomicLong downlinkFrames = new AtomicLong();
    private final AtomicLong uplinkFrames = new AtomicLong();
    private final AtomicLong droppedFrames = new AtomicLong();
    private volatile VoBLEPCMBridgeSession bridge;
    private volatile ExecutorService pumps;
    private volatile Identity identity;
    private volatile byte[] mediaKey;
    private volatile boolean running;
    private volatile boolean downlinkDiscontinuity;

    public VoBLEMediaSession(
            InetSocketAddress endpoint, BridgeFactory bridgeFactory, DownlinkSink downlink) {
        this(endpoint, bridgeFactory, downlink, ignored -> {});
    }

    public VoBLEMediaSession(InetSocketAddress endpoint, BridgeFactory bridgeFactory,
            DownlinkSink downlink, java.util.function.Consumer<VoBLEMediaSession> onFailure) {
        this.endpoint = endpoint;
        this.bridgeFactory = bridgeFactory;
        this.downlink = downlink;
        this.onFailure = java.util.Objects.requireNonNull(onFailure);
    }

    public synchronized void start(Identity call, byte[] key) throws IOException {
        if (running && call.equals(identity)) return;
        stop();
        if (key == null || key.length != 32) throw new IOException("media key is invalid");
        VoBLEPCMBridgeSession opened = bridgeFactory.open(endpoint);
        if (!opened.ready()) {
            opened.close();
            throw new IOException("PCM bridge is not ready");
        }
        identity = call;
        mediaKey = key.clone();
        uplinkReassembler = new VoBLEProtocol.AudioReassembler();
        uplinkQueue.clear();
        uplinkSequences.clear();
        bridge = opened;
        running = true;
        pumps = Executors.newFixedThreadPool(2, runnable -> {
            Thread thread = new Thread(runnable, "airsim-voble-media");
            thread.setDaemon(true);
            return thread;
        });
        pumps.execute(this::pumpDownlink);
        pumps.execute(this::pumpUplink);
    }

    public synchronized boolean onUplinkFragment(Identity call, byte[] fragment) {
        if (!running || identity == null || !identity.equals(call)) return false;
        try {
            VoBLEProtocol.AudioPacket packet = uplinkReassembler.append(
                    fragment, System.currentTimeMillis());
            if (packet == null) return true;
            Long previous = uplinkSequences.get(packet.streamId());
            if (previous != null && Long.compareUnsigned(packet.sequence(), previous) <= 0) {
                droppedFrames.incrementAndGet();
                return false;
            }
            Encrypted encrypted = new Encrypted(packet.payload(), packet.authenticationTag());
            byte[] encoded = decrypt(encrypted, mediaKey, true, packet.streamId(),
                    packet.sequence(), packet.sampleTimestamp());
            byte[] pcm = decodeMuLaw(encoded);
            uplinkSequences.put(packet.streamId(), packet.sequence());
            uplinkQueue.offer(packet.sequence(), pcm);
            return true;
        } catch (GeneralSecurityException | IllegalArgumentException error) {
            droppedFrames.incrementAndGet();
            return false;
        }
    }

    public boolean matches(Identity call) { return running && call != null && call.equals(identity); }
    public boolean ready() { return running && bridge != null && bridge.ready(); }
    public Stats stats() {
        return new Stats(downlinkFrames.get(), uplinkFrames.get(),
                droppedFrames.get() + uplinkQueue.droppedFrames());
    }

    private void pumpDownlink() {
        long sequence = 0;
        long timestamp = 0;
        try {
            while (running) {
                byte[] pcm = readFrame(bridge.input(), 320);
                byte[] encoded = encodeMuLaw(pcm);
                long current = sequence++ & 0xffff_ffffL;
                byte[] key = keySnapshot();
                Encrypted encrypted;
                try {
                    encrypted = encrypt(encoded, key, false, 1, current, timestamp);
                } finally {
                    Arrays.fill(key, (byte) 0);
                }
                int flags = downlinkDiscontinuity ? VoBLEProtocol.FLAG_DISCONTINUITY : 0;
                VoBLEProtocol.AudioPacket packet = new VoBLEProtocol.AudioPacket(
                        flags, VoBLEProtocol.CODEC_G711_MULAW, 1, current, timestamp,
                        encrypted.payload(), encrypted.authenticationTag());
                long deadline = System.nanoTime() + 100_000_000L;
                boolean accepted = false;
                while (running && System.nanoTime() < deadline && !(accepted = downlink.offer(packet))) {
                    Thread.sleep(5);
                }
                if (accepted) {
                    downlinkFrames.incrementAndGet();
                    downlinkDiscontinuity = false;
                } else {
                    droppedFrames.incrementAndGet();
                    downlinkDiscontinuity = true;
                }
                timestamp = (timestamp + 160) & 0xffff_ffffL;
            }
        } catch (EOFException ignored) {
            stopFromPump();
        } catch (Exception error) {
            stopFromPump();
        }
    }

    private void pumpUplink() {
        try {
            while (running) {
                VoBLEAudioQueue.Frame entry = uplinkQueue.poll();
                if (entry == null) {
                    Thread.sleep(2);
                    continue;
                }
                bridge.output().write(entry.payload());
                uplinkFrames.incrementAndGet();
            }
        } catch (Exception error) {
            stopFromPump();
        }
    }

    private void stopFromPump() {
        synchronized (this) {
            if (!running) return;
            running = false;
            VoBLEPCMBridgeSession active = bridge;
            if (active != null) try { active.close(); } catch (IOException ignored) {}
        }
        // Release the exact failed owner once, outside the media lock. A surviving
        // GATT control connection must not keep Android output muted after PCM EOF.
        onFailure.accept(this);
    }

    @Override public synchronized void close() { stop(); }

    public synchronized void stop() {
        running = false;
        VoBLEPCMBridgeSession active = bridge;
        bridge = null;
        if (active != null) try { active.close(); } catch (IOException ignored) {}
        ExecutorService workers = pumps;
        pumps = null;
        if (workers != null) workers.shutdownNow();
        byte[] key = mediaKey;
        mediaKey = null;
        if (key != null) Arrays.fill(key, (byte) 0);
        identity = null;
        uplinkQueue.clear();
        uplinkSequences.clear();
    }

    private synchronized byte[] keySnapshot() throws GeneralSecurityException {
        if (!running || mediaKey == null) throw new GeneralSecurityException("media session stopped");
        return mediaKey.clone();
    }

    public static Encrypted encrypt(
            byte[] plaintext, byte[] key, boolean uplink, int streamId,
            long sequence, long timestamp) throws GeneralSecurityException {
        Cipher cipher = cipher(Cipher.ENCRYPT_MODE, key, uplink, streamId, sequence, timestamp);
        byte[] joined = cipher.doFinal(plaintext);
        return new Encrypted(
                Arrays.copyOf(joined, joined.length - VoBLEProtocol.AUTH_TAG_LENGTH),
                Arrays.copyOfRange(joined, joined.length - VoBLEProtocol.AUTH_TAG_LENGTH, joined.length));
    }

    public static byte[] decrypt(
            Encrypted encrypted, byte[] key, boolean uplink, int streamId,
            long sequence, long timestamp) throws GeneralSecurityException {
        Cipher cipher = cipher(Cipher.DECRYPT_MODE, key, uplink, streamId, sequence, timestamp);
        byte[] joined = new byte[encrypted.payload.length + encrypted.authenticationTag.length];
        System.arraycopy(encrypted.payload, 0, joined, 0, encrypted.payload.length);
        System.arraycopy(encrypted.authenticationTag, 0, joined, encrypted.payload.length,
                encrypted.authenticationTag.length);
        return cipher.doFinal(joined);
    }

    private static Cipher cipher(
            int mode, byte[] key, boolean uplink, int streamId,
            long sequence, long timestamp) throws GeneralSecurityException {
        if (key == null || key.length != 32 || (streamId & ~0xff) != 0
                || (sequence & ~0xffff_ffffL) != 0 || (timestamp & ~0xffff_ffffL) != 0) {
            throw new GeneralSecurityException("invalid media cryptography inputs");
        }
        ByteBuffer nonce = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN);
        nonce.put((byte) (uplink ? 1 : 2)).put((byte) streamId).putShort((short) 0)
                .putInt((int) timestamp).putInt((int) sequence);
        ByteBuffer aad = ByteBuffer.allocate(11).order(ByteOrder.BIG_ENDIAN);
        aad.put((byte) (uplink ? 1 : 2)).put((byte) VoBLEProtocol.CODEC_G711_MULAW)
                .put((byte) streamId).putInt((int) sequence).putInt((int) timestamp);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce.array()));
        cipher.updateAAD(aad.array());
        return cipher;
    }

    public static byte[] encodeMuLaw(byte[] pcm) {
        if (pcm == null || (pcm.length & 1) != 0) throw new IllegalArgumentException("PCM16 LE is required");
        byte[] output = new byte[pcm.length / 2];
        for (int index = 0; index < output.length; index++) {
            int sample = (short) ((pcm[index * 2] & 0xff) | (pcm[index * 2 + 1] << 8));
            output[index] = linearToMuLaw(sample);
        }
        return output;
    }

    public static byte[] decodeMuLaw(byte[] encoded) {
        if (encoded == null) throw new IllegalArgumentException("G.711 payload is required");
        byte[] output = new byte[encoded.length * 2];
        for (int index = 0; index < encoded.length; index++) {
            short sample = muLawToLinear(encoded[index]);
            output[index * 2] = (byte) sample;
            output[index * 2 + 1] = (byte) (sample >>> 8);
        }
        return output;
    }

    private static byte linearToMuLaw(int sample) {
        final int bias = 0x84;
        int sign = (sample >> 8) & 0x80;
        if (sign != 0) sample = -sample;
        sample = Math.min(32635, sample) + bias;
        int exponent = 7;
        for (int mask = 0x4000; exponent > 0 && (sample & mask) == 0; mask >>= 1) exponent--;
        int mantissa = (sample >> (exponent + 3)) & 0x0f;
        return (byte) ~(sign | (exponent << 4) | mantissa);
    }

    private static short muLawToLinear(byte value) {
        int mu = ~value & 0xff;
        int sign = mu & 0x80;
        int exponent = (mu >> 4) & 0x07;
        int mantissa = mu & 0x0f;
        int sample = ((mantissa << 3) + 0x84) << exponent;
        sample -= 0x84;
        return (short) (sign == 0 ? sample : -sample);
    }

    private static byte[] readFrame(java.io.InputStream input, int length) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(length);
        byte[] buffer = new byte[length];
        while (output.size() < length) {
            int count = input.read(buffer, 0, length - output.size());
            if (count < 0) throw new EOFException("PCM stream ended");
            if (count > 0) output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }
}
