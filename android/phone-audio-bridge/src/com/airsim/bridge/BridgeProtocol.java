package com.airsim.bridge;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

final class BridgeProtocol {
    static final int FRAME_BYTES = 320;
    static final byte[] CLIENT_HELLO = "AIRSIMPCM1\n".getBytes(StandardCharsets.US_ASCII);
    static final byte[] SERVER_READY = "AIRSIMREADY".getBytes(StandardCharsets.US_ASCII);

    private BridgeProtocol() {}

    /** A liveness probe connected and closed without speaking PCM. Not a failure. */
    static final class ProbeClosed extends IOException {
        ProbeClosed() { super("client closed before PCM handshake"); }
    }

    static void acceptHandshake(InputStream input, OutputStream output) throws IOException {
        acceptHandshake(input, output, () -> {});
    }

    interface AudioStartup { void start() throws IOException; }

    static void acceptHandshake(InputStream input, OutputStream output, AudioStartup startup) throws IOException {
        readHello(input);
        startup.start();
        writeReady(output);
    }

    /** Validate the client hello before creating AudioRecord/AudioTrack. */
    static void readHello(InputStream input) throws IOException {
        byte[] hello = new byte[CLIENT_HELLO.length];
        int offset = 0;
        while (offset < hello.length) {
            int count = input.read(hello, offset, hello.length - offset);
            if (count < 0) throw new ProbeClosed();
            if (count == 0) continue;
            offset += count;
        }
        if (!Arrays.equals(hello, CLIENT_HELLO)) {
            throw new IllegalArgumentException("invalid PCM handshake");
        }
    }

    static boolean readReceiveOnlyHello(InputStream input) throws IOException {
        byte[] hello = new byte[CLIENT_HELLO.length];
        int first = input.read();
        if (first < 0) throw new ProbeClosed();
        hello[0] = (byte) first;
        new java.io.DataInputStream(input).readFully(hello, 1, hello.length - 1);
        if (Arrays.equals(hello, CLIENT_HELLO)) return false;
        if (Arrays.equals(hello, "AIRSIMEM01\n".getBytes(StandardCharsets.US_ASCII))) return true;
        throw new IllegalArgumentException("invalid PCM handshake");
    }

    static void writeReady(OutputStream output) throws IOException {
        output.write(SERVER_READY);
        output.flush();
    }
}
