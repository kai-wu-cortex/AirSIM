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
    StandaloneWebSocket(Read reader) { this.reader = reader; }
    static StandaloneWebSocket connect(URI target, String token) throws Exception { attempts++; return next.run(); }
    Message read() throws Exception { return reader.run(); }
    void writeText(String text) {}
    void writeBinary(byte[] bytes) {}
    public void close() { closed = true; }
}
