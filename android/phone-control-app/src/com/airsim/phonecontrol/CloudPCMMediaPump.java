package com.airsim.phonecontrol;

import java.io.Closeable;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.LockSupport;

final class CloudPCMMediaPump implements Closeable {
    interface Sender { void send(byte[] frame) throws Exception; }
    interface Failure { void failed(Exception error); }
    private final InputStream capture;
    private final OutputStream playback;
    private final Sender sender;
    private final Failure failure;
    private final Executor executor;
    private final CloudPCMAudioQueue outgoing = new CloudPCMAudioQueue(false);
    private final CloudPCMAudioQueue incoming = new CloudPCMAudioQueue(true);
    private final AtomicBoolean running = new AtomicBoolean(true);
    private final AtomicBoolean started = new AtomicBoolean();
    private volatile long sendingSince, playingSince;

    CloudPCMMediaPump(InputStream capture, OutputStream playback, Sender sender,
                      Failure failure, Executor executor) {
        this.capture = capture; this.playback = playback; this.sender = sender;
        this.failure = failure; this.executor = executor;
    }
    void start() {
        if (!running.get() || !started.compareAndSet(false, true)) return;
        executor.execute(this::capture);
        executor.execute(() -> paced(true));
        executor.execute(() -> paced(false));
        executor.execute(this::watchdog);
    }
    void receive(byte[] pcm) {
        if (!running.get() || pcm.length == 0 || pcm.length % 320 != 0) return;
        long now = nowMillis();
        for (int offset = 0; offset < pcm.length; offset += 320) {
            incoming.offer(java.util.Arrays.copyOfRange(pcm, offset, offset + 320), now);
        }
    }
    private void capture() {
        byte[] frame = new byte[320];
        int offset = 0;
        try {
            while (running.get()) {
                int count = capture.read(frame, offset, frame.length - offset);
                if (count < 0) throw new EOFException("Cloud PCM capture closed");
                offset += count;
                if (offset == frame.length) {
                    outgoing.offer(frame, nowMillis());
                    offset = 0;
                }
            }
        } catch (Exception error) { fail(error); }
    }
    private void paced(boolean network) {
        long tick = System.nanoTime();
        try {
            while (running.get() && !Thread.currentThread().isInterrupted()) {
                byte[] frame = (network ? outgoing : incoming).poll(nowMillis());
                if (frame != null && running.get()) {
                    if (network) {
                        sendingSince = System.nanoTime();
                        try { sender.send(frame); } finally { sendingSince = 0; }
                    } else {
                        playingSince = System.nanoTime();
                        try { playback.write(frame); } finally { playingSince = 0; }
                    }
                }
                tick = CloudPCMAudioQueue.nextTickNanos(tick, System.nanoTime());
                LockSupport.parkNanos(Math.max(0, tick - System.nanoTime()));
            }
        } catch (Exception error) { fail(error); }
    }
    private void watchdog() {
        long lastStats = System.nanoTime();
        while (running.get() && !Thread.currentThread().isInterrupted()) {
            long now = System.nanoTime();
            long sending = sendingSince, playing = playingSince;
            if ((sending != 0 && now - sending > 2_000_000_000L)
                    || (playing != 0 && now - playing > 2_000_000_000L)) {
                fail(new IOException("Cloud PCM write stalled"));
                return;
            }
            if (now - lastStats >= 5_000_000_000L) {
                BridgeLog.info("cloud_pcm_quality tx_queue=" + outgoing.size()
                        + " tx_drop=" + outgoing.droppedFrames() + " rx_queue=" + incoming.size()
                        + " rx_target_ms=" + incoming.targetFrames() * 20
                        + " rx_drop=" + incoming.droppedFrames() + " underruns=" + incoming.underruns()
                        + " concealed=" + incoming.concealedFrames());
                lastStats = now;
            }
            LockSupport.parkNanos(100_000_000L);
        }
    }
    private static long nowMillis() { return System.nanoTime() / 1_000_000L; }
    private void fail(Exception error) {
        if (!running.compareAndSet(true, false)) return;
        closeIO();
        failure.failed(error);
    }
    int pendingCaptureFrames() { return outgoing.size(); }
    @Override public void close() {
        if (running.getAndSet(false)) closeIO();
    }
    private void closeIO() {
        try { capture.close(); } catch (Exception ignored) {}
        try { playback.close(); } catch (Exception ignored) {}
        outgoing.clear(); incoming.clear();
    }
}
