package com.airsim.phonecontrol;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.FileDescriptor;
import java.io.PrintWriter;
import java.net.URI;
import java.net.SocketTimeoutException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** AVF-free foreground Agent: Relay registration, heartbeat and command execution. */
public final class StandaloneAgentService extends Service {
    private static final RelayEventQueue<String> CALL_EVENTS = new RelayEventQueue<>(RelayEgressGate.shared);
    private static final Object START_LOCK = new Object();
    private static boolean startRequested;
    private static volatile StandaloneAgentService instance;
    private static final java.util.concurrent.atomic.AtomicBoolean manualHeartbeatRunning = new java.util.concurrent.atomic.AtomicBoolean();
    private final ExecutorService worker = Executors.newFixedThreadPool(3);
    private final RelayCommandRetryState smsTransport = new RelayCommandRetryState();
    private record SMSSnapshot(RelayCommandConfiguration.Snapshot<JSONObject> configuration, long epoch,
                               RelayEgressGate.Generation generation) {}
    // CallKit latency must not wait behind heartbeat/registration/command I/O.
    private final ExecutorService eventWorker = Executors.newSingleThreadExecutor();
    private final Object callEventLock = new Object();
    private final Set<String> completedCommands = new LinkedHashSet<>();
    private final NotificationUpdateGate notificationGate = new NotificationUpdateGate();
    private volatile boolean running;
    private StandaloneAgentStore store;
    private StandaloneRelayClient relay;
    private int syncedRegistrationHash;
    private final RelayRegistrationRecovery registrationRecovery = new RelayRegistrationRecovery();
    private final CloudCallRetryPolicy callEventRetry = new CloudCallRetryPolicy();
    private volatile long lastHeartbeat;
    private volatile long nextHeartbeatAttempt;
    private final CloudSMSUploader smsUploader = new CloudSMSUploader();
    private long lastCommandPoll;
    private volatile StandaloneWebSocket commandSocket;
    private volatile boolean commandChannelConnected;
    private final RelayCommandRetryState commandRetry = new RelayCommandRetryState();
    private RelayCommandConfiguration<JSONObject> commandConfiguration;
    private final android.content.SharedPreferences.OnSharedPreferenceChangeListener commandPreferences =
            (preferences, key) -> smsSnapshot();

    public static void start(Context context) {
        synchronized (START_LOCK) {
            if (instance != null && instance.running) return;
            if (startRequested) return;
            startRequested = true;
            try { context.startForegroundService(new Intent(context, StandaloneAgentService.class)); }
            catch (RuntimeException error) {
                startRequested = false;
                BridgeLog.error("standalone_agent_start_failed", error);
            }
        }
    }

    /** Explicit user action; call off the UI thread. Never enables cloud or bypasses the gate. */
    static void sendManualHeartbeat() throws Exception {
        if (!manualHeartbeatRunning.compareAndSet(false, true))
            throw new IllegalStateException("心跳正在发送，请稍候");
        try { performManualHeartbeat(); }
        finally { manualHeartbeatRunning.set(false); }
    }

    private static void performManualHeartbeat() throws Exception {
        StandaloneAgentService active = instance;
        if (active == null || !active.running) throw new IllegalStateException("Agent 服务未运行，请返回首页启动后重试");
        var generation = RelayEgressGate.shared.generation();
        if (!generation.isCurrent()) throw new IllegalStateException("纯本地模式已开启，禁止发送云端心跳");
        var snapshot = active.commandConfiguration.snapshot();
        if (snapshot.scope() == null || !active.store.cloudEnabled())
            throw new IllegalStateException("云端未开启或尚未配对，请先检查云端配置");
        active.relay.postJSON(snapshot.registration(), "/v1/devices/register",
                RelayRegistrationPayload.forRelay(snapshot.registration()), 15_000, generation);
        if (!generation.isCurrent() || !active.commandConfiguration.isCurrent(snapshot))
            throw new IllegalStateException("连接配置已变更，请重新发送");
        try {
            active.sendHeartbeat(snapshot.registration(), generation);
            active.nextHeartbeatAttempt = 0;
        } catch (Exception error) {
            active.nextHeartbeatAttempt = android.os.SystemClock.elapsedRealtime()
                    + RelayHTTPException.heartbeatRetryDelay(error);
            throw error;
        }
        if (!generation.isCurrent() || !active.commandConfiguration.isCurrent(snapshot))
            throw new IllegalStateException("连接配置已变更，请重新自检");
        BridgeLog.info("standalone_manual_heartbeat_accepted");
    }

    static void enqueueCallEvent(Context context, String json) {
        if (!CALL_EVENTS.add(json)) return;
        start(context);
        StandaloneAgentService active = instance;
        if (active != null) active.eventWorker.execute(active::flushCallEvents);
    }

    @Override public void onCreate() {
        super.onCreate();
        // Android starts the FGS promotion deadline when startForegroundService() returns.
        // Promote before any preference, disk, or Shizuku initialization can delay onCreate().
        startForeground(BridgeNotification.WATCHDOG_ID,
                BridgeNotification.status(this, "内置 Agent 正在启动"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
        store = new StandaloneAgentStore(this);
        relay = new StandaloneRelayClient();
        running = true;
        synchronized (START_LOCK) {
            instance = this;
            startRequested = false;
        }
        commandConfiguration = new RelayCommandConfiguration<>(store::registration, this::commandScope, commandRetry);
        getSharedPreferences("standalone_agent", MODE_PRIVATE).registerOnSharedPreferenceChangeListener(commandPreferences);
        ShizukuBridgeManager.get(this).ensureStarted();
        SIMSlotObserver.start(this, () -> StandaloneAgentGateway.get(this).simSlotsChanged());
        VoWLANGatewayService.start(this);
        worker.execute(this::loop);
        worker.execute(this::commandLoop);
        worker.execute(this::smsLoop);
        BridgeLog.info("standalone_agent_created");
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return null; }

    /**
     * {@code adb shell dumpsys activity service <this component> [simulate-unauthorized]} prints the
     * Relay re-registration state; the optional argument feeds one simulated Relay 401 for on-device
     * verification. Callers need the DUMP permission, so only adb/shell can reach it.
     */
    @Override protected void dump(FileDescriptor fd, PrintWriter writer, String[] args) {
        long now = android.os.SystemClock.elapsedRealtime();
        if (args != null && Arrays.asList(args).contains("simulate-unauthorized")) {
            registrationRecovery.onFailure(new RelayHTTPException(401, "simulated by dumpsys"), now);
        }
        writer.println("relay_recovery " + registrationRecovery.describe(now));
    }

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
                // 120s remains inside the 150s cloud-online window and cuts
                // Relay heartbeat/observability churn on weak cellular links.
                if (now - lastHeartbeat >= 120_000 &&
                        android.os.SystemClock.elapsedRealtime() >= nextHeartbeatAttempt) {
                    try {
                        sendHeartbeat(registration);
                        nextHeartbeatAttempt = 0;
                        registrationRecovery.onAuthenticated();
                    } catch (Exception heartbeatError) {
                        // Do not spin the whole agent loop on a failed heartbeat.
                        nextHeartbeatAttempt = android.os.SystemClock.elapsedRealtime()
                                + RelayHTTPException.heartbeatRetryDelay(heartbeatError);
                        registrationRecovery.onFailure(heartbeatError, android.os.SystemClock.elapsedRealtime());
                        BridgeLog.error("standalone_heartbeat_failed", heartbeatError);
                    }
                }
                flushCallEvents();
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
                registrationRecovery.onFailure(error, android.os.SystemClock.elapsedRealtime());
                store.recordError(error.getClass().getSimpleName() + ": " + error.getMessage());
                BridgeLog.error("standalone_agent_cycle_failed failures=" + failures, error);
                update("内置 Agent 正在重连 · " + failures);
                try { Thread.sleep(RelayRetryPolicy.delayMillis(failures, error)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void syncRegistration(JSONObject registration) throws Exception {
        JSONObject payload = RelayRegistrationPayload.forRelay(registration);
        int hash = RelayRegistrationPayload.syncKey(registration).hashCode();
        // A Relay 401 means the device record is gone; re-post the unchanged registration. The
        // signal is one-shot, so a failed re-post waits for the next back-off window instead of
        // retrying every cycle.
        if (registrationRecovery.takeResync(android.os.SystemClock.elapsedRealtime())) {
            BridgeLog.info("standalone_relay_reregister reason=unauthorized");
        } else if (hash == syncedRegistrationHash) {
            return;
        }
        relay.postJSON(registration, "/v1/devices/register", payload, 15_000);
        syncedRegistrationHash = hash;
        store.recordSuccess();
        BridgeLog.info("standalone_relay_registration_synced");
    }

    private void sendHeartbeat(JSONObject registration) throws Exception {
        sendHeartbeat(registration, RelayEgressGate.shared.generation());
    }

    private void sendHeartbeat(JSONObject registration, RelayEgressGate.Generation generation) throws Exception {
        JSONObject heartbeat = identity(registration)
                .put("battery", AndroidBatteryStatus.snapshot(this))
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
        relay.postJSON(registration, "/v1/events/heartbeat", heartbeat, 12_000, generation);
        lastHeartbeat = System.currentTimeMillis();
        store.recordHeartbeat();
    }

    private void pollCommands(RelayCommandConfiguration.Snapshot<JSONObject> snapshot) throws Exception {
        var generation = RelayEgressGate.shared.generation();
        if (!generation.isCurrent()) return;
        if (!commandConfiguration.isCurrent(snapshot)) return;
        JSONObject registration = snapshot.registration();
        JSONObject batch = relay.postJSON(registration, "/v2/commands/pull", identity(registration), 12_000);
        JSONArray commands = batch.optJSONArray("commands");
        if (commands == null) return;
        for (int index = 0; index < commands.length(); index++) {
            if (!generation.isCurrent()) return;
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
                            () -> generation.isCurrent() && commandConfiguration.isCurrent(snapshot));
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
            if (!generation.isCurrent()) return;
            relay.postJSON(registration, "/v2/commands/complete", completion, 12_000);
            rememberCompleted(commandID);
        }
    }

    private void commandLoop() {
        while (running) {
            var generation = RelayEgressGate.shared.generation();
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
                while (running && generation.isCurrent() && commandConfiguration.isCurrent(snapshot)) {
                    try {
                        StandaloneWebSocket.Message message = socket.read();
                        if (message.opcode() != 1) continue;
                        JSONObject command = new JSONObject(new String(message.payload(), StandardCharsets.UTF_8));
                        if (!commandConfiguration.isCurrent(snapshot)) break;
                        if (!generation.isCurrent()) break;
                        if (!agentID(registration).equals(command.optString("target_agent_id"))) continue;
                        JSONObject result = StandaloneAgentGateway.get(this).executeCloudCommand(command,
                                () -> generation.isCurrent() && commandConfiguration.isCurrent(commandSnapshot));
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
        if (!RelayEgressGate.shared.isBlocked() && running && registration != null && !registration.optBoolean("local_mode",false)
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
        registrationRecovery.onFailure(error, now);
        RetryDecision decision = commandRetry.failedFor(epoch, now, connectedAt < 0 ? 0 : Math.max(0, now - connectedAt),
                error, java.util.concurrent.ThreadLocalRandom.current().nextDouble());
        if (decision == null) return;
        BridgeLog.info("standalone_command_retry reason=" + decision.reason() + " tier=" + decision.failures()
                + " delay_ms=" + decision.delayMillis() + " fallback=false");
    }

    private void flushCallEvents() {
        var generation = RelayEgressGate.shared.generation();
        if (store == null || !store.cloudEnabled()) return;
        JSONObject registration = store.registration();
        if (registration == null) return;
        synchronized (callEventLock) {
            for (int attempt = 0; attempt < 3; attempt++) {
                if (!generation.isCurrent()) return;
                String encoded = CALL_EVENTS.peek();
                if (encoded == null) return;
                try {
                    StandaloneCloudMediaManager.get(this).handleCallEvent(
                            registration, new JSONObject(encoded), relay);
                    if (!generation.isCurrent()) return;
                    CALL_EVENTS.poll();
                } catch (Exception error) {
                    if (!generation.isCurrent()) return;
                    if (callEventRetry.shouldDrop(encoded, error, android.os.SystemClock.elapsedRealtime())) {
                        // A refused or long-failing event must not hold every later event,
                        // including the "ended" that closes the cloud call, behind it.
                        CALL_EVENTS.poll();
                        BridgeLog.info("standalone_call_event_dropped " + CloudCallRetryPolicy.describe(error));
                        try {
                            StandaloneCloudMediaManager.get(this).abandonCallEvent(encoded);
                        } catch (RuntimeException abandonError) {
                            // The event is already out of the queue; escaping here would end the
                            // single event-worker thread and crash the process.
                            BridgeLog.error("standalone_call_event_drop_failed", abandonError);
                        }
                        continue;
                    }
                    BridgeLog.info("standalone_call_event_retry failures=" + (attempt + 1)
                            + " " + CloudCallRetryPolicy.describe(error));
                    try { Thread.sleep(500); } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                    if (attempt == 2) return;
                }
            }
        }
    }

    private synchronized SMSSnapshot smsSnapshot() {
        var generation = RelayEgressGate.shared.generation();
        var snapshot = commandConfiguration.snapshot();
        long epoch = smsTransport.configure(snapshot.scope() == null ? null : Long.toString(snapshot.epoch()));
        return new SMSSnapshot(snapshot, epoch, generation);
    }

    private void smsLoop() {
        while (running) {
            try {
                var snapshot = smsSnapshot();
                if (snapshot.generation().isCurrent() && snapshot.configuration().scope() != null) flushEvents(snapshot);
            } catch (Exception error) {
                BridgeLog.error("standalone_sms_cycle_failed", error);
            }
            try { Thread.sleep(2_000); }
            catch (InterruptedException stopped) { Thread.currentThread().interrupt(); return; }
        }
    }

    private void flushEvents(SMSSnapshot snapshot) throws Exception {
        JSONObject registration = snapshot.configuration().registration();
        var generation = snapshot.generation();
        StandaloneSMSStore smsStore = new StandaloneSMSStore(this);
        JSONArray smsPending = smsStore.cloudPending();
        Map<String, JSONObject> events = new LinkedHashMap<>();
        // With an E2E key for this registration every SMS goes up sealed (issue #24), never in plaintext.
        byte[] e2eKey = E2EKeyStore.forRegistration(this, registration);
        E2ESMSCrypto.Keys keys = e2eKey == null ? null : E2ESMSCrypto.keys(e2eKey);
        for (int index = 0; index < smsPending.length(); index++) {
            if (!generation.isCurrent()) return;
            JSONObject source = smsPending.getJSONObject(index);
            String timestamp = CloudSMSUploader.uploadTimestamp(source.optString("timestamp", ""), System.currentTimeMillis());
            events.put(source.getString("delivery_id"), CloudSMSEvent.body(identity(registration), source, timestamp, keys));
        }
        // One SMS the Relay refuses or cannot push must neither stall the others nor fail the agent cycle.
        smsUploader.flush(new ArrayList<>(events.keySet()),
                id -> relay.postJSON(registration, "/v1/events/sms", events.get(id), 12_000,
                        generation, smsTransport, snapshot.epoch()),
                new CloudSMSUploader.Ledger() {
                    public void settled(String id) throws Exception {
                        if (generation.isCurrent() && commandConfiguration.isCurrent(snapshot.configuration()) && smsTransport.isCurrent(snapshot.epoch()))
                            smsStore.markCloudSent(id);
                    }
                    public void rejected(String id) throws Exception {
                        if (generation.isCurrent() && commandConfiguration.isCurrent(snapshot.configuration()) && smsTransport.isCurrent(snapshot.epoch()))
                            smsStore.markCloudRejected(id);
                    }
                }, this::smsFailure, android.os.SystemClock::elapsedRealtime,
                () -> running && generation.isCurrent() && commandConfiguration.isCurrent(snapshot.configuration())
                        && smsTransport.isCurrent(snapshot.epoch()), keys != null);
    }

    private void smsFailure(Throwable smsError, CloudSMSUploader.Verdict verdict, int attempt, long pauseMillis) {
        registrationRecovery.onFailure(smsError, android.os.SystemClock.elapsedRealtime());
        if (verdict == CloudSMSUploader.Verdict.DROP) {
            BridgeLog.info("standalone_sms_upload_dropped attempt=" + attempt + " " + CloudCallRetryPolicy.describe(smsError));
        } else {
            BridgeLog.info("standalone_sms_upload_retry verdict=" + verdict.name().toLowerCase(java.util.Locale.ROOT)
                    + " attempt=" + attempt + " pause_ms=" + pauseMillis + " " + CloudCallRetryPolicy.describe(smsError));
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
        synchronized (START_LOCK) {
            if (instance == this) instance = null;
            startRequested = false;
        }
        eventWorker.shutdownNow();
        getSharedPreferences("standalone_agent", MODE_PRIVATE).unregisterOnSharedPreferenceChangeListener(commandPreferences);
        commandConfiguration.stop();
        smsTransport.configure(null);
        StandaloneWebSocket socket = commandSocket;
        if (socket != null) socket.close();
        worker.shutdownNow();
        SIMSlotObserver.stop(this);
        StandaloneCloudMediaManager.get(this).close();
        BridgeLog.info("standalone_agent_destroyed");
        super.onDestroy();
    }
}
