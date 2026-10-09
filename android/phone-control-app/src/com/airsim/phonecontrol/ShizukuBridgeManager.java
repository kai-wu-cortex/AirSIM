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

import rikka.shizuku.Shizuku;

final class ShizukuBridgeManager {
    interface DialerRoleCallback {
        void onResult(boolean success, String detail);
    }

    static final int PERMISSION_REQUEST = 7301;
    private static volatile ShizukuBridgeManager instance;

    private final Context app;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object roleLock = new Object();
    private final Shizuku.UserServiceArgs serviceArgs;
    private volatile String status = "等待 Shizuku";
    private volatile boolean binding;
    private volatile PrivilegedBridgeClient privilegedClient;
    private DialerRoleCallback pendingRoleCallback;
    private boolean roleRequestInFlight;

    private final Shizuku.OnBinderReceivedListener binderReceived = this::onBinderReceived;
    private final Shizuku.OnBinderDeadListener binderDead = this::onBinderDead;
    private final Shizuku.OnRequestPermissionResultListener permissionResult = (requestCode, grantResult) -> {
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

    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            binding = false;
            worker.execute(() -> {
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
            binding = false;
            privilegedClient = null;
            coordinator.disconnect();
            status = "Shizuku 服务已断开";
            BridgeLog.info("shizuku_user_service_disconnected");
            finishDialerRoleRequest(false, "Shizuku 服务已断开");
        }
    };

    private ShizukuBridgeManager(Context context) {
        app = context.getApplicationContext();
        serviceArgs = new Shizuku.UserServiceArgs(new ComponentName(
                app.getPackageName(), ShizukuBridgeUserService.class.getName()))
                .daemon(true)
                .processNameSuffix("pcm_shell")
                .debuggable(true)
                .tag("airsim-pcm-v1")
                .version(5);
        Shizuku.addBinderReceivedListenerSticky(binderReceived);
        Shizuku.addBinderDeadListener(binderDead);
        Shizuku.addRequestPermissionResultListener(permissionResult);
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

    private void onBinderReceived() {
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
        binding = false;
        privilegedClient = null;
        coordinator.disconnect();
        status = "Shizuku 未运行";
        BridgeLog.info("shizuku_binder_dead");
        finishDialerRoleRequest(false, "Shizuku 未运行");
    }

    void requestPermission() {
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

    boolean dialerRoleAutomationAuthorized() {
        try {
            return Shizuku.pingBinder()
                    && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED;
        } catch (RuntimeException error) {
            return false;
        }
    }

    boolean dialerRoleAutomationAvailable() {
        try { return Shizuku.pingBinder(); }
        catch (RuntimeException error) { return false; }
    }

    void ensureDialerRole(boolean requestPermission, DialerRoleCallback callback) {
        synchronized (roleLock) {
            pendingRoleCallback = callback;
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

    void setLocalOutputMuted(boolean muted) {
        worker.execute(() -> {
            try {
                coordinator.setLocalOutputMuted(muted);
                status = "Shizuku 已连接 · " + coordinator.lastResult();
                BridgeLog.info("shizuku_local_output target_muted=" + muted
                        + " result=" + coordinator.lastResult());
            } catch (Exception error) {
                status = "本机通话静音失败";
                BridgeLog.error("shizuku_local_output_failed target_muted=" + muted, error);
            }
        });
    }

    private void bindPrivilegedService() {
        if (binding) return;
        binding = true;
        status = "正在启动 Shizuku PCM 服务";
        try {
            Shizuku.bindUserService(serviceArgs, connection);
        } catch (RuntimeException error) {
            binding = false;
            status = "Shizuku PCM 服务启动失败";
            BridgeLog.error("shizuku_user_service_bind_failed", error);
        }
    }

    String status() {
        return status;
    }

    void openShizuku() {
        Intent launch = app.getPackageManager().getLaunchIntentForPackage("moe.shizuku.privileged.api");
        if (launch == null) {
            status = "未安装 Shizuku";
            return;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        app.startActivity(launch);
    }
}
