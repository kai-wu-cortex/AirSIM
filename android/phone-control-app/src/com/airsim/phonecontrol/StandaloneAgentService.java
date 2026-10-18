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
    private final ExecutorService worker = Executors.newFixedThreadPool(2);
    private final Set<String> completedCommands = new LinkedHashSet<>();
    private final NotificationUpdateGate notificationGate = new NotificationUpdateGate();
    private volatile boolean running;
    private StandaloneAgentStore store;
    private StandaloneRelayClient relay;
    private int syncedRegistrationHash;
    private long lastHeartbeat;
    private long lastCommandPoll;
    private volatile StandaloneWebSocket commandSocket;
    private volatile boolean commandChannelConnected;
    private final RelayCommandRetryState commandRetry = new RelayCommandRetryState();
    private RelayCommandConfiguration<JSONObject> commandConfiguration;
    private final android.content.SharedPreferences.OnSharedPreferenceChangeListener commandPreferences =
            (preferences, key) -> commandConfiguration.snapshot();

    public static void start(Context context) {
        try { context.startForegroundService(new Intent(context, StandaloneAgentService.class)); }
        catch (RuntimeException error) { BridgeLog.error("standalone_agent_start_failed", error); }
    }

    static void enqueueCallEvent(Context context, String json) {
        CALL_EVENTS.add(json);
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
        commandConfiguration = new RelayCommandConfiguration<>(store::registration, this::commandScope, commandRetry);
        getSharedPreferences("standalone_agent", MODE_PRIVATE).registerOnSharedPreferenceChangeListener(commandPreferences);
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
                SMSInboxScanner.scanIfDue(this);
                var snapshot = commandConfiguration.snapshot();
                JSONObject registration = snapshot.registration();
                if (registration == null || !store.cloudEnabled()) {
                    update(registration == null ? "内置 Agent 在线 · 等待 iPhone 配对" : "内置 Agent 在线 · 云端已关闭");
                    Thread.sleep(2_000);
                    continue;
                }
                syncRegistration(registration);
                long now = System.currentTimeMillis();
                if (now - lastHeartbeat >= 30_000) sendHeartbeat(registration);
                flushEvents(registration);
                if (commandConfiguration.isCurrent(snapshot) && CommandPollingPolicy.shouldPoll(commandChannelConnected, lastCommandPoll, now,
                        commandRetry.remainingMillis(android.os.SystemClock.elapsedRealtime()))) {
                    lastCommandPoll = now;
                    try { pollCommands(snapshot); }
                    catch (Exception error) { if (commandConfiguration.isCurrent(snapshot)) commandFailure(snapshot.epoch(), -1, error); }
                }
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
                try { Thread.sleep(RelayRetryPolicy.delayMillis(failures, error)); }
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
                .put("command_routing_version", 1)
                .put("device_name", AndroidAgentIdentity.deviceName())
                .put("manufacturer", registration.optString("android_manufacturer", android.os.Build.MANUFACTURER))
                .put("model", registration.optString("android_model", android.os.Build.MODEL))
                .put("phone_number", AndroidAgentIdentity.phoneNumber(this))
                .put("at_ok", true).put("cellular_state", "registered")
                .put("cellular_registration", "Android Telecom")
                .put("cellular_recovery", "not_required").put("ecm_carrier", "android-default");
        relay.postJSON(registration, "/v1/events/heartbeat", heartbeat, 12_000);
        lastHeartbeat = System.currentTimeMillis();
        store.recordHeartbeat();
    }

    private void pollCommands(RelayCommandConfiguration.Snapshot<JSONObject> snapshot) throws Exception {
        if (!commandConfiguration.isCurrent(snapshot)) return;
        JSONObject registration = snapshot.registration();
        JSONObject batch = relay.postJSON(registration, "/v2/commands/pull", identity(registration), 12_000);
        JSONArray commands = batch.optJSONArray("commands");
        if (commands == null) return;
        for (int index = 0; index < commands.length(); index++) {
            if (!commandConfiguration.isCurrent(snapshot)) return;
            JSONObject command = commands.getJSONObject(index);
            if (!agentID(registration).equals(command.optString("target_agent_id"))) continue;
            String commandID = command.optString("command_id", "").toLowerCase();
            if (commandID.isBlank() || completedCommands.contains(commandID)) continue;
            JSONObject result;
            try {
                String expires = command.optString("expires_at", "");
                if (expires.isEmpty() || Instant.now().isAfter(Instant.parse(expires))) {
                    result = new JSONObject().put("command_id", commandID).put("status", "failed")
                            .put("error", "云端命令已过期");
                } else {
                    if (!commandConfiguration.isCurrent(snapshot)) return;
                    result = StandaloneAgentGateway.get(this).executeCloudCommand(command,
                            () -> commandConfiguration.isCurrent(snapshot));
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
            if (!commandConfiguration.isCurrent(snapshot)) return;
            relay.postJSON(registration, "/v2/commands/complete", completion, 12_000);
            rememberCompleted(commandID);
        }
    }

    private void commandLoop() {
        while (running) {
            StandaloneWebSocket socket = null;
            long connectedAt = -1;
            long epoch = -1;
            RelayCommandConfiguration.Snapshot<JSONObject> snapshot = null;
            try {
                snapshot = commandConfiguration.snapshot();
                JSONObject registration = snapshot.registration();
                epoch = snapshot.epoch();
                if (registration == null || !store.cloudEnabled()) {
                    Thread.sleep(2_000);
                    continue;
                }
                if (!commandRetry.isCurrent(epoch)) { Thread.sleep(2_000); continue; }
                long cooldown = commandRetry.remainingMillis(android.os.SystemClock.elapsedRealtime());
                if (cooldown > 0) { Thread.sleep(Math.min(2_000, cooldown)); continue; }
                URI relayURI = URI.create(registration.getString("relay_url"));
                String deviceID = URLEncoder.encode(registration.getString("device_id"), "UTF-8")
                        .replace("+", "%20");
                URI endpoint = URI.create("wss://" + relayURI.getRawAuthority()
                        + "/v2/devices/" + deviceID + "/commands/connect?agent_id="
                        + URLEncoder.encode(agentID(registration), "UTF-8").replace("+", "%20"));
                final long connectionEpoch = epoch;
                socket = StandaloneWebSocket.connect(endpoint, registration.getString("device_secret"),
                        attempt -> commandRetry.attach(connectionEpoch, attempt),
                        () -> (javax.net.ssl.SSLSocket)javax.net.ssl.SSLSocketFactory.getDefault().createSocket());
                if (!running || !commandRetry.attach(epoch, socket)) continue;
                commandSocket = socket;
                commandChannelConnected = true;
                connectedAt = android.os.SystemClock.elapsedRealtime();
                socket.setReadTimeout(20_000);
                BridgeLog.info("standalone_command_channel_connected");
                final var commandSnapshot = snapshot;
                while (running && commandConfiguration.isCurrent(snapshot)) {
                    try {
                        StandaloneWebSocket.Message message = socket.read();
                        if (message.opcode() != 1) continue;
                        JSONObject command = new JSONObject(new String(message.payload(), StandardCharsets.UTF_8));
                        if (!commandConfiguration.isCurrent(snapshot)) break;
                        if (!agentID(registration).equals(command.optString("target_agent_id"))) continue;
                        JSONObject result = StandaloneAgentGateway.get(this).executeCloudCommand(command,
                                () -> commandConfiguration.isCurrent(commandSnapshot));
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
                if (running && commandConfiguration.isCurrent(snapshot)) commandFailure(epoch, connectedAt, error);
            } finally {
                commandChannelConnected = false;
                commandSocket = null;
                if (socket != null) socket.close();
            }
        }
    }

    private String commandScope(JSONObject registration) {
        String scope = null;
        if (running && registration != null && !registration.optBoolean("local_mode",false)
                && registration.optBoolean("cloud_enabled",true)) {
            String id = agentID(registration);
            if (RelayCommandRetryState.validAgentID(id)) {
                // Only transport identity participates: SIM, metadata and push-token refreshes do not reconnect.
                scope = new JSONArray().put(registration.optString("relay_url"))
                        .put(registration.optString("device_id")).put(registration.optString("device_secret"))
                        .put(id).toString();
            }
        }
        return scope;
    }

    private static String agentID(JSONObject registration) { return registration.optString("android_agent_id", ""); }

    private void commandFailure(long epoch, long connectedAt, Throwable error) {
        long now = android.os.SystemClock.elapsedRealtime();
        RetryDecision decision = commandRetry.failedFor(epoch, now, connectedAt < 0 ? 0 : Math.max(0, now - connectedAt),
                error, java.util.concurrent.ThreadLocalRandom.current().nextDouble());
        if (decision == null) return;
        BridgeLog.info("standalone_command_retry reason=" + decision.reason() + " tier=" + decision.failures()
                + " delay_ms=" + decision.delayMillis() + " fallback=false");
    }

    private void flushEvents(JSONObject registration) throws Exception {
        String encoded;
        while ((encoded = CALL_EVENTS.peek()) != null) {
            JSONObject event = new JSONObject(encoded);
            StandaloneCloudMediaManager.get(this).handleCallEvent(registration, event, relay);
            CALL_EVENTS.poll();
        }
        StandaloneSMSStore smsStore = new StandaloneSMSStore(this);
        JSONArray smsPending = smsStore.cloudPending();
        for (int index = 0; index < smsPending.length(); index++) {
            JSONObject source = smsPending.getJSONObject(index);
            JSONObject event = identity(registration).put("event", "incoming_sms")
                    .put("delivery_id", source.optString("delivery_id"))
                    .put("sender", source.optString("sender")).put("content", source.optString("content"))
                    .put("timestamp", source.optString("timestamp", Instant.now().toString()));
            relay.postJSON(registration, "/v1/events/sms", event, 12_000);
            smsStore.markCloudSent(source.getString("delivery_id"));
        }
    }

    private static JSONObject identity(JSONObject registration) throws Exception {
        return new JSONObject().put("device_id", registration.getString("device_id"))
                .put("agent_id", agentID(registration))
                .put("device_secret", registration.getString("device_secret"));
    }

    private void rememberCompleted(String commandID) {
        completedCommands.add(commandID);
        while (completedCommands.size() > 128) {
            completedCommands.remove(completedCommands.iterator().next());
        }
    }

    private void update(String detail) {
        long now = System.currentTimeMillis();
        if (!notificationGate.shouldPublish(detail, now)) return;
        getSystemService(android.app.NotificationManager.class).notify(
                BridgeNotification.WATCHDOG_ID, BridgeNotification.status(this, detail));
        notificationGate.published(detail, now);
    }

    @Override public void onDestroy() {
        running = false;
        getSharedPreferences("standalone_agent", MODE_PRIVATE).unregisterOnSharedPreferenceChangeListener(commandPreferences);
        commandConfiguration.stop();
        StandaloneWebSocket socket = commandSocket;
        if (socket != null) socket.close();
        worker.shutdownNow();
        StandaloneCloudMediaManager.get(this).close();
        BridgeLog.info("standalone_agent_destroyed");
        super.onDestroy();
    }
}
