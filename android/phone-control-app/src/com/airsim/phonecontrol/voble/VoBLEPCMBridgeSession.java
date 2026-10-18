package com.airsim.phonecontrol.voble;

import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Authenticates the local/AVF PCM bridge before exposing either audio direction. */
public final class VoBLEPCMBridgeSession implements Closeable {
    private static final byte[] HELLO = "AIRSIMPCM1\n".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] READY = "AIRSIMREADY".getBytes(StandardCharsets.US_ASCII);

    public interface Duplex extends Closeable {
        InputStream input() throws IOException;
        OutputStream output() throws IOException;
    }

    public interface Connector { Duplex connect(InetSocketAddress endpoint) throws IOException; }

    private final Duplex duplex;
    private final InputStream input;
    private final OutputStream output;
    private volatile boolean ready;

    private VoBLEPCMBridgeSession(Duplex duplex, InputStream input, OutputStream output) {
        this.duplex = duplex;
        this.input = input;
        this.output = output;
        ready = true;
    }

    public static VoBLEPCMBridgeSession open(InetSocketAddress endpoint, Connector connector)
            throws IOException {
        if (endpoint == null || connector == null) throw new IOException("PCM endpoint is unavailable");
        Duplex duplex = connector.connect(endpoint);
        try {
            InputStream input = duplex.input();
            OutputStream output = duplex.output();
            output.write(HELLO);
            output.flush();
            byte[] response = readExactly(input, READY.length);
            if (!Arrays.equals(response, READY)) throw new IOException("PCM handshake failed");
            return new VoBLEPCMBridgeSession(duplex, input, output);
        } catch (IOException | RuntimeException error) {
            try { duplex.close(); } catch (IOException ignored) {}
            throw error;
        }
    }

    public static Connector socketConnector() {
        return endpoint -> {
            Socket socket = new Socket();
            socket.connect(endpoint, 3_000);
            socket.setTcpNoDelay(true);
            socket.setKeepAlive(true);
            return new Duplex() {
                @Override public InputStream input() throws IOException { return socket.getInputStream(); }
                @Override public OutputStream output() throws IOException { return socket.getOutputStream(); }
                @Override public void close() throws IOException { socket.close(); }
            };
        };
    }

    public boolean ready() { return ready; }
    public InputStream input() throws IOException {
        if (!ready) throw new IOException("PCM session is closed");
        return input;
    }
    public OutputStream output() throws IOException {
        if (!ready) throw new IOException("PCM session is closed");
        return output;
    }

    @Override public void close() throws IOException {
        ready = false;
        duplex.close();
    }

    private static byte[] readExactly(InputStream input, int length) throws IOException {
        byte[] value = new byte[length];
        int offset = 0;
        while (offset < length) {
            int count = input.read(value, offset, length - offset);
            if (count < 0) throw new EOFException("PCM handshake incomplete");
            if (count > 0) offset += count;
        }
        return value;
    }
}
