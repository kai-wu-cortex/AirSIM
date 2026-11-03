package com.airsim.phonecontrol;

import android.util.Base64;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.InetSocketAddress;
import java.util.function.Predicate;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/** Minimal RFC 6455 client for Relay command/media sockets, with TLS hostname checks. */
final class StandaloneWebSocket implements Closeable {
    record Message(int opcode, byte[] payload) {}

    private static final String GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private static final int MAX_FRAME = 64 * 1024;
    private final SSLSocket socket;
    private final BufferedInputStream input;
    private final OutputStream output;
    private final RelayEgressGate.Lease relayLease;
    private final SecureRandom random = new SecureRandom();

    private StandaloneWebSocket(SSLSocket socket, BufferedInputStream input, OutputStream output,
                               RelayEgressGate.Lease relayLease) {
        this.socket = socket;
        this.input = input;
        this.output = output;
        this.relayLease = relayLease;
    }

    static StandaloneWebSocket connect(URI target, String bearerToken) throws Exception {
        return connect(target,bearerToken,attempt -> true,
                () -> (SSLSocket)SSLSocketFactory.getDefault().createSocket());
    }

    interface SocketFactory { SSLSocket create() throws IOException; }
    static StandaloneWebSocket connect(URI target, String bearerToken, Predicate<Closeable> owner,
                                      SocketFactory factory) throws Exception {
        if (!"wss".equalsIgnoreCase(target.getScheme()) || target.getHost() == null
                || target.getRawUserInfo() != null) throw new IllegalArgumentException("WSS 地址无效");
        int port = target.getPort() < 0 ? 443 : target.getPort();
        SSLSocket socket = factory.create();
        boolean transferred = false;
        RelayEgressGate.Lease lease = null;
        try {
        lease = RelayEgressGate.shared.acquire(socket::close);
        lease.checkCurrent();
        if (!owner.test(socket)) throw new IOException("Command connection cancelled");
        SSLParameters parameters = socket.getSSLParameters();
        parameters.setEndpointIdentificationAlgorithm("HTTPS");
        socket.setSSLParameters(parameters);
        socket.setSoTimeout(15_000);
        socket.connect(new InetSocketAddress(target.getHost(),port),8_000);
        socket.startHandshake();
        BufferedInputStream input = new BufferedInputStream(socket.getInputStream());
        OutputStream output = socket.getOutputStream();
        byte[] keyBytes = new byte[16];
        new SecureRandom().nextBytes(keyBytes);
        String key = Base64.encodeToString(keyBytes, Base64.NO_WRAP);
        String path = target.getRawPath();
        if (path == null || path.isEmpty()) path = "/";
        if (target.getRawQuery() != null && !target.getRawQuery().isEmpty()) path += "?" + target.getRawQuery();
        String host = target.getHost() + (target.getPort() < 0 ? "" : ":" + port);
        String request = "GET " + path + " HTTP/1.1\r\nHost: " + host
                + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key
                + "\r\nSec-WebSocket-Version: 13\r\n"
                + (bearerToken == null || bearerToken.isEmpty() ? "" : "Authorization: Bearer " + bearerToken + "\r\n")
                + "User-Agent: AirSIM-Standalone/0.1\r\n\r\n";
        output.write(request.getBytes(StandardCharsets.US_ASCII));
        output.flush();
        String headers = readHeaders(input);
        String[] lines = headers.split("\r\n");
        Map<String, String> values = new LinkedHashMap<>();
        for (int index = 1; index < lines.length; index++) {
            int colon = lines[index].indexOf(':');
            if (colon > 0) values.put(lines[index].substring(0, colon).trim().toLowerCase(Locale.ROOT),
                    lines[index].substring(colon + 1).trim());
        }
        if (lines.length == 0 || !lines[0].contains(" 101 ")) {
            RelayHTTPException failure = RelayHTTPException.fromHandshakeStatusLine(lines.length == 0 ? null : lines[0]);
            throw new RelayHTTPException(failure.statusCode(), "WebSocket handshake rejected",
                    RelayHTTPException.parseRetryAfter(values.get("retry-after"), System.currentTimeMillis()));
        }
        String expected = Base64.encodeToString(MessageDigest.getInstance("SHA-1")
                .digest((key + GUID).getBytes(StandardCharsets.US_ASCII)), Base64.NO_WRAP);
        if (!"websocket".equalsIgnoreCase(values.get("upgrade"))
                || !expected.equals(values.get("sec-websocket-accept"))) {
            socket.close();
            throw new IOException("WebSocket 握手校验失败");
        }
        socket.setSoTimeout(0);
        lease.checkCurrent();
        transferred = true;
        return new StandaloneWebSocket(socket, input, output, lease);
        } finally {
            if (!transferred) {
                try { socket.close(); } catch (IOException ignored) {}
                if (lease != null) lease.close();
            }
        }
    }

    Message read() throws Exception {
        while (true) {
            relayLease.checkCurrent();
            int first = input.read();
            int second = input.read();
            if (first < 0 || second < 0) throw new EOFException("WebSocket closed");
            int opcode = first & 0x0f;
            long length = second & 0x7f;
            if (length == 126) length = ((long) readByte() << 8) | readByte();
            else if (length == 127) {
                length = 0;
                for (int index = 0; index < 8; index++) length = (length << 8) | readByte();
            }
            if (length < 0 || length > MAX_FRAME) throw new IOException("WebSocket frame too large");
            byte[] mask = (second & 0x80) == 0 ? null : readExactly(4);
            byte[] payload = readExactly((int) length);
            if (mask != null) for (int index = 0; index < payload.length; index++) payload[index] ^= mask[index & 3];
            if (opcode == 9) { write(10, payload); continue; }
            if (opcode == 10) continue;
            if (opcode >= 8 && ((first & 0x80) == 0 || length > 125)) throw new IOException("Invalid control frame");
            if (opcode == 8) throw WebSocketPeerClose.decode(payload);
            if (opcode == 1 || opcode == 2) {
                relayLease.checkCurrent();
                return new Message(opcode, payload);
            }
        }
    }

    synchronized void writeText(String text) throws Exception {
        write(1, text.getBytes(StandardCharsets.UTF_8));
    }

    synchronized void writeBinary(byte[] payload) throws Exception { write(2, payload); }

    synchronized void writePing(byte[] payload) throws Exception { write(9, payload); }

    void setReadTimeout(int timeoutMillis) throws IOException { socket.setSoTimeout(timeoutMillis); }

    private void write(int opcode, byte[] payload) throws Exception {
        relayLease.checkCurrent();
        if (payload.length > MAX_FRAME) throw new IOException("WebSocket frame too large");
        ByteArrayOutputStream header = new ByteArrayOutputStream();
        header.write(0x80 | opcode);
        if (payload.length < 126) header.write(0x80 | payload.length);
        else {
            header.write(0x80 | 126);
            header.write((payload.length >>> 8) & 0xff);
            header.write(payload.length & 0xff);
        }
        byte[] mask = new byte[4];
        random.nextBytes(mask);
        header.write(mask);
        byte[] encoded = payload.clone();
        for (int index = 0; index < encoded.length; index++) encoded[index] ^= mask[index & 3];
        output.write(header.toByteArray());
        output.write(encoded);
        output.flush();
        relayLease.checkCurrent();
    }

    private static String readHeaders(InputStream input) throws IOException {
        ByteArrayOutputStream value = new ByteArrayOutputStream();
        int state = 0;
        while (value.size() < 16_384) {
            int next = input.read();
            if (next < 0) throw new EOFException("WebSocket response incomplete");
            value.write(next);
            state = state == 0 && next == '\r' ? 1 : state == 1 && next == '\n' ? 2
                    : state == 2 && next == '\r' ? 3 : state == 3 && next == '\n' ? 4 : 0;
            if (state == 4) return new String(value.toByteArray(), StandardCharsets.US_ASCII);
        }
        throw new IOException("WebSocket response headers too large");
    }

    private int readByte() throws IOException {
        int value = input.read();
        if (value < 0) throw new EOFException();
        return value;
    }

    private byte[] readExactly(int length) throws IOException {
        byte[] value = new byte[length];
        new DataInputStream(input).readFully(value);
        return value;
    }

    @Override public void close() {
        try { socket.close(); } catch (IOException ignored) {}
        finally { relayLease.close(); }
    }
}
