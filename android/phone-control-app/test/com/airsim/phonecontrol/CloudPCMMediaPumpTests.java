package com.airsim.phonecontrol;

import java.io.ByteArrayOutputStream;
import java.io.PipedInputStream;
import java.io.PipedOutputStream;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

public final class CloudPCMMediaPumpTests {
    public static void main(String[] args) throws Exception {
        ExecutorService workers = Executors.newCachedThreadPool();
        PipedInputStream capture = new PipedInputStream(64 * 1024);
        PipedOutputStream source = new PipedOutputStream(capture);
        CountDownLatch sending = new CountDownLatch(1), release = new CountDownLatch(1);
        CountDownLatch played = new CountDownLatch(1);
        CountDownLatch disconnected = new CountDownLatch(1);
        AtomicReference<Exception> failure = new AtomicReference<>();
        ByteArrayOutputStream playback = new ByteArrayOutputStream() {
            @Override public synchronized void write(byte[] data, int offset, int length) {
                super.write(data, offset, length); played.countDown();
            }
        };
        CloudPCMMediaPump pump = new CloudPCMMediaPump(capture, playback, frame -> {
            sending.countDown(); release.await();
        }, error -> { failure.set(error); disconnected.countDown(); }, workers);
        try {
            pump.start();
            source.write(new byte[320]); source.flush();
            check(sending.await(2, TimeUnit.SECONDS), "capture reaches independent sender");
            source.write(new byte[320 * 100]); source.flush();
            for (int i = 0; i < 4; i++) pump.receive(new byte[320]);
            check(played.await(2, TimeUnit.SECONDS), "blocked network send cannot block playback/control receive");
            check(pump.pendingCaptureFrames() <= 12, "capture backlog stays bounded during blocked network");
            check(failure.get() == null, "short send stall is not an immediate disconnect");
            check(disconnected.await(3, TimeUnit.SECONDS), "persistent blocked write closes its own connection");
            check(failure.get() instanceof java.io.IOException, "watchdog reports a recoverable IO failure");
        } finally {
            pump.close(); release.countDown(); source.close(); workers.shutdownNow();
            workers.awaitTermination(2, TimeUnit.SECONDS);
        }
        int before = playback.size();
        pump.receive(new byte[320 * 12]);
        check(playback.size() == before, "closed old stream must not accept PCM into another session");
        System.out.println("CloudPCMMediaPumpTests passed (synthetic PCM only)");
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
