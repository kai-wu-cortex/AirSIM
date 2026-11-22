package com.airsim.phonecontrol;

import java.io.Closeable;
import java.net.URI;

/** Replace only the external transport; run the real CloudSession loop. */
final class StandaloneWebSocket implements Closeable {
    record Message(int opcode, byte[] payload) {}
    interface Connect { StandaloneWebSocket run() throws Exception; }
    interface Read { Message run() throws Exception; }
    static Connect next;
    static int attempts;
    final Read reader;
    boolean closed;
    boolean failWrites;
    java.util.concurrent.CountDownLatch writeEntered, releaseWrite;
    boolean ignoreWriteInterrupt;
    StandaloneWebSocket(Read reader) { this.reader = reader; }
    static StandaloneWebSocket connect(URI target, String token) throws Exception { attempts++; return next.run(); }
    Message read() throws Exception { return reader.run(); }
    final java.util.List<String> text = new java.util.concurrent.CopyOnWriteArrayList<>();
    final java.util.concurrent.atomic.AtomicInteger frames = new java.util.concurrent.atomic.AtomicInteger();
    synchronized void writeText(String text) throws java.io.IOException {
        if (writeEntered != null) {
            writeEntered.countDown();
            while (releaseWrite.getCount() > 0) {
                try { releaseWrite.await(); }
                catch (InterruptedException error) { if (!ignoreWriteInterrupt) throw new java.io.InterruptedIOException(); }
            }
        }
        if (closed) throw new java.io.IOException("socket closed");
        if (failWrites) throw new java.io.IOException("synthetic socket failure"); this.text.add(text); }
    void writeBinary(byte[] bytes) { frames.incrementAndGet(); }
    public void close() { closed = true; if (releaseWrite != null) releaseWrite.countDown(); }
}
