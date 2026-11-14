package com.airsim.phonecontrol;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.IBinder;
import android.os.Handler;
import android.os.Looper;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import rikka.shizuku.Shizuku;

final class ShizukuBridgeManager {
    interface DialerRoleCallback {
        void onResult(boolean success, String detail);
    }

    static final int PERMISSION_REQUEST = 7301;
    static final String MANAGER_PACKAGE = "moe.shizuku.privileged.api";
    static final String DOWNLOAD_URL = "https://shizuku.rikka.app/zh-hans/download/";
    record StartupSnapshot(boolean installed, boolean running, boolean authorized) {}
    private static volatile ShizukuBridgeManager instance;

    private final Context app;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final ExecutorService rootWorker = Executors.newSingleThreadExecutor();
    private final AtomicBoolean rootStartInFlight = new AtomicBoolean();
    private final java.util.concurrent.atomic.AtomicLong privilegeGeneration = new java.util.concurrent.atomic.AtomicLong();
    private final PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
    private final MuteRequestRetrier muteRetrier;
    private final AtomicBoolean statusRefreshInFlight = new AtomicBoolean();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object roleLock = new Object();
    private final Shizuku.UserServiceArgs serviceArgs;
    private volatile String status = "等待权限通道";
    private volatile boolean binding;
    private final ServiceBindAttempt bindAttempt = new ServiceBindAttempt();
    private volatile ServiceConnection connection;
    private volatile PrivilegedBridgeClient privilegedClient;
    private volatile RootBridgeTransport rootTransport;
    private volatile PrivilegeChannelPreference.Channel channel;
    private final java.util.concurrent.atomic.AtomicLong audioWatchdogGeneration = new java.util.concurrent.atomic.AtomicLong();
    private volatile boolean audioWatchdogActive;
    private String audioWatchdogKey = "";
    private final ExecutorService audioProbeWorker = Executors.newSingleThreadExecutor();
    private final AtomicBoolean audioProbeInFlight = new AtomicBoolean();
    private volatile String lastPCMHealthReport = "";
    private final AudioHealthReportCache audioHealthReport = new AudioHealthReportCache();
    private volatile long lastPCMHealthLogAt;
    private DialerRoleCallback pendingRoleCallback;
    private boolean roleRequestInFlight;

    private final Shizuku.OnBinderReceivedListener binderReceived = this::onBinderReceived;
    private final Shizuku.OnBinderDeadListener binderDead = this::onBinderDead;
    private final Shizuku.OnRequestPermissionResultListener permissionResult = (requestCode, grantResult) -> {
        if (channel == PrivilegeChannelPreference.Channel.ROOT || rootTransport != null) return;
        if (requestCode != PERMISSION_REQUEST) return;
        if (grantResult == PackageManager.PERMISSION_GRANTED) {
            BridgeLog.info("shizuku_permission_granted");
            bindPrivilegedService();
        } else {
            status = "Shizuku 授权被拒绝";
            BridgeLog.info("shizuku_permission_denied");
            finishDialerRoleRequest(false, "Shizuku 授权被拒绝");
        }
    };

    private ServiceConnection newConnection(long attempt, long generation) { return new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            worker.execute(() -> {
                if (connection != this || !bindAttempt.connected(attempt)) return;
                binding = false;
                if (!PrivilegeChannelGate.accepts(generation, privilegeGeneration.get()) || !shizukuAllowed()) return;
                try {
                    PrivilegedBridgeClient client = new PrivilegedBridgeClient(binder);
                    privilegedClient = client;
                    coordinator.connect(client);
                    status = "Shizuku 已连接 · " + client.status();
                    BridgeLog.info("shizuku_user_service_connected " + status);
                    runPendingDialerRoleRequest(client);
                } catch (Exception error) {
                    status = "Shizuku 服务启动失败";
                    privilegedClient = null;
                    coordinator.disconnect();
                    BridgeLog.error("shizuku_user_service_connect_failed", error);
                    finishDialerRoleRequest(false, "Shizuku 服务启动失败");
                }
            });
        }

        @Override public void onServiceDisconnected(ComponentName name) {
            worker.execute(() -> {
                if (connection != this) return;
                bindAttempt.cancel();
                binding = false;
                if (generation != privilegeGeneration.get() || channel == PrivilegeChannelPreference.Channel.ROOT || rootTransport != null) return;
                privilegedClient = null;
                coordinator.disconnect();
                status = "Shizuku 服务已断开";
                BridgeLog.info("shizuku_user_service_disconnected");
                finishDialerRoleRequest(false, "Shizuku 服务已断开");
            });
        }
    }; }

    private ShizukuBridgeManager(Context context) {
        app = context.getApplicationContext();
        try { coordinator.setOutputPolicy(AppConfig.callAudioVolumePolicy(app)); }
        catch (Exception error) { throw new IllegalStateException(error); }
        muteRetrier = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
            @Override public void execute(Runnable task) { worker.execute(task); }
            @Override public void schedule(Runnable task, long delayMillis) {
                mainHandler.postDelayed(() -> worker.execute(task), delayMillis);
            }
        }, coordinator::setLocalOutputMuted, (muted, error) -> {

            if (error != null) {
                status = "本机通话音量控制失败";
                BridgeLog.error("shizuku_local_output_failed target_muted=" + muted, error);
            } else if (coordinator.connected()) {
                String channel = rootTransport != null ? "Root" : "Shizuku";
                status = channel + " 已连接 · " + coordinator.lastResult();
                BridgeLog.info((rootTransport != null ? "root" : "shizuku")
                        + "_local_output target_muted=" + muted
                        + " result=" + coordinator.lastResult());
            } else {
                BridgeLog.info("privileged_local_output_queued target_muted=" + muted);
            }
            // Persist both mute and restore outcomes even when ordinary Debug logging
            // is disabled. A queued intent is not a verified privileged operation.
            BridgeLog.watchdog("audio_watchdog phase=" + (muted ? "mute" : "restore")
                    + " success=" + (error == null && coordinator.connected())
                    + " result=" + coordinator.lastResult()
                    + " error=" + (error == null ? "none" : error.getClass().getSimpleName())
                    + " acoustic_check=unavailable");
        });
        serviceArgs = new Shizuku.UserServiceArgs(new ComponentName(
                app.getPackageName(), ShizukuBridgeUserService.class.getName()))
                .daemon(true)
                .processNameSuffix("pcm_shell")
                .debuggable(true)
                .tag("airsim-pcm-v1")
                // Bump when the embedded bridge or its lifecycle changes so an
                // APK update cannot keep Vivo/Samsung running an old daemon.
                .version(AppInformation.privilegedServiceVersion(app));
        channel = PrivilegeChannelPreference.get(app);
        startRootChannel();
        Shizuku.addBinderReceivedListenerSticky(binderReceived);
        Shizuku.addBinderDeadListener(binderDead);
        Shizuku.addRequestPermissionResultListener(permissionResult);
        SMSCommandExecutor.setPrivilegedSender(this::sendSms);
        DefaultCallAccount.setSubscriptionResolver(this::resolveSmsSubscription);
    }

    static ShizukuBridgeManager initialize(Context context) {
        return get(context);
    }

    static ShizukuBridgeManager get(Context context) {
        ShizukuBridgeManager value = instance;
        if (value != null) return value;
        synchronized (ShizukuBridgeManager.class) {
            if (instance == null) instance = new ShizukuBridgeManager(context);
            return instance;
        }
    }

    private void startRootChannel() {
        if (!PrivilegeChannelGate.canStartRoot(channel.name(), rootTransport != null, rootStartInFlight.get())) return;
        if (!rootStartInFlight.compareAndSet(false, true)) return;
        long generation = privilegeGeneration.get();
        rootWorker.execute(() -> {
            try {
                RootBridgeTransport root = RootBridgeTransport.start(app);
                worker.execute(() -> {
                    try {
                        if (!PrivilegeChannelGate.accepts(generation, privilegeGeneration.get())) root.close();
                        else connectRoot(root);
                    } finally {
                        rootStartInFlight.set(false);
                        resumeSelectedChannel(generation);
                    }
                });
            } catch (Throwable error) {
                // Root is optional: a missing su, SELinux denial or class-loading
                // error must degrade to Shizuku instead of killing the app.
                BridgeLog.info("root_bridge_unavailable " + error.getClass().getSimpleName());
                worker.execute(() -> {
                    rootStartInFlight.set(false);
                    if (generation == privilegeGeneration.get()) status = channel == PrivilegeChannelPreference.Channel.ROOT
                            ? "Root 未授权或不可用" : "Root 不可用，等待 Shizuku";
                    resumeSelectedChannel(generation);
                });
            }
        });
    }

    private boolean shizukuAllowed() {
        return PrivilegeChannelGate.canBindShizuku(channel.name(), rootTransport != null, rootStartInFlight.get());
    }

    private void resumeSelectedChannel(long completedGeneration) {
        // A late Root result must not resurrect an older selection. A new explicit
        // Root selection may retry once after the old in-flight attempt drains.
        if (completedGeneration != privilegeGeneration.get()
                && channel != PrivilegeChannelPreference.Channel.SHIZUKU) {
            startRootChannel();
        } else if (shizukuAllowed()) {
            try {
                if (Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) bindPrivilegedService();
            } catch (RuntimeException error) { BridgeLog.error("shizuku_fallback_failed", error); }
        }
    }

    private void connectRoot(RootBridgeTransport root) {
        synchronized (this) {
            if (channel == PrivilegeChannelPreference.Channel.SHIZUKU) {
                root.close();
                return;
            }
            if (rootTransport != null) {
                root.close();
                return;
            }
            try {
                disconnectShizuku();
                rootTransport = root;
                coordinator.connect(root);
                status = "Root 已连接 · " + root.status();
                BridgeLog.info("root_bridge_connected " + status);
                runPendingRootDialerRoleRequest(root);
            } catch (Exception error) {
                rootTransport = null;
                coordinator.disconnect();
                root.close();
                status = "Root PCM 启动失败";
                BridgeLog.error("root_bridge_connect_failed", error);
            }
        }
    }

    void setPrivilegeChannel(PrivilegeChannelPreference.Channel value) {
        if (value == null) return;
        if (value == channel) {
            if (value == PrivilegeChannelPreference.Channel.ROOT && rootTransport == null) {
                startRootChannel();
            }
            return;
        }
        channel = value;
        long generation = privilegeGeneration.incrementAndGet();
        bindAttempt.cancel();
        binding = false;
        PrivilegeChannelPreference.set(app, value);
        status = "正在切换权限通道…";
        BridgeLog.info("privilege_channel=" + value.name().toLowerCase());
        worker.execute(() -> {
            if (generation != privilegeGeneration.get()) return;
            try {
                if (value == PrivilegeChannelPreference.Channel.SHIZUKU) {
                    stopRootChannel();
                    if (Shizuku.pingBinder()
                            && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                        bindPrivilegedService();
                    } else {
                        status = "等待 Shizuku 授权";
                    }
                } else if (value == PrivilegeChannelPreference.Channel.ROOT) {
                    disconnectShizuku();
                    startRootChannel();
                } else {
                    if (rootTransport == null && !rootStartInFlight.get()) startRootChannel();
                    if (rootTransport == null && !rootStartInFlight.get()
                            && Shizuku.pingBinder()
                            && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                        bindPrivilegedService();
                    }
                }
            } catch (Throwable error) {
                status = "权限通道切换失败";
                BridgeLog.error("privilege_channel_switch_failed", error);
            }
        });
    }

    void requestRootPermission() {
        if (channel != PrivilegeChannelPreference.Channel.AUTO
                && channel != PrivilegeChannelPreference.Channel.ROOT) {
            setPrivilegeChannel(PrivilegeChannelPreference.Channel.ROOT);
            return;
        }
        startRootChannel();
    }

    private void stopRootChannel() {
        RootBridgeTransport old;
        synchronized (this) {
            old = rootTransport;
            rootTransport = null;
            if (privilegedClient == null) coordinator.disconnect();
        }
        if (old != null) old.close();
    }

    private void disconnectShizuku() {
        bindAttempt.cancel();
        // Merely dropping the Binder leaves the daemon's restart loop running.
        // Removal stops that supervisor before Root can own PCM.
        if (Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            Shizuku.unbindUserService(serviceArgs, connection, true);
            // remove=true stops the server but v13's client connection registry
            // remains cached. Detach it too before creating a fresh attempt.
            Shizuku.unbindUserService(serviceArgs, connection, false);
        }
        connection = null;
        privilegedClient = null;
        binding = false;
        if (rootTransport == null) coordinator.disconnect();
    }

    private void onBinderReceived() {
        if (!shizukuAllowed()) return;
        try {
            int uid = Shizuku.getUid();
            int version = Shizuku.getVersion();
            status = "Shizuku 在线 · UID " + uid;
            BridgeLog.info("shizuku_binder_received uid=" + uid + " version=" + version);
            if (Shizuku.isPreV11() || version < 13) {
                status = "Shizuku 版本过低，需要 v13+";
                return;
            }
            if (!PrivilegedBridgeProtocol.supportsUid(uid)) {
                status = "Shizuku 权限身份无效";
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                bindPrivilegedService();
            } else {
                status = "Shizuku 在线，等待授权";
            }
        } catch (RuntimeException error) {
            status = "Shizuku 检测失败";
            BridgeLog.error("shizuku_binder_check_failed", error);
        }
    }

    private void onBinderDead() {
        bindAttempt.cancel();
        binding = false;
        long generation = privilegeGeneration.get();
        worker.execute(() -> {
            if (generation != privilegeGeneration.get() || channel == PrivilegeChannelPreference.Channel.ROOT || rootTransport != null) return;
            privilegedClient = null;
            coordinator.disconnect();
            status = "Shizuku 未运行";
            BridgeLog.info("shizuku_binder_dead");
            finishDialerRoleRequest(false, "Shizuku 未运行");
        });
    }

    void requestPermission() {
        bindAttempt.cancel();
        binding = false;
        if (channel == PrivilegeChannelPreference.Channel.ROOT) {
            startRootChannel();
            return;
        }
        if (rootTransport != null) {
            status = "Root 已连接";
            return;
        }
        try {
            if (!Shizuku.pingBinder()) {
                status = "请先启动 Shizuku";
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                bindPrivilegedService();
            } else if (Shizuku.shouldShowRequestPermissionRationale()) {
                status = "请在 Shizuku 中允许 AirSIM";
            } else {
                Shizuku.requestPermission(PERMISSION_REQUEST);
                status = "等待 Shizuku 授权";
            }
        } catch (RuntimeException error) {
            status = "Shizuku 请求失败";
            BridgeLog.error("shizuku_permission_request_failed", error);
        }
    }

    void ensureStarted() {
        if (channel == PrivilegeChannelPreference.Channel.ROOT) {
            if (rootTransport == null) startRootChannel();
            return;
        }
        if (rootTransport != null) {
            status = "Root 已连接";
            return;
        }
        if (!Shizuku.pingBinder()) {
            status = "Shizuku 未运行";
            return;
        }
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            status = "Shizuku 在线，等待授权";
            return;
        }
        bindPrivilegedService();
    }

    /** Resolve only an exact enabled account through the existing authorized service. */
    String smsPreflight() {
        PrivilegedBridgeClient client = privilegedClient;
        if (client == null) return "unavailable";
        try { return client.smsPreflight(); }
        catch (Exception error) { return "error:" + error.getClass().getSimpleName(); }
    }

    private int resolveSmsSubscription(String key) {
        // Use only the already-authorized selected privilege channel; never launch
        // root or request new privileges as a side effect of reading SIM metadata.
        if (rootTransport != null || channel == PrivilegeChannelPreference.Channel.ROOT) return -1;
        PrivilegedBridgeClient client = privilegedClient;
        if (client == null) return -1;
        try { return client.resolveSmsSubscription(key); }
        catch (android.os.RemoteException | RuntimeException error) { return -1; }
    }

    /** Read recent inbox rows as shell (Shizuku); null when unavailable. */
    String recentSms(long afterId, long cutoffMillis, int limit) {
        if (rootTransport != null) return null; // Root inbox bridge is not implemented.
        if (channel == PrivilegeChannelPreference.Channel.ROOT) return null;
        PrivilegedBridgeClient client = privilegedClient;
        if (client == null) return null;
        try {
            return client.recentSms(afterId, cutoffMillis, limit);
        } catch (android.os.RemoteException error) {
            return null;
        }
    }

    String sendSms(String destination, String body, int subscriptionId) {
        RootBridgeTransport root = rootTransport;
        if (root != null) {
            try {
                return root.sendSms(destination, body, subscriptionId);
            } catch (Exception error) {
                return "error:root";
            }
        }
        if (channel == PrivilegeChannelPreference.Channel.ROOT) return "unavailable";
        PrivilegedBridgeClient client = privilegedClient;
        if (client == null) return "unavailable";
        return PrivilegedSmsConfirmation.send(app, destination, body, subscriptionId,
                callbacks -> client.sendSms(destination, body, subscriptionId, callbacks));
    }

    boolean dialerRoleAutomationAuthorized() {
        if (rootTransport != null) return true;
        if (channel == PrivilegeChannelPreference.Channel.ROOT) return false;
        try {
            return Shizuku.pingBinder()
                    && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED;
        } catch (RuntimeException error) {
            return false;
        }
    }

    boolean dialerRoleAutomationAvailable() {
        if (rootTransport != null) return true;
        if (channel == PrivilegeChannelPreference.Channel.ROOT) return false;
        try { return Shizuku.pingBinder(); }
        catch (RuntimeException error) { return false; }
    }

    StartupSnapshot startupSnapshot() {
        if (rootTransport != null || rootStartInFlight.get()
                || channel == PrivilegeChannelPreference.Channel.ROOT) {
            return new StartupSnapshot(true, true, true);
        }
        boolean installed = false;
        try {
            app.getPackageManager().getPackageInfo(MANAGER_PACKAGE, 0);
            installed = true;
        } catch (PackageManager.NameNotFoundException ignored) {
            // Both APK manifests declare package visibility for the manager.
        } catch (RuntimeException error) {
            BridgeLog.error("shizuku_package_check_failed", error);
        }
        boolean running = dialerRoleAutomationAvailable();
        return new StartupSnapshot(installed || running, running,
                running && dialerRoleAutomationAuthorized());
    }

    void ensureDialerRole(boolean requestPermission, DialerRoleCallback callback) {
        synchronized (roleLock) {
            pendingRoleCallback = callback;
        }
        RootBridgeTransport root = rootTransport;
        if (root != null) {
            runPendingRootDialerRoleRequest(root);
            return;
        }
        if (channel == PrivilegeChannelPreference.Channel.ROOT) {
            finishDialerRoleRequest(false, "Root 未授权或不可用");
            return;
        }
        try {
            if (!Shizuku.pingBinder()) {
                finishDialerRoleRequest(false, "Shizuku 未运行");
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                PrivilegedBridgeClient client = privilegedClient;
                if (client != null) runPendingDialerRoleRequest(client);
                else bindPrivilegedService();
                return;
            }
            if (!requestPermission) {
                finishDialerRoleRequest(false, "Shizuku 尚未授权");
            } else if (Shizuku.shouldShowRequestPermissionRationale()) {
                finishDialerRoleRequest(false, "请在 Shizuku 中允许 AirSIM");
            } else {
                status = "等待 Shizuku 授权";
                Shizuku.requestPermission(PERMISSION_REQUEST);
            }
        } catch (RuntimeException error) {
            BridgeLog.error("shizuku_dialer_role_prepare_failed", error);
            finishDialerRoleRequest(false, "Shizuku 请求失败");
        }
    }

    private void runPendingRootDialerRoleRequest(RootBridgeTransport root) {
        DialerRoleCallback callback;
        synchronized (roleLock) {
            if (pendingRoleCallback == null || roleRequestInFlight) return;
            roleRequestInFlight = true;
            callback = pendingRoleCallback;
        }
        worker.execute(() -> {
            try {
                String result = root.ensureDialerRole();
                BridgeLog.info("root_dialer_role_applied result=" + result);
                finishDialerRoleRequest(callback, true, result);
            } catch (Exception error) {
                BridgeLog.error("root_dialer_role_failed", error);
                finishDialerRoleRequest(callback, false, "系统未接受默认电话角色");
            }
        });
    }

    private void runPendingDialerRoleRequest(PrivilegedBridgeClient client) {
        DialerRoleCallback callback;
        synchronized (roleLock) {
            if (pendingRoleCallback == null || roleRequestInFlight) return;
            roleRequestInFlight = true;
            callback = pendingRoleCallback;
        }
        worker.execute(() -> {
            try {
                String result = client.ensureDialerRole();
                BridgeLog.info("shizuku_dialer_role_applied result=" + result);
                finishDialerRoleRequest(callback, true, result);
            } catch (Exception error) {
                BridgeLog.error("shizuku_dialer_role_failed", error);
                finishDialerRoleRequest(callback, false, "系统未接受默认电话角色");
            }
        });
    }

    private void finishDialerRoleRequest(boolean success, String detail) {
        DialerRoleCallback callback;
        synchronized (roleLock) {
            callback = pendingRoleCallback;
        }
        if (callback != null) finishDialerRoleRequest(callback, success, detail);
    }

    private void finishDialerRoleRequest(
            DialerRoleCallback callback, boolean success, String detail) {
        boolean deliver;
        synchronized (roleLock) {
            deliver = pendingRoleCallback == callback;
            if (deliver) pendingRoleCallback = null;
            roleRequestInFlight = false;
        }
        if (deliver) mainHandler.post(() -> callback.onResult(success, detail));
    }

    void refreshCallAudioVolumePolicy() {
        worker.execute(() -> {
            try {
                coordinator.setOutputPolicy(AppConfig.callAudioVolumePolicy(app));
                status = coordinator.connected() ? "音量策略已应用 · " + coordinator.lastResult() : "音量策略已保存，等待权限服务连接";
                BridgeLog.info("call_audio_volume_policy=" + AppConfig.callAudioVolumePolicy(app));
            } catch (Exception error) {
                status = "音量策略应用失败，请重新启动权限服务";
                BridgeLog.error("call_audio_volume_policy_failed", error);
            }
        });
    }

    void setLocalOutputMuted(boolean muted) {
        setLocalOutputMuted(muted, PrivilegedBridgeProtocol.TRANSPORT_VOWLAN);
    }

    /** VoBLE and VoWLAN need different stream policies; other callers default to VoWLAN. */
    void setLocalOutputMuted(boolean muted, String transport) {
        muteRetrier.requestWithTransport(muted, transport);
    }

    // Invalidate queued checks immediately when the remote owner or native call changes.
    synchronized void updateAudioWatchdog(boolean active, String key, String transports) {
        if (audioWatchdogActive == active && audioWatchdogKey.equals(key)) return;
        audioWatchdogActive = active;
        audioWatchdogKey = key;
        long generation = audioWatchdogGeneration.incrementAndGet();
        if (!active) {
            worker.execute(() -> BridgeLog.watchdog("audio_watchdog phase=stop generation=" + generation));
            return;
        }
        worker.execute(() -> {
            if (!watchdogCurrent(generation)) return;
            BridgeLog.watchdog("audio_watchdog phase=start generation=" + generation + " " + transports
                    + " app=" + AppInformation.version(app) + " sdk=" + android.os.Build.VERSION.SDK_INT
                    + " manufacturer=" + android.os.Build.MANUFACTURER + " model=" + android.os.Build.MODEL);
            RemoteAudioWatchdog monitor = new RemoteAudioWatchdog(new RemoteAudioWatchdog.Backend() {
                public AudioWatchdogSnapshot probe() throws Exception { return boundedAudioProbe(); }
                public void repair(int step) throws Exception {
                    if (!watchdogCurrent(generation)) return;
                    if (step >= 2) AirSIMInCallService.refreshAudioPolicy();
                    if (step >= 3 && !coordinator.connected()) recoverWatchdogTransport(generation);
                    if (watchdogCurrent(generation)) coordinator.reassertLocalOutputMuted();
                }
                public void reconnect() { recoverWatchdogTransport(generation); }
            }, value -> BridgeLog.watchdog("generation=" + generation + " " + value));
            runAudioWatchdog(monitor, generation);
        });
    }

    private boolean watchdogCurrent(long generation) {
        return audioWatchdogActive && audioWatchdogGeneration.get() == generation;
    }

    private void runAudioWatchdog(RemoteAudioWatchdog monitor, long generation) {
        if (!watchdogCurrent(generation)) return;
        monitor.tick(android.os.SystemClock.elapsedRealtime(),
                () -> watchdogCurrent(generation) && coordinator.desiredMuted());
        if (watchdogCurrent(generation)) mainHandler.postDelayed(() -> {
            if (watchdogCurrent(generation)) worker.execute(() -> runAudioWatchdog(monitor, generation));
        }, 2_000);
    }

    private void recoverWatchdogTransport(long generation) {
        if (!watchdogCurrent(generation)) return;
        if (rootTransport != null) {
            restartRootChannel();
            return;
        }
        // Rebind, never remove the user service or kill a live PCM bridge.
        mainHandler.post(() -> { if (watchdogCurrent(generation)) ensureStarted(); });
    }

    private void restartRootChannel() {
        if (channel == PrivilegeChannelPreference.Channel.SHIZUKU) return;
        RootBridgeTransport old = rootTransport;
        if (old != null) {
            rootTransport = null;
            coordinator.disconnect();
            old.close();
        }
        startRootChannel();
    }

    private AudioWatchdogSnapshot boundedAudioProbe() throws Exception {
        if (!audioProbeInFlight.compareAndSet(false, true)) throw new java.io.IOException("previous audio probe still busy");
        java.util.concurrent.Future<AudioWatchdogSnapshot> query = audioProbeWorker.submit(() -> {
            try { return coordinator.audioSnapshot(); }
            finally { audioProbeInFlight.set(false); }
        });
        // Binder cannot safely be interrupted. Keep at most one actual probe alive, never queue more.
        try { return query.get(1, java.util.concurrent.TimeUnit.SECONDS); }
        catch (java.util.concurrent.ExecutionException error) {
            if (error.getCause() instanceof Exception cause) throw cause;
            throw error;
        }
    }

    private void bindPrivilegedService() {
        if (!shizukuAllowed()) return;
        if (binding || (privilegedClient != null && coordinator.bridgeRunning())) return;
        long attempt = bindAttempt.begin(android.os.SystemClock.elapsedRealtime());
        if (attempt < 0) return;
        long generation = privilegeGeneration.get();
        ServiceConnection pending = newConnection(attempt, generation);
        connection = pending;
        binding = true;
        status = "正在启动 Shizuku PCM 服务";
        mainHandler.postDelayed(() -> worker.execute(() -> {
            if (connection != pending || generation != privilegeGeneration.get()
                    || !bindAttempt.expire(attempt, android.os.SystemClock.elapsedRealtime())) return;
            binding = false;
            connection = null;
            status = "Shizuku PCM 启动超时，请点击授权并启动重试，或切换 Root";
            BridgeLog.info("shizuku_user_service_bind_timeout");
            try {
                Shizuku.unbindUserService(serviceArgs, pending, true);
                Shizuku.unbindUserService(serviceArgs, pending, false);
            } catch (RuntimeException error) { BridgeLog.error("shizuku_timeout_detach_failed", error); }
            finishDialerRoleRequest(false, "Shizuku PCM 启动超时");
        }), 35_000);
        try {
            Shizuku.bindUserService(serviceArgs, pending);
        } catch (RuntimeException error) {
            bindAttempt.cancel();
            binding = false;
            status = "Shizuku PCM 服务启动失败";
            BridgeLog.error("shizuku_user_service_bind_failed", error);
        }
    }

    String status() {
        return status;
    }

    boolean privilegeConnected() { return coordinator.connected(); }
    String activePrivilegeLabel() { return rootTransport != null ? "Root" : privilegedClient != null ? "Shizuku" : "权限通道"; }

    boolean bridgeRunning() {
        return coordinator.bridgeRunning();
    }

    void refreshBridgeStatus() {
        if (!coordinator.connected() || !statusRefreshInFlight.compareAndSet(false, true)) return;
        worker.execute(() -> {
            try {
                if (coordinator.connected()) {
                    long generation = coordinator.connectionGeneration();
                    String report = coordinator.refreshStatus();
                    audioHealthReport.update(report, generation, android.os.SystemClock.elapsedRealtime());
                    status = (rootTransport != null ? "Root" : "Shizuku") + " 已连接 · " + report;
                    // Idle PCM stays at bridge_listening / initialized=false by design.
                    // Log every probe only during a call (where it is diagnostic); when
                    // idle, log state changes and a 30s heartbeat instead of every second.
                    boolean inCall = !CallRepository.callIDs().isEmpty();
                    long now = android.os.SystemClock.elapsedRealtime();
                    String stableReport = report.replaceAll(" pcm_(session_age|stats_age|down_idle|up_idle)_ms=-?[0-9]+", "");
                    boolean changed = !stableReport.equals(lastPCMHealthReport);
                    boolean heartbeat = now - lastPCMHealthLogAt >= 30_000;
                    if (inCall || changed || heartbeat) {
                        lastPCMHealthReport = stableReport;
                        lastPCMHealthLogAt = now;
                        BridgeLog.watchdog("pcm_health in_call=" + inCall + " " + report);
                    }
                }
            } catch (Exception error) {
                audioHealthReport.clear();
                status = (rootTransport != null ? "Root" : "Shizuku") + " PCM 状态检查失败";
                BridgeLog.error("pcm_status_refresh_failed", error);
            } finally {
                statusRefreshInFlight.set(false);
            }
        });
    }

    String freshAudioHealthReport() {
        if (!coordinator.connected() && bindAttempt.timedOut()) {
            String version = "";
            try { version = app.getPackageManager().getPackageInfo(MANAGER_PACKAGE, 0).versionName; }
            catch (PackageManager.NameNotFoundException | RuntimeException ignored) {}
            return "privileged_startup=timeout shizuku_mtk_startup_risk="
                + AgentAudioCompatibility.knownShizukuMtkStartupRisk(android.os.Build.HARDWARE, version);
        }
        return audioHealthReport.current(coordinator.connectionGeneration(), android.os.SystemClock.elapsedRealtime());
    }

    void openShizuku() {
        Intent launch = app.getPackageManager().getLaunchIntentForPackage(MANAGER_PACKAGE);
        if (launch == null) {
            status = "未安装 Shizuku";
            return;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try { app.startActivity(launch); }
        catch (RuntimeException error) {
            status = "无法打开 Shizuku";
            BridgeLog.error("shizuku_open_failed", error);
        }
    }
}
