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
            boolean watch = "1".equals(request.headers.get("x-airsim-watch-control"));
            String watchCallID = null;
            if (watch) {
                if ("GET".equals(request.method)) {
                    watchCallID = android.net.Uri.parse(request.path).getQueryParameter("call_id");
                } else {
                    watchCallID = new org.json.JSONObject(
                            new String(request.body, StandardCharsets.UTF_8)).optString("call_id");
                }
                if (!VoWLANControlPolicy.watchAllowed(request.method, request.path, watchCallID)) {
                    respond(peer, 403, "{\"error\":\"watch_scope_forbidden\"}");
                    return;
                }
            }
            VoWLANPairingStore.Record matched = watch
                    ? VoWLANPairingStore.matchWatch(context, signature, canonical, timestamp, now)
                    : VoWLANPairingStore.match(context, signature, canonical, timestamp, now);
            if (matched == null || !replayCache.accept(nonce, now)) {
                respond(peer, 401, "{\"error\":\"authentication_failed\"}");
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
            if ("/api/calls/early-media".equals(request.path.split("[?]", 2)[0])) {
                String call = android.net.Uri.parse(request.path).getQueryParameter("call_id");
                byte[] secret = matched.secretCopy();
                try {
                    var grant = EarlyMediaSessions.grant(context, matched.id(), call == null ? "" : call, nonce, secret);
                    respond(peer, grant == null ? 410 : 200,
                        grant == null ? "{\"error\":\"early_media_revoked\"}" : grant.toString());
                } finally { Arrays.fill(secret, (byte) 0); }
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
                String watchBackendID = null;
                if ("/api/calls/answer".equals(request.path) || (watch && "POST".equals(request.method))) {
                    String requested = request.body.length == 0 ? "" : new org.json.JSONObject(
                            new String(request.body, StandardCharsets.UTF_8)).optString("call_id");
                    AgentClient.ForwardResponse status = new AgentClient(context).forwardVoWLAN("GET", "/api/calls/status", null);
                    org.json.JSONObject active = new org.json.JSONObject(status.payload()).optJSONObject("active");
                    if (active != null && (requested.isEmpty() || requested.equals(active.optString("id"))
                            || (watch && watchMatchesCall(active, requested)))) {
                        String exactID = active.optString("android_id", active.optString("id"));
                        if (CallRepository.state(exactID) == android.telecom.Call.STATE_RINGING) answerTarget = exactID;
                        if (watch) watchBackendID = active.optString("id");
                    }
                }
                if (watch && "POST".equals(request.method)
                        && (watchBackendID == null || watchBackendID.isEmpty()
                            || ("/api/calls/answer".equals(request.path) && answerTarget.isEmpty()))) {
                    respond(peer, 409, "{\"error\":\"watch_call_state_changed\"}");
                    return;
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
                if (watchBackendID != null) body = new org.json.JSONObject().put("call_id", watchBackendID).toString();
                AgentClient.ForwardResponse forwarded =
                        new AgentClient(context).forwardVoWLAN(request.method,
                                watch && "GET".equals(request.method) ? "/api/calls/status" : request.path, body);
                responseStatus = forwarded.status();
                output = forwarded.payload();
                if (output.isEmpty()) output = "{}";
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
            if (watch) {
                String state = "";
                if ("GET".equals(request.method) && responseStatus == 200) {
                    org.json.JSONObject snapshot = new org.json.JSONObject(output);
                    org.json.JSONObject active = snapshot.optJSONObject("active");
                    if (active != null && watchMatchesCall(active, watchCallID)) {
                        state = active.optString("state");
                    } else {
                        org.json.JSONArray history = snapshot.optJSONArray("history");
                        for (int i = 0; history != null && i < history.length(); i++) {
                            org.json.JSONObject call = history.optJSONObject(i);
                            if (call != null && watchMatchesCall(call, watchCallID)) {
                                state = call.optString("state");
                                break;
                            }
                        }
                    }
                }
                byte[] root = matched.secretCopy();
                byte[] key = VoWLANAuth.watchCallKey(root);
                try {
                    String proof = VoWLANAuth.sign(key, "watch-response\n" + nonce + "\n" + watchCallID
                            + "\n" + responseStatus + "\n" + state);
                    output = new org.json.JSONObject().put("state", state).put("proof", proof).toString();
                } finally {
                    Arrays.fill(root, (byte) 0);
                    Arrays.fill(key, (byte) 0);
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

    private static boolean watchMatchesCall(org.json.JSONObject record, String id) {
        return id.equals(record.optString("id")) || id.equals(record.optString("android_id"));
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

    public boolean ownsCall() {
        ServerSocket current = server;
        return current != null && !current.isClosed()
                && DirectCallOwnership.ownsLiveCall(current.getInetAddress().getHostAddress());
    }

    private record Request(String method, String path, Map<String, String> headers, byte[] body) {}
}
