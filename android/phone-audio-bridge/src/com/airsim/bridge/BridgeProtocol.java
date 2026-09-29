package com.airsim.bridge;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

final class BridgeProtocol {
    static final int FRAME_BYTES = 320;
    static final byte[] CLIENT_HELLO = "DJ1PCM1\n".getBytes(StandardCharsets.US_ASCII);
    static final byte[] SERVER_READY = "DJ1READY".getBytes(StandardCharsets.US_ASCII);

    private BridgeProtocol() {}

    static void acceptHandshake(InputStream input, OutputStream output) throws IOException {
        byte[] hello = new byte[CLIENT_HELLO.length];
        int offset = 0;
        while (offset < hello.length) {
            int count = input.read(hello, offset, hello.length - offset);
            if (count < 0) {
                throw new IllegalArgumentException("incomplete PCM handshake");
            }
            if (count == 0) {
                continue;
            }
            offset += count;
        }
        if (!Arrays.equals(hello, CLIENT_HELLO)) {
            throw new IllegalArgumentException("invalid PCM handshake");
        }
        output.write(SERVER_READY);
        output.flush();
    }
}
