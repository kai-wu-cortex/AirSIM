package com.airsim.phonecontrol;

import android.content.Context;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.DataInputStream;
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
    private static final VoWLANReplayCache replayCache = new VoWLANReplayCache(30);
    private final ExecutorService acceptor = Executors.newSingleThreadExecutor();
    private final ExecutorService clients = Executors.newCachedThreadPool();
    private volatile ServerSocket server;
    private volatile boolean ownsCall;

    public VoWLANControlGateway(Context context) {
        this.context = context.getApplicationContext();
    }

    public synchronized int start(Inet4Address address, int port) throws IOException {
        if (server != null) return server.getLocalPort();
        ServerSocket created = VoWLANPortBinder.bind(address, port, 8);
        server = created;
        acceptor.execute(() -> acceptLoop(created));
        BridgeLog.info("vowlan_control_listening port=" + created.getLocalPort());
        return created.getLocalPort();
    }

    public int localPort() { return server == null || server.isClosed() ? -1 : server.getLocalPort(); }

    private void acceptLoop(ServerSocket active) {
        VoWLANAcceptLoop.run(active, peer -> clients.execute(() -> handle(peer)),
                error -> BridgeLog.error("vowlan_control_accept_failed", error));
    }

    private void handle(Socket peer) {
        String[] pathForLog = {"unknown"};
        VoWLANPeerLifecycle.run(peer, () -> {
            peer.setSoTimeout(75_000);
            if (!VoWLANNetworkPolicy.permitsPeer(peer.getInetAddress().getHostAddress(),
                    peer.getLocalAddress().getHostAddress())) {
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
            String canonical = VoWLANAuth.canonicalRequest(
                    request.method, request.path, request.body, timestamp, nonce);
            long now = System.currentTimeMillis() / 1000L;
            VoWLANPairingStore.Record matched = VoWLANPairingStore.match(
                    context, signature, canonical, timestamp, now);
            if (matched == null || !replayCache.accept(nonce, now)) {
                respond(peer, 401, "{\"error\":\"authentication_failed\"}");
                return;
            }
            if (request.path.equals("/api/calls/early-media") || request.path.startsWith("/api/calls/early-media?")) {
                if (!AndroidEarlyMedia.supported(context)) { BridgeLog.info("vowlan_early_media_probe result=unsupported"); respond(peer, 404, "{}"); return; }
                String query = new java.net.URI(request.path).getRawQuery();
                if (query == null || !query.startsWith("call_id=") || query.contains("&")) { respond(peer, 400, "{}"); return; }
                String id = java.net.URLDecoder.decode(query.substring(8), "UTF-8");
                var grant = AndroidEarlyMedia.LEASES.grant(matched.id(), id, now);
                if (grant == null) { BridgeLog.info("vowlan_early_media_probe result=revoked"); respond(peer, 410, "{}"); return; }
                String androidID = AndroidEarlyMedia.LEASES.authorize(matched.id(), grant.binding(), now);
                if (CallRepository.state(androidID) != android.telecom.Call.STATE_DIALING
                        || !ShizukuBridgeManager.get(context).bridgeRunning()) { BridgeLog.info("vowlan_early_media_probe result=pending"); respond(peer, 202, "{}"); return; }
                byte[] secret = matched.secretCopy();
                try { respond(peer, 200, AndroidEarlyMedia.response(grant, nonce, secret)); BridgeLog.info("vowlan_early_media_probe result=ready"); }
                finally { Arrays.fill(secret, (byte) 0); }
                return;
            }
            if ("/api/local-mode".equals(request.path)) {
                byte[] statusSecret = matched.secretCopy();
                try {
                    PureLocalModeRuntime runtime = PureLocalModeRuntime.get(context);
                    PureLocalModeCoordinator.Status status;
                    if ("GET".equals(request.method)) {
                        status = runtime.status();
                    } else {
                        status = runtime.apply(PureLocalModeWire.command(new org.json.JSONObject(
                                new String(request.body, StandardCharsets.UTF_8))), "wlan:" + matched.id());
                    }
                    respond(peer, 200, PureLocalModeWire.signedStatus(status, nonce, statusSecret).toString());
                } catch (PureLocalModePolicy.Rejected rejected) {
                    String code = rejected.getMessage();
                    int status = "unauthenticated".equals(code) ? 401
                            : "storage_corrupt".equals(code) ? 503 : 409;
                    respond(peer, status, new org.json.JSONObject().put("error", code).toString());
                } catch (IOException unavailable) {
                    respond(peer, 503, "{\"error\":\"agent_pending\"}");
                } finally {
                    Arrays.fill(statusSecret, (byte) 0);
                }
                return;
            }
            String identityProof = null;
            byte[] requestSecret = matched.secretCopy();
            try {
                if ("/v1/health".equals(request.path)) {
                    identityProof = DirectGatewayRoutes.healthProof(
                            requestSecret, nonce, AndroidAgentIdentity.agentID(context));
                }
            } finally {
                Arrays.fill(requestSecret, (byte) 0);
            }
            int responseStatus = 200;
            String output;
            if ("/v1/health".equals(request.path)) {
                output = new org.json.JSONObject()
                        .put("ok", true).put("transport", "vowlan").put("version", 1)
                        .put("agent_id", AndroidAgentIdentity.agentID(context))
                        .put("identity_proof", identityProof)
                        .put("canonical_call_ids", canonicalCallIDsSupported())
                        .put("agent_kind", RuntimeMode.isStandalone(context) ? "standalone" : "avf")
                        .put("device_name", AndroidAgentIdentity.deviceName())
                        .put("manufacturer", android.os.Build.MANUFACTURER)
                        .put("model", android.os.Build.MODEL)
                        .put("phone_number", AndroidAgentIdentity.phoneNumber(context))
                        .put("sim_slots", SimSlotJson.slots(context))
                        .put("battery", AndroidBatteryStatus.snapshot(context))
                        .toString();
            } else {
                String local = peer.getLocalAddress().getHostAddress();
                DirectCallOwnership.Lease callLease = DirectCallOwnership.capture(local);
                java.util.Set<String> before = CallRepository.callIDs();
                String answerTarget = "";
                if ("/api/calls/answer".equals(request.path)) {
                    String requested = request.body.length == 0 ? "" : new org.json.JSONObject(
                            new String(request.body, StandardCharsets.UTF_8)).optString("call_id");
                    AgentClient.ForwardResponse status = new AgentClient(context).forwardVoWLAN("GET", "/api/calls/status", null);
                    org.json.JSONObject active = new org.json.JSONObject(status.payload()).optJSONObject("active");
                    if (active != null && (requested.isEmpty() || requested.equals(active.optString("id")))) {
                        String exactID = active.optString("android_id", active.optString("id"));
                        if (CallRepository.state(exactID) == android.telecom.Call.STATE_RINGING) answerTarget = exactID;
                    }
                }
                String dialNumber = "/api/calls/dial".equals(request.path)
                        ? new org.json.JSONObject(new String(request.body, StandardCharsets.UTF_8)).optString("number") : "";
                String operationID = "/api/calls/dial".equals(request.path)
                        ? new org.json.JSONObject(new String(request.body, StandardCharsets.UTF_8)).optString("operation_id") : "";
                if (!operationID.isEmpty() && !canonicalCallIDsSupported()) {
                    respond(peer, 409, "{\"error\":\"canonical_call_ids_upgrade_required\"}");
                    return;
                }
                String body = request.body.length == 0 ? null : new String(request.body, StandardCharsets.UTF_8);
                AgentClient.ForwardResponse forwarded =
                        new AgentClient(context).forwardVoWLAN(request.method, request.path, body);
                responseStatus = forwarded.status();
                output = forwarded.payload();
                if (output.isEmpty()) output = "{}";
                ownsCall = VoWLANControlPolicy.ownsCallAfterResponse(
                        request.path, responseStatus, ownsCall);
                if (responseStatus >= 200 && responseStatus < 300) {
                    if ("/api/calls/dial".equals(request.path)) {
                        long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(2);
                        String created;
                        do {
                            created = CallRepository.newOutgoingCallSince(before, dialNumber);
                            if (!created.isEmpty()) break;
                            Thread.sleep(50);
                        } while (System.nanoTime() < deadline);
                        DirectCallOwnership.record(local, created, callLease);
                        if (!operationID.isEmpty() && !created.isEmpty()) {
                            // Telecom registration precedes the asynchronous Agent event.
                            // Pin the exact created call, then wait for its backend mapping;
                            // never return unowned success or repeat the dial command.
                            do {
                                AgentClient.ForwardResponse status = new AgentClient(context).forwardVoWLAN("GET", "/api/calls/status", null);
                                org.json.JSONObject active = new org.json.JSONObject(status.payload()).optJSONObject("active");
                                if (status.status() == 200 && active != null
                                        && created.equals(active.optString("android_id")) && !active.optString("id").isEmpty()) {
                                    String backendID = active.optString("id");
                                    if (AndroidEarlyMedia.supported(context)) AndroidEarlyMedia.LEASES.register(
                                        matched.id(), AndroidAgentIdentity.agentID(context), backendID, created);
                                    byte[] responseSecret = matched.secretCopy();
                                    try {
                                        output = new org.json.JSONObject(output).put("operation_id", operationID)
                                                .put("android_id", created).put("backend_id", backendID)
                                                .put("operation_proof", DirectGatewayRoutes.ownedDialProof(responseSecret,
                                                        nonce, operationID, created, backendID)).toString();
                                    } finally { Arrays.fill(responseSecret, (byte) 0); }
                                    break;
                                }
                                if (System.nanoTime() >= deadline) break;
                                Thread.sleep(25);
                            } while (true);
                        }
                        if (!operationID.isEmpty() && !new org.json.JSONObject(output).has("operation_proof")) {
                            // We cannot publish a safe iPhone media/control owner. Retire
                            // only the call created by this operation, not another active call.
                            CallRepository.disconnect(created);
                            DirectCallOwnership.end(callLease, false);
                            responseStatus = 504;
                            output = "{\"error\":\"owned_dial_receipt_unavailable\"}";
                            BridgeLog.info("vowlan_owned_dial_receipt_unavailable");
                        } else if (!operationID.isEmpty()) {
                            BridgeLog.info("vowlan_owned_dial_receipt_ready");
                        }
                        AirSIMInCallService.refreshAudioPolicy();
                    } else if ("/api/calls/answer".equals(request.path)
                            && CallRepository.state(answerTarget) == android.telecom.Call.STATE_ACTIVE) {
                        DirectCallOwnership.record(local, answerTarget, callLease);
                        AirSIMInCallService.refreshAudioPolicy();
                    } else if ("/api/calls/hangup".equals(request.path) || "/api/calls/reject".equals(request.path)) {
                        DirectCallOwnership.end(callLease, false);
                        AirSIMInCallService.refreshAudioPolicy();
                    }
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

    private boolean canonicalCallIDsSupported() {
        if (RuntimeMode.isStandalone(context)) return true;
        try {
            AgentClient.ForwardResponse health = new AgentClient(context).forwardVoWLAN("GET", "/api/health", null);
            return health.status() == 200 && new org.json.JSONObject(health.payload()).optBoolean("canonical_call_ids", false);
        } catch (Exception ignored) { return false; }
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
        String[] lines = new String(headerBytes.toByteArray(), StandardCharsets.US_ASCII).split("\\r\\n");
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
        byte[] body = new byte[length];
        new DataInputStream(input).readFully(body);
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
