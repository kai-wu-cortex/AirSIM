package com.airsim.phonecontrol;

import org.json.JSONObject;

import java.io.Closeable;
import java.io.DataInputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Owns the single cloud call and bridges Relay WebSocket media to loopback Shizuku PCM. */
final class StandaloneCloudMediaManager implements Closeable {
    private static volatile StandaloneCloudMediaManager instance;

    static StandaloneCloudMediaManager get(android.content.Context context) {
        StandaloneCloudMediaManager value = instance;
        if (value == null) {
            synchronized (StandaloneCloudMediaManager.class) {
                value = instance;
                if (value == null) instance = value = new StandaloneCloudMediaManager(context);
            }
        }
        return value;
    }

    private final android.content.Context context;
    private final ExecutorService sessions = Executors.newCachedThreadPool();
    private final Object lock = new Object();
    private CloudSession active;

    private StandaloneCloudMediaManager(android.content.Context context) {
        this.context = context.getApplicationContext();
    }

    void startOutgoing(JSONObject call, CallRepository.OutgoingCallObservation observation) {
        var generation = RelayEgressGate.shared.generation();
        boolean started = false;
        try {
            if (call == null || !generation.isCurrent()) return;
            Descriptor descriptor = Descriptor.from(call);
            descriptor.outgoingObservation = observation;
            bindOutgoing(descriptor);
            start(descriptor, generation);
            started = true;
        }
        catch (Exception error) { BridgeLog.error("standalone_outgoing_media_invalid", error); }
        finally { if (!started && observation != null) observation.close(); }
    }

    private void bindOutgoing(Descriptor descriptor) {
        synchronized (descriptor) {
            if (!descriptor.androidID.isEmpty() || !"outgoing".equals(descriptor.direction)
                    || descriptor.outgoingObservation == null) return;
            // Creation is observed before dialing and survives Telecom removal. A delayed
            // terminal event can still clean up its own call, never an arbitrary old event.
            String candidate = descriptor.outgoingObservation.matchingCallID();
            if (!candidate.isEmpty()) {
                descriptor.androidID = candidate;
                descriptor.outgoingObservation.close();
                descriptor.outgoingObservation = null;
            }
        }
    }

    String androidCallIDFor(JSONObject call) {
        if (call == null) return "";
        synchronized (lock) {
            if (active == null) return "";
            Descriptor descriptor = active.descriptor;
            bindOutgoing(descriptor);
            return new CloudCallTarget(descriptor.callID, descriptor.callUUID,
                    descriptor.generation, descriptor.androidID).resolve(
                    call.optString("call_id"), call.optString("call_uuid"),
                    call.optLong("generation", 1));
        }
    }

    void handleCallEvent(JSONObject registration, JSONObject event, StandaloneRelayClient relay) throws Exception {
        var generation = RelayEgressGate.shared.generation();
        if (!generation.isCurrent()) return;
        String state = event.optString("state", "");
        String direction = event.optString("direction", "");
        String androidID = event.optString("call_id", "");
        Descriptor descriptor;
        synchronized (lock) {
            descriptor = active == null ? null : active.descriptor;
        }
        if ("incoming".equals(direction) && "incoming".equals(state) && descriptor == null) {
            // A queued ringing event can survive a Relay time-out until after the
            // carrier call has ended. Never wake CallKit with a stale ring.
            if (CallRepository.state(androidID) < 0 && eventAgeMillis(event) > 3_000) {
                BridgeLog.info("standalone_incoming_skipped_ended");
                return;
            }
            descriptor = Descriptor.incoming(registration, androidID);
            JSONObject payload = identity(registration).put("event", "incoming_call")
                    .put("call_id", descriptor.callID).put("call_uuid", descriptor.callUUID)
                    .put("generation", descriptor.generation).put("call_secret", descriptor.secret)
                    .put("number", event.optString("number", "")).put("caller_name", "")
                    .put("issued_at", Instant.now().toString())
                    .put("expires_at", Instant.now().plusSeconds(90).toString())
                    .put("media_transport", "legacy_pcm");
            // Keep ringing latency bounded; a failed call event stays queued for
            // the priority retry path instead of blocking the agent loop for 15s.
            postRelay(registration, relay, "/v2/events/call", payload, 5_000);
            start(descriptor, generation);
        } else if (descriptor != null && descriptor.androidID.isEmpty()) {
            bindOutgoing(descriptor);
            synchronized (lock) {
                if (active != null && active.descriptor == descriptor) {
                    synchronized (active) {
                        if (active.running && active.mediaStarted && active.pcm != null && !active.pcm.isClosed()) {
                            if (!descriptor.androidID.isBlank()) {
                                RemoteAudioSessionRegistry.setCloud(active.pcm, true, descriptor.androidID);
                            }
                        }
                    }
                }
            }
        }
        if (descriptor != null && !CloudCallTarget.owns(descriptor.androidID, androidID)) {
            // Call waiting, or a late event of an earlier call: it must not rewrite or end
            // the lifecycle of the call this session owns.
            BridgeLog.info("standalone_call_event_other_call state=" + state);
            return;
        }
        if (descriptor != null) {
            String phase = phase(state);
            if (!phase.isEmpty()) {
                JSONObject lifecycle = identity(registration).put("event", "call_state")
                        .put("call_id", descriptor.callID).put("call_uuid", descriptor.callUUID)
                        .put("generation", descriptor.generation).put("phase", phase)
                        .put("source", "agent").put("timestamp", Instant.now().toString())
                        .put("trace_id", "standalone-" + descriptor.callUUID + "-" + phase);
                postCallState(registration, relay, lifecycle);
                if ("active".equals(phase) || "ended".equals(phase)) {
                    JSONObject owner = identity(registration).put("event", "call_owner")
                            .put("call_id", descriptor.callID).put("call_uuid", descriptor.callUUID)
                            .put("generation", descriptor.generation).put("owner", "android")
                            .put("phase", phase);
                    // Best effort: an older Relay may not know owner=android yet, and
                    // this notification must never block the authoritative call path.
                    try {
                        relay.postJSON(registration, "/v1/events/call-owner", owner, 12_000);
                    } catch (Exception error) {
                        BridgeLog.info("standalone_call_owner_push_failed type="
                                + error.getClass().getSimpleName());
                    }
                }
            }
            if ("ended".equals(state)) closeActive(descriptor);
        }
    }

    /**
     * A crash/uninstall can leave a ringing/active lifecycle in Relay forever. The
     * next real call is then rejected with 409 identity_mismatch and never reaches
     * PushKit. Close only the exact stale identity returned by Relay, then retry the
     * current lifecycle once.
     */
    private void postCallState(JSONObject registration, StandaloneRelayClient relay,
                               JSONObject lifecycle) throws Exception {
        postRelay(registration, relay, "/v2/events/call-state", lifecycle, 12_000);
    }

    private static long eventAgeMillis(JSONObject event) {
        String eventID = event.optString("event_id", "");
        int dash = eventID.indexOf('-');
        if (dash <= 0) return 0;
        try { return Math.max(0, System.currentTimeMillis() - Long.parseLong(eventID.substring(0, dash))); }
        catch (NumberFormatException ignored) { return 0; }
    }

    private void postRelay(JSONObject registration, StandaloneRelayClient relay, String path,
                           JSONObject payload, int timeoutMillis) throws Exception {
        try {
            relay.postJSON(registration, path, payload, timeoutMillis);
        } catch (RelayHTTPException error) {
            if (error.statusCode() != 409) throw error;
            JSONObject response;
            try { response = new JSONObject(error.detailBody()); }
            catch (Exception ignored) { throw error; }
            if (!"identity_mismatch".equals(response.optString("reason"))) throw error;
            JSONObject stale = response.optJSONObject("lifecycle");
            if (stale == null || stale.optString("call_id").isBlank()
                    || stale.optString("call_uuid").isBlank()) throw error;
            JSONObject ended = identity(registration)
                    .put("event", "call_state")
                    .put("call_id", stale.optString("call_id"))
                    .put("call_uuid", stale.optString("call_uuid"))
                    .put("generation", Math.max(1, stale.optLong("generation", 1)))
                    .put("phase", "ended")
                    .put("source", "agent")
                    .put("timestamp", Instant.now().toString())
                    .put("trace_id", "standalone-stale-" + stale.optString("call_uuid"));
            relay.postJSON(registration, "/v2/events/call-state", ended, 12_000);
            BridgeLog.info("standalone_cloud_stale_call_cleared");
            relay.postJSON(registration, path, payload, timeoutMillis);
        }
    }

    private void start(Descriptor descriptor, RelayEgressGate.Generation generation) {
        synchronized (lock) {
            if (!generation.isCurrent()) return;
            if (active != null && active.descriptor.same(descriptor)) return;
            if (active != null) active.close();
            active = new CloudSession(descriptor, generation);
            sessions.execute(active);
        }
    }

    /**
     * The Relay will never take this queued call event. When it was the carrier's "ended", still
     * close the cloud call of that Android call, or its media session keeps reconnecting.
     */
    void abandonCallEvent(String encoded) {
        JSONObject event;
        try { event = new JSONObject(encoded); } catch (Exception ignored) { return; }
        if (!"ended".equals(event.optString("state", ""))) return;
        String androidID = event.optString("call_id", "");
        synchronized (lock) {
            if (active != null && CloudCallTarget.owns(active.descriptor.androidID, androidID)) {
                String callUUID = active.descriptor.callUUID;
                active.close();
                active = null;
                BridgeLog.info("standalone_cloud_call_closed_unconfirmed call_uuid="
                        + DebugRedactor.safeIdentifier(callUUID));
            }
        }
    }

    private void closeActive(Descriptor descriptor) {
        synchronized (lock) {
            if (active != null && active.descriptor.same(descriptor)) {
                active.close();
                active = null;
            }
        }
    }

    private final class CloudSession implements Runnable, Closeable {
        final Descriptor descriptor;
        final CloudCallRetryPolicy.MediaRetry mediaRetry = new CloudCallRetryPolicy.MediaRetry();
        final RelayEgressGate.Generation relayGeneration;
        volatile boolean running = true;
        volatile StandaloneWebSocket webSocket;
        volatile Socket pcm;
        volatile CloudPCMMediaPump mediaPump;
        volatile String mediaProtocol = "";
        volatile boolean mediaStarted;
        int sequence;

        CloudSession(Descriptor descriptor) { this(descriptor, RelayEgressGate.shared.generation()); }
        CloudSession(Descriptor descriptor, RelayEgressGate.Generation generation) {
            this.descriptor = descriptor;
            this.relayGeneration = generation;
        }

        @Override public void run() {
            int reconnectFailures = 0;
            while (running && relayGeneration.isCurrent()) {
                StandaloneWebSocket owner = null;
                boolean connected = false;
                try {
                    URI endpoint = URI.create(descriptor.relayURL.replaceFirst("^https", "wss")
                            + "/v1/calls/" + descriptor.callUUID + "/connect?role=agent&token="
                            + URLEncoder.encode(descriptor.secret, "UTF-8"));
                    owner = StandaloneWebSocket.connect(endpoint, "");
                    synchronized (this) {
                        if (!running || !relayGeneration.isCurrent()) { closeSocket(owner); return; }
                        webSocket = owner;
                    }
                    mediaRetry.authenticated();
                    owner.writeText(status("agent_ready", ""));
                    BridgeLog.info("standalone_cloud_media_connected call_uuid="
                            + DebugRedactor.safeIdentifier(descriptor.callUUID));
                    connected = true;
                    reconnectFailures = 0;
                    readLoop(owner);
                } catch (Exception error) {
                    if (running) {
                        connected = false;
                        reconnectFailures = Math.min(4, reconnectFailures + 1);
                        BridgeLog.error("standalone_cloud_media_disconnected", error);
                        var outcome = mediaRetry.outcome(error, CallRepository.state(descriptor.androidID),
                                android.os.SystemClock.elapsedRealtime());
                        if (outcome != CloudCallRetryPolicy.MediaOutcome.RECONNECT) {
                            // Relay no longer has this call (ended, expired or never stored),
                            // so every reconnect with this secret would be refused again.
                            BridgeLog.info("standalone_cloud_media_abandoned call_uuid="
                                    + DebugRedactor.safeIdentifier(descriptor.callUUID) + " " + CloudCallRetryPolicy.describe(error));
                            synchronized (lock) {
                                if (outcome == CloudCallRetryPolicy.MediaOutcome.STOP_AND_RELEASE && active == this) active = null;
                            }
                            close();
                        }
                    }
                } finally {
                    closeSocket(owner);
                    synchronized (this) {
                        if (webSocket == owner) {
                            webSocket = null;
                            // The next answer/replay must restart PCM for the new socket.
                            mediaStarted = false;
                            RemoteAudioSessionRegistry.setCloud(pcm, false, "");
                            closeSocket(mediaPump);
                            mediaPump = null;
                            closeSocket(pcm);
                            pcm = null;
                        }
                    }
                }
                if (running) {
                    // A Relay/DO failure or quota exhaustion must not turn into a
                    // 1 Hz request loop. Back off to at most one attempt per 15 s.
                    long delay = connected ? 1_000L : Math.min(15_000L, 1_000L << reconnectFailures);
                    if (!connected) {
                        BridgeLog.info("standalone_cloud_media_retry delay_ms=" + delay
                                + " failures=" + reconnectFailures);
                    }
                    try { Thread.sleep(delay); }
                    catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                }
            }
        }

        private void readLoop(StandaloneWebSocket owner) throws Exception {
            while (running && webSocket == owner) {
                StandaloneWebSocket.Message message = owner.read();
                if (message.opcode() == 2) {
                    CloudPCMMediaPump pump = mediaPump;
                    if (pump != null) pump.receive(decodePCM(message.payload()));
                    continue;
                }
                JSONObject control = new JSONObject(new String(message.payload(), StandardCharsets.UTF_8));
                String action = control.optString("action", "");
                if (!"answer".equals(action) && !"reject".equals(action) && !"end".equals(action)) continue;
                mediaProtocol = control.optString("media_protocol", "");
                JSONObject command = new JSONObject().put("command_id",
                                control.optString("command_id", UUID.randomUUID().toString()))
                        .put("type", "call_control").put("action", action)
                        .put("call", new JSONObject().put("call_id", descriptor.callID)
                                .put("call_uuid", descriptor.callUUID)
                                .put("generation", descriptor.generation));
                JSONObject result = StandaloneAgentGateway.get(context).executeCloudCommand(command);
                if (!"completed".equals(result.optString("status"))) {
                    owner.writeText(status("action_error", result.optString("error", "Telecom command failed")));
                    continue;
                }
                if ("answer".equals(action)) {
                    owner.writeText(status("answer_ok", ""));
                    if (!mediaStarted) {
                        mediaStarted = true;
                        sessions.execute(() -> runPCM(owner));
                    }
                } else {
                    owner.writeText(status("reject".equals(action) ? "rejected" : "ended", ""));
                    running = false;
                }
            }
        }

        private void runPCM(StandaloneWebSocket owner) {
            long deadline = System.currentTimeMillis() + 45_000;
            while (running && webSocket == owner && mediaStarted && System.currentTimeMillis() < deadline) {
                Socket connection = new Socket();
                try {
                    connection.connect(new InetSocketAddress("127.0.0.1", 7580), 2_000);
                    connection.setTcpNoDelay(true);
                    connection.setSoTimeout(5_000);
                    OutputStream output = connection.getOutputStream();
                    output.write("AIRSIMPCM1\n".getBytes(StandardCharsets.US_ASCII));
                    output.flush();
                    byte[] ready = new byte[11];
                    new DataInputStream(connection.getInputStream()).readFully(ready);
                    if (!"AIRSIMREADY".equals(new String(ready, StandardCharsets.US_ASCII))) {
                        connection.close();
                        throw new java.io.IOException("PCM handshake failed");
                    }
                    connection.setSoTimeout(0);
                    synchronized (this) {
                        if (!running || webSocket != owner || !mediaStarted) {
                            closeSocket(connection); return;
                        }
                        pcm = connection;
                        boolean[] first = {true};
                        mediaPump = new CloudPCMMediaPump(connection.getInputStream(), output, frame -> {
                            owner.writeBinary(encodePCM(frame));
                            if (first[0]) { first[0] = false; owner.writeText(status("pcm_first_frame", "")); }
                        }, error -> {
                            if (running && webSocket == owner) BridgeLog.error("standalone_pcm_bridge_failed", error);
                            // Only the owning connection is closed; old workers cannot touch a new call/socket.
                            closeSocket(owner);
                        }, sessions);
                        mediaPump.start();
                        if (!descriptor.androidID.isBlank()) {
                            RemoteAudioSessionRegistry.setCloud(connection, true, descriptor.androidID);
                        }
                    }
                    owner.writeText(status("pcm_listening", ""));
                    owner.writeText(status("active", ""));
                    owner.writeText(status("pcm_ready", ""));
                    return;
                } catch (Exception error) {
                    closeSocket(connection);
                    synchronized (this) {
                        if (pcm == connection) {
                            RemoteAudioSessionRegistry.setCloud(connection, false, "");
                            closeSocket(mediaPump); mediaPump = null; pcm = null;
                        }
                    }
                    if (running && webSocket == owner) BridgeLog.error("standalone_pcm_bridge_failed", error);
                }
                if (running) {
                    try { Thread.sleep(750); }
                    catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                }
            }
        }

        private byte[] encodePCM(byte[] payload) {
            if (!"airsim-pcm-v1".equalsIgnoreCase(mediaProtocol)) return payload;
            ByteBuffer wire = ByteBuffer.allocate(20 + payload.length).order(ByteOrder.BIG_ENDIAN);
            wire.put(new byte[]{'A', 'S', 'P', 'M'}).put((byte) 1).put((byte) 0).putShort((short) 20)
                    .putInt(sequence++).putLong(System.currentTimeMillis()).put(payload);
            return wire.array();
        }

        private byte[] decodePCM(byte[] wire) throws Exception {
            if (wire.length < 4 || wire[0] != 'A' || wire[1] != 'S' || wire[2] != 'P' || wire[3] != 'M') return wire;
            if (wire.length != 340 || wire[4] != 1 || ByteBuffer.wrap(wire, 6, 2).order(ByteOrder.BIG_ENDIAN).getShort() != 20) {
                throw new java.io.IOException("AirSIM PCM frame invalid");
            }
            return java.util.Arrays.copyOfRange(wire, 20, wire.length);
        }

        private String status(String value, String message) throws Exception {
            JSONObject result = new JSONObject().put("status", value).put("call_id", descriptor.callID)
                    .put("call_uuid", descriptor.callUUID).put("generation", descriptor.generation);
            if (!message.isEmpty()) result.put("message", message);
            return result.toString();
        }

        @Override public synchronized void close() {
            running = false;
            mediaStarted = false;
            synchronized (descriptor) {
                if (descriptor.outgoingObservation != null) descriptor.outgoingObservation.close();
            }
            RemoteAudioSessionRegistry.setCloud(pcm, false, "");
            closeSocket(webSocket);
            closeSocket(mediaPump);
            closeSocket(pcm);
        }
    }

    private static final class Descriptor {
        final String callID;
        final String callUUID;
        final long generation;
        final String secret;
        final String relayURL;
        final String direction;
        CallRepository.OutgoingCallObservation outgoingObservation;
        volatile String androidID;

        Descriptor(String callID, String callUUID, long generation, String secret,
                   String relayURL, String direction, String androidID) {
            this.callID = callID;
            this.callUUID = callUUID;
            this.generation = generation <= 0 ? 1 : generation;
            this.secret = secret;
            this.relayURL = relayURL;
            this.direction = direction;
            this.androidID = androidID;
        }

        static Descriptor from(JSONObject call) {
            Descriptor result = new Descriptor(call.optString("call_id"), call.optString("call_uuid"),
                    call.optLong("generation", 1), call.optString("call_secret"),
                    call.optString("relay_url"), call.optString("direction", "outgoing"), "");
            result.validate();
            return result;
        }

        static Descriptor incoming(JSONObject registration, String androidID) {
            byte[] secret = new byte[32];
            new SecureRandom().nextBytes(secret);
            StringBuilder encoded = new StringBuilder(64);
            for (byte value : secret) encoded.append(String.format("%02x", value & 0xff));
            Descriptor result = new Descriptor("android-" + System.currentTimeMillis(), UUID.randomUUID().toString(), 1,
                    encoded.toString(), registration.optString("relay_url"), "incoming", androidID);
            result.validate();
            return result;
        }

        private void validate() {
            if (callID.isBlank() || callUUID.isBlank() || secret.isBlank()) {
                throw new IllegalArgumentException("云端通话描述缺少身份或密钥");
            }
            URI relay = URI.create(relayURL);
            if (!"https".equalsIgnoreCase(relay.getScheme()) || relay.getHost() == null
                    || relay.getRawUserInfo() != null) {
                throw new IllegalArgumentException("云端通话 Relay 必须是无凭据的 HTTPS 地址");
            }
        }

        boolean same(Descriptor other) { return other != null && callUUID.equalsIgnoreCase(other.callUUID); }
    }

    private static JSONObject identity(JSONObject registration) throws Exception {
        return new JSONObject().put("device_id", registration.getString("device_id"))
                .put("agent_id", registration.getString("android_agent_id"))
                .put("device_secret", registration.getString("device_secret"));
    }

    private static String phase(String state) {
        return switch (state) {
            case "incoming" -> "ringing";
            case "dialing", "alerting" -> "connecting";
            case "active", "held" -> "active";
            case "ended" -> "ended";
            default -> "";
        };
    }

    private static void closeSocket(Object value) {
        if (value instanceof Closeable closeable) {
            try { closeable.close(); } catch (Exception ignored) {}
        }
    }

    @Override public void close() {
        synchronized (lock) {
            if (active != null) active.close();
            active = null;
        }
    }
}
