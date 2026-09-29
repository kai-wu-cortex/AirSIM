package com.airsim.phonecontrol;

import android.content.Context;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class VoWLANControlGateway implements Closeable {
    private static final int MAX_HEADERS = 8_192;
    private static final int MAX_BODY = 32_768;
    private final Context context;
    private final VoWLANReplayCache replayCache = new VoWLANReplayCache(30);
    private final ExecutorService acceptor = Executors.newSingleThreadExecutor();
    private final ExecutorService clients = Executors.newCachedThreadPool();
    private volatile ServerSocket server;
    private volatile boolean ownsCall;

    public VoWLANControlGateway(Context context) {
        this.context = context.getApplicationContext();
    }

    public synchronized int start(Inet4Address address, int port) throws IOException {
        if (server != null) return server.getLocalPort();
        ServerSocket created = new ServerSocket();
        created.setReuseAddress(true);
        created.bind(new InetSocketAddress(address, port), 8);
        server = created;
        acceptor.execute(() -> acceptLoop(created));
        BridgeLog.info("vowlan_control_listening port=" + created.getLocalPort());
        return created.getLocalPort();
    }

    private void acceptLoop(ServerSocket active) {
        while (!active.isClosed()) {
            try {
                Socket peer = active.accept();
                clients.execute(() -> handle(peer));
            } catch (IOException error) {
                if (!active.isClosed()) BridgeLog.error("vowlan_control_accept_failed", error);
            }
        }
    }

    private void handle(Socket peer) {
        String[] pathForLog = {"unknown"};
        VoWLANPeerLifecycle.run(peer, () -> {
            peer.setSoTimeout(36_000);
            if (!(peer.getInetAddress().isSiteLocalAddress() || peer.getInetAddress().isLinkLocalAddress())) {
                respond(peer, 403, "{\"error\":\"private_peer_required\"}");
                return;
            }
            Request request = readRequest(peer.getInputStream());
            pathForLog[0] = request.path;
            if (!VoWLANControlPolicy.allowed(request.method, request.path)) {
                respond(peer, 404, "{\"error\":\"not_found\"}");
                return;
            }
            long timestamp = Long.parseLong(request.headers.getOrDefault("x-airsim-vowlan-timestamp", "0"));
            String nonce = request.headers.getOrDefault("x-airsim-vowlan-nonce", "");
            String signature = request.headers.getOrDefault("x-airsim-vowlan-signature", "");
            if (!"1".equals(request.headers.get("x-airsim-vowlan-version"))) {
                respond(peer, 401, "{\"error\":\"authentication_failed\"}");
                return;
            }
            byte[] secret = VoWLANPairingStore.load(context);
            try {
                String canonical = VoWLANAuth.canonicalRequest(
                        request.method, request.path, request.body, timestamp, nonce);
                long now = System.currentTimeMillis() / 1000L;
                if (!VoWLANAuth.verify(secret, signature, canonical, timestamp, now)
                        || !replayCache.accept(nonce, now)) {
                    respond(peer, 401, "{\"error\":\"authentication_failed\"}");
                    return;
                }
            } finally {
                Arrays.fill(secret, (byte) 0);
            }
            int responseStatus = 200;
            String output;
            if ("/v1/health".equals(request.path)) {
                output = "{\"ok\":true,\"transport\":\"vowlan\",\"version\":1}";
            } else {
                String body = request.body.length == 0 ? null : new String(request.body, StandardCharsets.UTF_8);
                AgentClient.ForwardResponse forwarded =
                        new AgentClient(context).forwardVoWLAN(request.method, request.path, body);
                responseStatus = forwarded.status();
                output = forwarded.payload();
                if (output.isEmpty()) output = "{}";
                if ("/api/calls/dial".equals(request.path) || "/api/calls/answer".equals(request.path)) {
                    ownsCall = true;
                } else if ("/api/calls/hangup".equals(request.path) || "/api/calls/reject".equals(request.path)) {
                    ownsCall = false;
                }
            }
            respond(peer, responseStatus, output);
            BridgeLog.info("vowlan_control_forwarded method=" + request.method + " path=" + safePath(request.path));
        }, error -> {
            if (error instanceof IllegalArgumentException) {
                respond(peer, 400, "{\"error\":\"bad_request\"}");
                return;
            }
            BridgeLog.error("vowlan_control_failed path=" + safePath(pathForLog[0]), error);
            respond(peer, 502, "{\"error\":\"agent_unavailable\"}");
        });
    }

    private static Request readRequest(InputStream raw) throws IOException {
        BufferedInputStream input = new BufferedInputStream(raw);
        ByteArrayOutputStream headerBytes = new ByteArrayOutputStream();
        int state = 0;
        while (headerBytes.size() < MAX_HEADERS) {
            int value = input.read();
            if (value < 0) throw new IOException("incomplete headers");
            headerBytes.write(value);
            state = state == 0 && value == '\r' ? 1
                    : state == 1 && value == '\n' ? 2
                    : state == 2 && value == '\r' ? 3
                    : state == 3 && value == '\n' ? 4 : 0;
            if (state == 4) break;
        }
        if (state != 4) throw new IOException("headers too large");
        String[] lines = headerBytes.toString(StandardCharsets.US_ASCII).split("\\r\\n");
        String[] first = lines[0].split(" ", 3);
        if (first.length != 3 || !first[2].startsWith("HTTP/1.")) throw new IOException("invalid request line");
        Map<String, String> headers = new HashMap<>();
        for (int index = 1; index < lines.length; index++) {
            int colon = lines[index].indexOf(':');
            if (colon > 0) headers.put(lines[index].substring(0, colon).trim().toLowerCase(Locale.ROOT),
                    lines[index].substring(colon + 1).trim());
        }
        int length;
        try { length = Integer.parseInt(headers.getOrDefault("content-length", "0")); }
        catch (NumberFormatException error) { throw new IOException("invalid content length", error); }
        if (length < 0 || length > MAX_BODY) throw new IOException("body too large");
        byte[] body = input.readNBytes(length);
        if (body.length != length) throw new IOException("incomplete body");
        return new Request(first[0].toUpperCase(Locale.ROOT), first[1], headers, body);
    }

    private static void respond(Socket peer, int status, String json) throws IOException {
        if (peer.isClosed()) return;
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        String reason = status == 200 ? "OK" : "Error";
        byte[] headers = ("HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: application/json\r\n" +
                "Content-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
        OutputStream output = peer.getOutputStream();
        output.write(headers);
        output.write(body);
        output.flush();
    }

    private static String safePath(String path) {
        if (path == null) return "unknown";
        int query = path.indexOf('?');
        return query < 0 ? path : path.substring(0, query);
    }

    @Override public synchronized void close() throws IOException {
        ServerSocket active = server;
        server = null;
        if (active != null) active.close();
        acceptor.shutdownNow();
        clients.shutdownNow();
    }

    public boolean ownsCall() { return ownsCall; }

    private record Request(String method, String path, Map<String, String> headers, byte[] body) {}
}
