package com.airsim.phonecontrol.voble;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothGatt;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

import com.airsim.phonecontrol.AndroidAgentIdentity;
import com.airsim.phonecontrol.AppConfig;
import com.airsim.phonecontrol.BridgeLog;
import com.airsim.phonecontrol.CallRepository;
import com.airsim.phonecontrol.RuntimeMode;
import com.airsim.phonecontrol.SMSCommandExecutor;
import com.airsim.phonecontrol.SimSlotJson;
import com.airsim.phonecontrol.RemoteAudioSessionRegistry;
import com.airsim.phonecontrol.PureLocalModeCoordinator;
import com.airsim.phonecontrol.PureLocalModeRuntime;
import com.airsim.phonecontrol.PureLocalModeWire;

import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.net.InetSocketAddress;
import java.net.URI;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

public final class VoBLEGatewayService extends Service implements VoBLEGattServer.Listener {
    private static final String CHANNEL_ID = "airsim_voble";
    private static final int NOTIFICATION_ID = 4108;
    private static volatile VoBLEGatewayService instance;
    private static volatile VoBLEDiagnostics.Snapshot diagnostics =
            VoBLEDiagnostics.idle("Android");
    private static volatile String pendingPairingCode = "";

    public static String diagnosticsSummary() {
        return VoBLEDiagnostics.summary(diagnostics);
    }

    public static boolean isAuthenticated() {
        return diagnostics != null && diagnostics.authenticated();
    }

    public static String pendingPairingCode() {
        return pendingPairingCode;
    }

    public static boolean hasStoredCredential(Context context) {
        String identity = AndroidAgentIdentity.agentID(context);
        return VoBLECredentialStore.androidPrivatePreferences(context).hasCredential(identity);
    }

    /** Local recovery path for a stale iPhone credential. It never opens a remote reset endpoint. */
    public static void clearStoredCredential(Context context) {
        VoBLEGatewayService active = instance;
        if (active != null) {
            active.controlQueue.execute(active::revokeLocalCredential);
            return;
        }
        String identity = AndroidAgentIdentity.agentID(context);
        VoBLECredentialStore.androidPrivatePreferences(context).revoke(identity);
        pendingPairingCode = "";
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(context));
    }

    private record SessionContext(
            String deviceId, byte[] sessionId, String callId, long generation) {}

    private final ExecutorService controlQueue = Executors.newSingleThreadExecutor();
    private final ExecutorService mediaQueue = Executors.newSingleThreadExecutor();
    private final VoBLEControlChannel channel = new VoBLEControlChannel();
    private final AtomicLong generations = new AtomicLong();
    private final Map<String, Long> callGenerations = new ConcurrentHashMap<>();
    private final Map<String, String> peerIdentities = new ConcurrentHashMap<>();
    private final SecureRandom random = new SecureRandom();
    private VoBLEPairingManager pairingManager;
    private VoBLEGattServer gatt;
    private VoBLECallController calls;
    private final Object mediaLifecycleLock = new Object();
    private volatile boolean destroyed;
    private volatile VoBLEMediaSession media;
    private VoBLEMediaSession.Identity mediaIdentity;
    private volatile SessionContext session;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final AtomicLong advertisingRetries = new AtomicLong();
    private final Runnable advertisingRetry = () -> {
        if (destroyed) return;
        if (gatt == null || !gatt.hasBluetoothPermissions()) return;
        BridgeLog.info("voble_gatt_advertising_retry attempt=" + advertisingRetries.get());
        if (!gatt.start()) BridgeLog.info("voble_gatt_advertising_retry_blocked");
    };
    /** Bluetooth can be toggled after the foreground service starts; retry advertising on STATE_ON. */
    private final BroadcastReceiver bluetoothStateReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (intent == null || !BluetoothAdapter.ACTION_STATE_CHANGED.equals(intent.getAction())) return;
            int state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR);
            if (state == BluetoothAdapter.STATE_ON) {
                BridgeLog.info("voble_bluetooth_on_restart_advertising");
                advertisingRetries.set(0);
                mainHandler.removeCallbacks(advertisingRetry);
                if (gatt != null && gatt.hasBluetoothPermissions()) gatt.start();
            } else if (state == BluetoothAdapter.STATE_OFF) {
                BridgeLog.info("voble_bluetooth_off_close_advertising");
                mainHandler.removeCallbacks(advertisingRetry);
                if (gatt != null) gatt.close();
            }
        }
    };

    public static void start(Context context) {
        if (!hasPermissions(context)) return;
        Intent intent = new Intent(context, VoBLEGatewayService.class);
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
            else context.startService(intent);
        } catch (IllegalStateException | SecurityException restricted) {
            // Application/boot may run in the background. Retry when the Activity resumes;
            // do not let an expected platform restriction kill the app or clear pairing.
            BridgeLog.error("voble_service_start_deferred", restricted);
        }
    }

    public static boolean hasPermissions(Context context) {
        return Build.VERSION.SDK_INT < 31
                || (context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
                        == PackageManager.PERMISSION_GRANTED
                && context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
                        == PackageManager.PERMISSION_GRANTED);
    }

    public static void publishSMS(Context context, org.json.JSONObject event) {
        VoBLEGatewayService active = instance;
        if (active == null) {
            start(context);
            return;
        }
        active.controlQueue.execute(() -> active.publishSMS(event));
    }

    public static void publishCallState(
            Context context, String callId, String direction, String state, String number) {
        VoBLEGatewayService active = instance;
        if (active == null) {
            start(context);
            return;
        }
        active.controlQueue.execute(() -> active.publishCallState(callId, direction, state, number));
    }

    @Override public void onCreate() {
        super.onCreate();
        instance = this;
        createNotificationChannel();
        Notification notification = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("AirSIM 蓝牙通话")
                .setContentText("等待已认证的 iPhone")
                .setGroup(com.airsim.phonecontrol.BridgeNotification.GROUP)
                .setOnlyAlertOnce(true)
                .setOngoing(true).build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        VoBLECredentialStore credentials = VoBLECredentialStore.androidPrivatePreferences(this);
        pairingManager = new VoBLEPairingManager(credentials);
        calls = new VoBLECallController(request -> {
            CallRepository.ActionResult result = CallRepository.executeRemote(
                    VoBLEGatewayService.this, request.requestId(), request.action(), request.callId(),
                    request.number(), request.simAccount());
            return result.success
                    ? VoBLECallController.Result.success("accepted")
                    : VoBLECallController.Result.failure("telecom_failed", result.error);
        });
        gatt = new VoBLEGattServer(this, this, channel);
        try {
            IntentFilter filter = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(bluetoothStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
            } else {
                registerReceiver(bluetoothStateReceiver, filter);
            }
        } catch (RuntimeException error) {
            BridgeLog.error("voble_bluetooth_receiver_register_failed", error);
        }
        if (!gatt.start()) BridgeLog.info("voble_waiting_for_bluetooth_permission");
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        advertisingRetries.set(0);
        mainHandler.removeCallbacks(advertisingRetry);
        if (gatt != null && gatt.hasBluetoothPermissions() && !gatt.start()) {
            BridgeLog.info("voble_gatt_start_deferred");
        }
        return START_STICKY;
    }

    @Override public void onAdvertisingReady() {
        advertisingRetries.set(0);
        mainHandler.removeCallbacks(advertisingRetry);
    }

    @Override public void onAdvertisingFailed(int code) {
        mainHandler.removeCallbacks(advertisingRetry);
        long attempt = advertisingRetries.incrementAndGet();
        if (attempt > 3) {
            BridgeLog.info("voble_gatt_advertising_gave_up code=" + code);
            return;
        }
        long delay = 2000L << (attempt - 1);
        BridgeLog.info("voble_gatt_advertising_retry_scheduled attempt=" + attempt
                + " delay_ms=" + delay + " code=" + code);
        mainHandler.postDelayed(advertisingRetry, delay);
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public void onPairingWrite(String deviceId, byte[] value) {
        controlQueue.execute(() -> handlePairing(deviceId, value));
    }

    private void handlePairing(String deviceId, byte[] value) {
        try {
            JSONObject request = new JSONObject(new String(value, StandardCharsets.UTF_8));
            String operation = request.optString("op", "");
            BridgeLog.info("voble_pairing op=" + operation);
            JSONObject response = new JSONObject().put("version", 1).put("op", operation);
            String identity = AndroidAgentIdentity.agentID(this);
            if ("begin".equals(operation)) {
                pendingPairingCode = "";
                VoBLEPairingManager.Challenge challenge = pairingManager.begin(
                        identity, System.currentTimeMillis());
                response.put("challenge_id", challenge.id())
                        .put("android_identity", identity)
                        .put("android_public", base64(challenge.androidPublicKey()))
                        .put("android_nonce", base64(challenge.androidNonce()))
                        .put("expires_at_ms", challenge.expiresAtMillis());
            } else if ("prepare".equals(operation)) {
                VoBLEPairingManager.PairingMaterial material = pairingManager.preview(
                        request.getString("challenge_id"),
                        decode(request.getString("iphone_public")),
                        decode(request.getString("iphone_nonce")), System.currentTimeMillis());
                response.put("sas", material.sas());
                showPairingCode(material.sas());
            } else if ("confirm".equals(operation)) {
                if (!channel.canAuthenticate(deviceId)) {
                    throw new SecurityException("another central owns VoBLE");
                }
                VoBLEPairingManager.PairingMaterial material;
                if (request.has("reconnect_tag")) {
                    material = pairingManager.confirmReconnect(
                            request.getString("challenge_id"),
                            decode(request.getString("iphone_public")),
                            decode(request.getString("iphone_nonce")),
                            decode(request.getString("reconnect_tag")), System.currentTimeMillis());
                } else {
                    material = pairingManager.confirm(
                            request.getString("challenge_id"),
                            decode(request.getString("iphone_public")),
                            decode(request.getString("iphone_nonce")),
                            request.getString("sas"), System.currentTimeMillis());
                }
                if (!channel.authenticate(deviceId)) throw new SecurityException("another central owns VoBLE");
                peerIdentities.put(deviceId, identity);
                diagnostics = new VoBLEDiagnostics.Snapshot(
                        RuntimeMode.agentLabel(this), true, false, "G.711-mu/8000/mono",
                        0, 0, 0, "");
                publishDiagnostics();
                response.put("ready", true).put("sas", material.sas())
                        .put("confirmation_tag", base64(VoBLEPairingManager.confirmationTag(
                                material.pairingKey(), request.getString("challenge_id"))));
                showReadyNotification();
            } else {
                throw new IllegalArgumentException("unsupported pairing operation");
            }
            gatt.indicatePairing(deviceId, response.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) {
            BridgeLog.info("voble_pairing_failed type=" + error.getClass().getSimpleName());
            sendPairingError(deviceId, error.getMessage());
        }
    }

    @Override public void onControlWrite(String deviceId, byte[] value) {
        controlQueue.execute(() -> handleControl(deviceId, value));
    }

    private void handleControl(String deviceId, byte[] value) {
        try {
            if (!channel.isReady(deviceId)) throw new SecurityException("peer is not authenticated");
            VoBLEProtocol.ControlEnvelope envelope = VoBLEProtocol.decodeControl(value);
            JSONObject body = new JSONObject(new String(envelope.ciphertext(), StandardCharsets.UTF_8));
            long timestamp = body.getLong("timestamp_ms");
            String identity = peerIdentities.get(deviceId);
            if (identity == null) throw new SecurityException("peer identity is unavailable");
            byte[] authenticated = Arrays.copyOf(value, value.length - VoBLEProtocol.AUTH_TAG_LENGTH);
            boolean valid = pairingManager.authenticate(
                    identity, envelope.sessionId(), envelope.callId(), envelope.generation(),
                    envelope.nonce(), timestamp, authenticated,
                    envelope.authenticationTag(), System.currentTimeMillis());
            if (!valid) throw new SecurityException("control authentication failed");
            String requestId = body.getString("request_id");
            String action = normalizeAction(envelope.command());
            BridgeLog.info("voble_control_received command=" + action
                    + " generation=" + envelope.generation()
                    + " request_id=" + com.airsim.phonecontrol.DebugRedactor.safeIdentifier(requestId));
            // Reading fresh metadata or sending SMS must not replace an active
            // call's ID/generation.
            if ((!"device_info".equals(action) && !"sms_send".equals(action)
                    && !"local_mode_status".equals(action) && !"local_mode_set".equals(action)) || session == null) {
                session = new SessionContext(deviceId, envelope.sessionId(),
                        envelope.callId(), envelope.generation());
            }
            VoBLECallController.Request request = new VoBLECallController.Request(
                    requestId, action, envelope.callId(), body.optString("number", ""),
                    envelope.generation(), body.optString("sim_account", ""));
            VoBLECallController.Result result;
            boolean revokeAfterResponse = false;
            if ("local_mode_status".equals(action) || "local_mode_set".equals(action)) {
                PureLocalModeRuntime runtime = PureLocalModeRuntime.get(this);
                PureLocalModeCoordinator.Status status = "local_mode_status".equals(action)
                        ? runtime.status() : runtime.apply(PureLocalModeWire.command(body), "ble:" + identity);
                result = VoBLECallController.Result.success(PureLocalModeWire.status(status).toString());
            } else if ("sms_send".equals(action)) {
                String sent = SMSCommandExecutor.sendFromVoBLE(
                        this, requestId, body.optString("number", ""),
                        body.optString("message", ""), body.optString("sim_account", ""));
                result = sent.startsWith("ok:")
                        ? VoBLECallController.Result.success(sent.substring(3))
                        : VoBLECallController.Result.failure("sms_failed",
                                sent.startsWith("error:") ? sent.substring(6) : sent);
            } else if ("ping".equals(action)) {
                result = calls.executeOnce(request, true,
                        ignored -> VoBLECallController.Result.success("ready"));
            } else if ("device_info".equals(action)) {
                result = VoBLECallController.Result.success(new JSONObject()
                        .put("battery", com.airsim.phonecontrol.AndroidBatteryStatus.snapshot(this))
                        .put("agent_id", AndroidAgentIdentity.agentID(this))
                        .put("device_name", AndroidAgentIdentity.deviceName())
                        .put("agent_kind", RuntimeMode.isStandalone(this) ? "standalone" : "avf")
                        .put("call_generation", calls.currentGeneration())
                        .put("phone_number", AndroidAgentIdentity.phoneNumber(this))
                        .put("sim_slots", SimSlotJson.slots(this)).toString());
            } else if ("start_media".equals(action)) {
                result = calls.executeOnce(request, true,
                        ignored -> startMedia(deviceId, identity, envelope));
            } else if ("stop_media".equals(action)) {
                result = calls.executeOnce(request, true, ignored -> {
                    if (!calls.ownsCall(envelope.callId(), envelope.generation())) {
                        return VoBLECallController.Result.failure("call_mismatch");
                    }
                    stopMedia(envelope.callId(), envelope.generation());
                    return VoBLECallController.Result.success("stopped");
                });
            } else if ("unpair".equals(action)) {
                result = VoBLECallController.Result.success("unpaired");
                revokeAfterResponse = true;
            } else {
                result = calls.execute(request, true);
            }
            BridgeLog.info("voble_control_result command=" + action + " generation=" + envelope.generation()
                    + " success=" + result.success() + " code=" + result.code());
            try {
                sendControl(deviceId, envelope.sessionId(), envelope.callId(), envelope.generation(),
                        "response", new JSONObject().put("request_id", requestId)
                                .put("ok", result.success()).put("code", result.code())
                                .put("detail", result.detail()));
            } catch (Exception error) {
                BridgeLog.info("voble_control_response_failed type="
                        + error.getClass().getSimpleName()
                        + " detail=" + com.airsim.phonecontrol.DebugRedactor.sanitize(
                                error.getMessage() == null ? "none" : error.getMessage()));
                throw error;
            }
            if (revokeAfterResponse && result.success()) revokeAuthenticatedPeer(deviceId, identity);
        } catch (Exception error) {
            BridgeLog.info("voble_control_rejected reason="
                    + (error instanceof SecurityException ? "authentication_failed" : "invalid_request")
                    + " type=" + error.getClass().getSimpleName()
                    + " detail=" + com.airsim.phonecontrol.DebugRedactor.sanitize(
                            error.getMessage() == null ? "none" : error.getMessage()));
            sendPlainControlError(deviceId, error instanceof SecurityException
                    ? "authentication_failed" : "invalid_request");
        }
    }

    @Override public void onAudioWrite(String deviceId, byte[] value) {
        mediaQueue.execute(() -> {
            VoBLEMediaSession active = media;
            VoBLEMediaSession.Identity identity = mediaIdentity;
            if (!channel.owns(deviceId) || active == null || identity == null
                    || !active.onUplinkFragment(identity, value)) {
                BridgeLog.info("voble_audio_rejected_unowned_or_stale");
            }
        });
    }

    @Override public void onDisconnected(String deviceId) {
        controlQueue.execute(() -> {
            BridgeLog.info("voble_peer_disconnected");
            peerIdentities.remove(deviceId);
            SessionContext value = session;
            if (value != null && value.deviceId.equals(deviceId)) {
                session = null;
                stopMedia("", 0);
            }
            pendingPairingCode = "";
            diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        });
    }

    private void publishCallState(String callId, String direction, String state, String number) {
        // An empty Telecom ID is not an authoritative call identity. Publishing
        // generation 0 makes iOS reducers ignore the event and previously let an
        // empty session look like a pending outgoing owner.
        if (callId == null || callId.isBlank()) return;
        Long generation = callGenerations.get(callId);
        if (generation == null && !"ended".equals(state)) {
            SessionContext activeSession = session;
            boolean ownsPendingOutgoing = "outgoing".equals(direction)
                    && activeSession != null
                    && calls.ownsCall(activeSession.callId, activeSession.generation);
            if (ownsPendingOutgoing) {
                // `dial` starts with an iOS provisional ID. Android's first
                // Telecom event authoritatively replaces the ID, not the
                // generation; advancing both strands iOS on the old call.
                generation = activeSession.generation;
            } else {
                long candidate = generations.incrementAndGet();
                generation = Math.max(candidate, calls.currentGeneration() + 1);
            }
            generations.accumulateAndGet(generation, Math::max);
            callGenerations.put(callId, generation);
        }
        if (generation == null) return;
        boolean terminal = calls.observeCall(callId, generation, state);
        synchronized (mediaLifecycleLock) {
            VoBLEMediaSession current = media;
            if (!destroyed && !terminal && current != null && mediaIdentity != null
                    && mediaIdentity.generation() == generation && calls.ownsCall(callId, generation)) {
                synchronized (current) {
                    // A queued Telecom event must not re-register an owner after the
                    // PCM failure callback has already released it but before cleanup.
                    if (current.ready()) RemoteAudioSessionRegistry.ownCall(current, callId);
                }
            }
        }
        if ("ended".equals(state) && !terminal) return;
        SessionContext target = session;
        if (target != null && channel.isReady(target.deviceId)) {
            try {
                BridgeLog.info("voble_call_state state=" + state + " generation=" + generation);
                sendControl(target.deviceId, target.sessionId, callId, generation,
                        "call_state", new JSONObject().put("direction", direction).put("state", state)
                                .put("number", number == null ? "" : number));
            } catch (Exception error) {
                BridgeLog.error("voble_call_state_failed", error);
            }
        }
        if (terminal) callGenerations.remove(callId);
        if (terminal) stopMedia(callId, generation);
    }

    private void publishSMS(org.json.JSONObject event) {
        SessionContext target = session;
        if (target == null || !channel.isReady(target.deviceId)) return;
        try {
            sendControl(target.deviceId, target.sessionId, "", 0,
                    "sms_event", new org.json.JSONObject(event.toString()));
            BridgeLog.info("voble_sms_event_sent");
        } catch (Exception error) {
            BridgeLog.error("voble_sms_event_failed", error);
        }
    }

    private VoBLECallController.Result startMedia(
            String deviceId, String peerIdentity, VoBLEProtocol.ControlEnvelope envelope) {
        if (!calls.ownsCall(envelope.callId(), envelope.generation())) {
            return VoBLECallController.Result.failure("call_mismatch");
        }
        try {
            InetSocketAddress endpoint;
            if (RuntimeMode.isStandalone(this)) {
                endpoint = VoBLEPCMBackendResolver.resolve(
                        VoBLEPCMBackendResolver.Runtime.STANDALONE, "");
            } else {
                String host = URI.create(AppConfig.endpoint(this)).getHost();
                endpoint = VoBLEPCMBackendResolver.resolve(
                        VoBLEPCMBackendResolver.Runtime.AVF, host);
            }
            VoBLEPairingManager.SessionKeys keys = pairingManager.storedSessionKeys(
                    peerIdentity, envelope.sessionId(), envelope.callId(), envelope.generation());
            byte[] mediaKey = keys.media();
            try {
                stopMedia("", 0);
                VoBLEMediaSession next = new VoBLEMediaSession(
                        endpoint,
                        address -> VoBLEPCMBridgeSession.open(
                                address, VoBLEPCMBridgeSession.socketConnector()),
                        packet -> gatt.notifyAudioPacket(deviceId, packet),
                        failed -> {
                            RemoteAudioSessionRegistry.releaseCall(failed);
                            try {
                                controlQueue.execute(() -> {
                                    // Delayed failure from an old call cannot stop its replacement.
                                    if (media == failed) stopMedia("", 0);
                                });
                            } catch (java.util.concurrent.RejectedExecutionException destroyed) {
                                // Service teardown already releases/cleans up its current media.
                            }
                        });
                VoBLEMediaSession.Identity identity = new VoBLEMediaSession.Identity(
                        envelope.callId(), envelope.generation());
                next.start(identity, mediaKey);
                synchronized (mediaLifecycleLock) {
                    synchronized (next) {
                        // Socket reads may complete after shutdownNow; publication
                        // and service teardown must share the same lifecycle lock.
                        if (destroyed || !next.ready()) {
                            next.close();
                            throw new java.io.IOException("PCM gateway stopped during startup");
                        }
                        media = next;
                        mediaIdentity = identity;
                        if (CallRepository.callIDs().contains(envelope.callId())) {
                            RemoteAudioSessionRegistry.ownCall(next, envelope.callId());
                        }
                        RemoteAudioSessionRegistry.setVoBLE(true);
                    }
                }
                diagnostics = new VoBLEDiagnostics.Snapshot(
                        RuntimeMode.agentLabel(this), true, true, "G.711-mu/8000/mono",
                        0, 0, 0, "");
                publishDiagnostics();
                BridgeLog.info("voble_media_started call_generation=" + envelope.generation());
                return VoBLECallController.Result.success("media_ready");
            } finally {
                Arrays.fill(mediaKey, (byte) 0);
            }
        } catch (Exception error) {
            BridgeLog.error("voble_media_start_failed", error);
            return VoBLECallController.Result.failure("pcm_unavailable", error.getClass().getSimpleName());
        }
    }

    private void stopMedia(String callId, long generation) {
        synchronized (mediaLifecycleLock) {
            VoBLEMediaSession.Identity identity = mediaIdentity;
            if (identity != null && callId != null && !callId.isEmpty()
                    && (!identity.callId().equals(callId) || identity.generation() != generation)) return;
            VoBLEMediaSession active = media;
            if (active != null) RemoteAudioSessionRegistry.releaseCall(active);
            media = null;
            mediaIdentity = null;
            RemoteAudioSessionRegistry.setVoBLE(false);
            if (active != null) {
                BridgeLog.info("voble_media_stopped");
                VoBLEMediaSession.Stats stats = active.stats();
                diagnostics = new VoBLEDiagnostics.Snapshot(
                        RuntimeMode.agentLabel(this), session != null, false,
                        "G.711-mu/8000/mono", stats.downlinkFrames(), stats.uplinkFrames(),
                        stats.droppedFrames(), "");
                publishDiagnostics();
                active.close();
            }
        }
    }

    private void revokeLocalCredential() {
        String identity = AndroidAgentIdentity.agentID(this);
        pairingManager.revoke(identity);
        for (String deviceId : peerIdentities.keySet()) {
            channel.revokeOwnerAndDisconnect(deviceId, () -> {
                VoBLEGattServer active = gatt;
                if (active != null) active.disconnectPeer(deviceId);
            });
        }
        peerIdentities.clear();
        session = null;
        pendingPairingCode = "";
        stopMedia("", 0);
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        publishDiagnostics();
        BridgeLog.info("voble_pairing_cleared_locally");
    }

    private void revokeAuthenticatedPeer(String deviceId, String identity) {
        pairingManager.revoke(identity);
        channel.revokeOwner(deviceId);
        peerIdentities.remove(deviceId);
        SessionContext current = session;
        if (current != null && current.deviceId.equals(deviceId)) session = null;
        pendingPairingCode = "";
        stopMedia("", 0);
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        publishDiagnostics();
        BridgeLog.info("voble_pairing_revoked_by_authenticated_peer");
    }

    private void publishDiagnostics() {
        VoBLEGattServer active = gatt;
        if (active == null) return;
        active.updateDiagnostics(new JSONObject(diagnostics.sanitizedFields())
                .toString().getBytes(StandardCharsets.UTF_8));
    }

    private void sendControl(
            String deviceId, byte[] sessionId, String callId, long generation,
            String command, JSONObject body) throws Exception {
        long timestamp = System.currentTimeMillis();
        body.put("timestamp_ms", timestamp);
        byte[] nonce = new byte[12];
        random.nextBytes(nonce);
        byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
        VoBLEProtocol.ControlEnvelope unsigned = new VoBLEProtocol.ControlEnvelope(
                command, callId == null ? "" : callId, generation,
                sessionId, nonce, payload, new byte[16]);
        byte[] encoded = VoBLEProtocol.encodeControl(unsigned);
        byte[] prefix = Arrays.copyOf(encoded, encoded.length - VoBLEProtocol.AUTH_TAG_LENGTH);
        String identity = peerIdentities.get(deviceId);
        byte[] tag = pairingManager.signSessionMessage(
                identity, sessionId, callId, generation, nonce, timestamp, prefix);
        VoBLEProtocol.ControlEnvelope signed = new VoBLEProtocol.ControlEnvelope(
                command, callId == null ? "" : callId, generation,
                sessionId, nonce, payload, tag);
        byte[] signedBytes = VoBLEProtocol.encodeControl(signed);
        BridgeLog.info("voble_control_response_bytes bytes=" + signedBytes.length);
        boolean sent = gatt.indicateControl(deviceId, signedBytes);
        BridgeLog.info("voble_control_response_enqueued sent=" + sent);
    }

    private void sendPairingError(String deviceId, String detail) {
        try {
            JSONObject response = new JSONObject().put("ok", false)
                    .put("error", detail == null ? "pairing_failed" : detail);
            gatt.indicatePairing(deviceId, response.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {}
    }

    private void sendPlainControlError(String deviceId, String code) {
        try {
            JSONObject response = new JSONObject().put("ok", false).put("code", code);
            gatt.indicateControl(deviceId, response.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) {
            BridgeLog.info("voble_control_error_send_failed type=" + error.getClass().getSimpleName());
        }
    }

    private static String normalizeAction(String command) {
        return switch (command) {
            case "hangup" -> "end";
            default -> command;
        };
    }

    private static String base64(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private static byte[] decode(String value) { return Base64.getUrlDecoder().decode(value); }

    private void createNotificationChannel() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) manager.createNotificationChannel(new NotificationChannel(
                CHANNEL_ID, "AirSIM 蓝牙通话", NotificationManager.IMPORTANCE_LOW));
    }

    private void showPairingCode(String sas) {
        pendingPairingCode = sas == null ? "" : sas;
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) return;
        manager.notify(NOTIFICATION_ID, new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("AirSIM 蓝牙配对")
                .setContentText("安全码 " + sas + " · 请与 iPhone 核对")
                .setGroup(com.airsim.phonecontrol.BridgeNotification.GROUP)
                .setOnlyAlertOnce(true)
                .setOngoing(true).build());
    }

    private void showReadyNotification() {
        pendingPairingCode = "";
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) return;
        manager.notify(NOTIFICATION_ID, new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("AirSIM 蓝牙通话")
                .setContentText("已连接经过认证的 iPhone")
                .setGroup(com.airsim.phonecontrol.BridgeNotification.GROUP)
                .setOnlyAlertOnce(true)
                .setOngoing(true).build());
    }

    @Override public void onDestroy() {
        synchronized (mediaLifecycleLock) {
            destroyed = true;
            stopMedia("", 0);
        }
        if (instance == this) instance = null;
        pendingPairingCode = "";
        diagnostics = VoBLEDiagnostics.idle(RuntimeMode.agentLabel(this));
        mainHandler.removeCallbacks(advertisingRetry);
        try {
            unregisterReceiver(bluetoothStateReceiver);
        } catch (RuntimeException ignored) {
            // Already unregistered by the platform during shutdown.
        }
        controlQueue.shutdownNow();
        mediaQueue.shutdownNow();
        if (gatt != null) gatt.close();
        super.onDestroy();
    }
}
