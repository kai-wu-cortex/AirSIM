package com.airsim.phonecontrol;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.net.SocketTimeoutException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** AVF-free foreground Agent: Relay registration, heartbeat and command execution. */
public final class StandaloneAgentService extends Service {
    private static final ConcurrentLinkedQueue<String> CALL_EVENTS = new ConcurrentLinkedQueue<>();
    private static final ConcurrentLinkedQueue<String> SMS_EVENTS = new ConcurrentLinkedQueue<>();
    private final ExecutorService worker = Executors.newFixedThreadPool(2);
    private final Set<String> completedCommands = new LinkedHashSet<>();
    private volatile boolean running;
    private StandaloneAgentStore store;
    private StandaloneRelayClient relay;
    private int syncedRegistrationHash;
    private long lastHeartbeat;
    private volatile StandaloneWebSocket commandSocket;
    private volatile boolean commandChannelConnected;

    public static void start(Context context) {
        try { context.startForegroundService(new Intent(context, StandaloneAgentService.class)); }
        catch (RuntimeException error) { BridgeLog.error("standalone_agent_start_failed", error); }
    }

    static void enqueueCallEvent(Context context, String json) {
        CALL_EVENTS.add(json);
        start(context);
    }

    static void enqueueSMSEvent(Context context, String json) {
        SMS_EVENTS.add(json);
        start(context);
    }

    @Override public void onCreate() {
        super.onCreate();
        store = new StandaloneAgentStore(this);
        relay = new StandaloneRelayClient();
        startForeground(BridgeNotification.WATCHDOG_ID,
                BridgeNotification.status(this, "内置 Agent 正在启动"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
        running = true;
        ShizukuBridgeManager.get(this).ensureStarted();
        VoWLANGatewayService.start(this);
        worker.execute(this::loop);
        worker.execute(this::commandLoop);
        BridgeLog.info("standalone_agent_created");
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return null; }

    private void loop() {
        int failures = 0;
        while (running) {
            try {
                JSONObject registration = store.registration();
                if (registration == null || !store.cloudEnabled()) {
                    update(registration == null ? "内置 Agent 在线 · 等待 iPhone 配对" : "内置 Agent 在线 · 云端已关闭");
                    Thread.sleep(2_000);
                    continue;
                }
                syncRegistration(registration);
                long now = System.currentTimeMillis();
                if (now - lastHeartbeat >= 30_000) sendHeartbeat(registration);
                flushEvents(registration);
                if (!commandChannelConnected) pollCommands(registration);
                failures = 0;
                update("内置 Agent 在线 · Relay 已连接");
                Thread.sleep(2_000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                failures++;
                store.recordError(error.getClass().getSimpleName() + ": " + error.getMessage());
                BridgeLog.error("standalone_agent_cycle_failed failures=" + failures, error);
                update("内置 Agent 正在重连 · " + failures);
                try { Thread.sleep(RetryPolicy.delayMillis(failures - 1)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void syncRegistration(JSONObject registration) throws Exception {
        int hash = registration.toString().hashCode();
        if (hash == syncedRegistrationHash) return;
        relay.postJSON(registration, "/v1/devices/register", new JSONObject(registration.toString()), 15_000);
        syncedRegistrationHash = hash;
        store.recordSuccess();
        BridgeLog.info("standalone_relay_registration_synced");
    }

    private void sendHeartbeat(JSONObject registration) throws Exception {
        JSONObject heartbeat = identity(registration)
                .put("event", "agent_heartbeat").put("agent_version", "standalone-0.1.0")
                .put("agent_id", registration.optString("android_agent_id", AndroidAgentIdentity.agentID(this)))
                .put("agent_kind", "standalone")
                .put("device_name", registration.optString("android_device_name", AndroidAgentIdentity.deviceName()))
                .put("manufacturer", registration.optString("android_manufacturer", android.os.Build.MANUFACTURER))
                .put("model", registration.optString("android_model", android.os.Build.MODEL))
                .put("phone_number", registration.optString("android_phone_number", AndroidAgentIdentity.phoneNumber(this)))
                .put("at_ok", true).put("cellular_state", "registered")
                .put("cellular_registration", "Android Telecom")
                .put("cellular_recovery", "not_required").put("ecm_carrier", "android-default");
        relay.postJSON(registration, "/v1/events/heartbeat", heartbeat, 12_000);
        lastHeartbeat = System.currentTimeMillis();
        store.recordHeartbeat();
    }

    private void pollCommands(JSONObject registration) throws Exception {
        JSONObject batch = relay.postJSON(registration, "/v1/commands/pull", identity(registration), 12_000);
        JSONArray commands = batch.optJSONArray("commands");
        if (commands == null) return;
        for (int index = 0; index < commands.length(); index++) {
            JSONObject command = commands.getJSONObject(index);
            String commandID = command.optString("command_id", "").toLowerCase();
            if (commandID.isBlank() || completedCommands.contains(commandID)) continue;
            JSONObject result;
            try {
                String expires = command.optString("expires_at", "");
                if (expires.isEmpty() || Instant.now().isAfter(Instant.parse(expires))) {
                    result = new JSONObject().put("command_id", commandID).put("status", "failed")
                            .put("error", "云端命令已过期");
                } else {
                    result = StandaloneAgentGateway.get(this).executeCloudCommand(command);
                    if (result.optString("status").equals("completed") && "dial".equals(command.optString("type"))) {
                        StandaloneCloudMediaManager.get(this).startOutgoing(command.optJSONObject("call"));
                    }
                }
            } catch (Exception error) {
                result = new JSONObject().put("command_id", commandID).put("status", "failed")
                        .put("error", DebugRedactor.sanitize(error.getMessage()));
            }
            JSONObject completion = identity(registration);
            for (String key : new String[]{"command_id", "status", "result", "error"}) {
                if (result.has(key)) completion.put(key, result.get(key));
            }
            relay.postJSON(registration, "/v1/commands/complete", completion, 12_000);
            rememberCompleted(commandID);
        }
    }

    private void commandLoop() {
        int failures = 0;
        while (running) {
            StandaloneWebSocket socket = null;
            try {
                JSONObject registration = store.registration();
                if (registration == null || !store.cloudEnabled()) {
                    Thread.sleep(2_000);
                    continue;
                }
                URI relayURI = URI.create(registration.getString("relay_url"));
                String deviceID = URLEncoder.encode(registration.getString("device_id"), StandardCharsets.UTF_8)
                        .replace("+", "%20");
                URI endpoint = URI.create("wss://" + relayURI.getRawAuthority()
                        + "/v1/devices/" + deviceID + "/commands/connect");
                socket = StandaloneWebSocket.connect(endpoint, registration.getString("device_secret"));
                commandSocket = socket;
                commandChannelConnected = true;
                failures = 0;
                socket.setReadTimeout(20_000);
                BridgeLog.info("standalone_command_channel_connected");
                while (running) {
                    try {
                        StandaloneWebSocket.Message message = socket.read();
                        if (message.opcode() != 1) continue;
                        JSONObject command = new JSONObject(new String(message.payload(), StandardCharsets.UTF_8));
                        JSONObject result = StandaloneAgentGateway.get(this).executeCloudCommand(command);
                        if (result.optString("status").equals("completed")
                                && "dial".equals(command.optString("type"))) {
                            StandaloneCloudMediaManager.get(this).startOutgoing(command.optJSONObject("call"));
                        }
                        socket.writeText(result.toString());
                    } catch (SocketTimeoutException timeout) {
                        socket.writePing("command-keepalive".getBytes(StandardCharsets.US_ASCII));
                    }
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                failures++;
                if (running) BridgeLog.error("standalone_command_channel_failed failures=" + failures, error);
            } finally {
                commandChannelConnected = false;
                commandSocket = null;
                if (socket != null) socket.close();
            }
            if (running) {
                try { Thread.sleep(RetryPolicy.delayMillis(failures - 1)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void flushEvents(JSONObject registration) throws Exception {
        String encoded;
        while ((encoded = CALL_EVENTS.peek()) != null) {
            JSONObject event = new JSONObject(encoded);
            StandaloneCloudMediaManager.get(this).handleCallEvent(registration, event, relay);
            CALL_EVENTS.poll();
        }
        while ((encoded = SMS_EVENTS.peek()) != null) {
            JSONObject source = new JSONObject(encoded);
            JSONObject event = identity(registration).put("event", "incoming_sms")
                    .put("delivery_id", source.optString("delivery_id"))
                    .put("sender", source.optString("sender")).put("content", source.optString("content"))
                    .put("timestamp", source.optString("timestamp", Instant.now().toString()));
            relay.postJSON(registration, "/v1/events/sms", event, 12_000);
            SMS_EVENTS.poll();
        }
    }

    private static JSONObject identity(JSONObject registration) throws Exception {
        return new JSONObject().put("device_id", registration.getString("device_id"))
                .put("device_secret", registration.getString("device_secret"));
    }

    private void rememberCompleted(String commandID) {
        completedCommands.add(commandID);
        while (completedCommands.size() > 128) {
            completedCommands.remove(completedCommands.iterator().next());
        }
    }

    private void update(String detail) {
        getSystemService(android.app.NotificationManager.class).notify(
                BridgeNotification.WATCHDOG_ID, BridgeNotification.status(this, detail));
    }

    @Override public void onDestroy() {
        running = false;
        StandaloneWebSocket socket = commandSocket;
        if (socket != null) socket.close();
        worker.shutdownNow();
        StandaloneCloudMediaManager.get(this).close();
        BridgeLog.info("standalone_agent_destroyed");
        super.onDestroy();
    }
}
