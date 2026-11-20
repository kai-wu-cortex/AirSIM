package com.airsim.phonecontrol;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import java.util.HashMap;

/** Restores screen-off only for authenticated remote calls that began screen-off. */
final class RemoteCallScreenGuard {
    private static RemoteCallScreenGuard instance;
    static synchronized RemoteCallScreenGuard get(Context context) {
        if (instance == null) instance = new RemoteCallScreenGuard(context.getApplicationContext());
        return instance;
    }
    private static final class Scope {
        final long since;
        boolean eligible, owned;
        long endedUntil;
        Scope(long since, boolean eligible) { this.since = since; this.eligible = eligible; }
    }
    private final Context app;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final HashMap<String, Scope> calls = new HashMap<>();
    private long lastScreenOn;
    private boolean pending;
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent intent) {
            if (Intent.ACTION_SCREEN_ON.equals(intent.getAction())) {
                lastScreenOn = SystemClock.uptimeMillis();
                request();
                // A screen-on broadcast may race an already-off check finishing.
                main.postDelayed(RemoteCallScreenGuard.this::request, 180);
                main.postDelayed(RemoteCallScreenGuard.this::request, 600);
            }
        }
    };
    private RemoteCallScreenGuard(Context app) {
        this.app = app;
        IntentFilter filter = new IntentFilter(Intent.ACTION_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
        else app.registerReceiver(receiver, filter);
    }
    synchronized void added(String id, boolean incoming) {
        PowerManager power = app.getSystemService(PowerManager.class);
        long now = SystemClock.uptimeMillis();
        boolean remote = !BridgeNotification.wakesForCalls(app, AppConfig.mode(app));
        boolean recent = lastScreenOn > 0 && now - lastScreenOn <= 1500;
        Scope scope = new Scope(now, RemoteCallScreenPolicy.eligible(remote,
                power != null && !power.isInteractive(), recent));
        // Paired remote-silent mode also suppresses the native incoming-call wake.
        scope.owned = remote && incoming;
        calls.put(id, scope);
        if (scope.owned) request();
    }
    synchronized void ownership(String id, boolean owned) {
        Scope s = calls.get(id);
        if (s == null) return;
        s.owned |= owned; // ownership is retained through exact-call teardown
        if (owned) request();
    }
    synchronized void removed(String id) {
        Scope s = calls.get(id);
        if (s == null) return;
        s.endedUntil = SystemClock.elapsedRealtime() + 5000;
        request();
        main.postDelayed(() -> {
            synchronized (RemoteCallScreenGuard.this) {
                if (calls.get(id) == s) calls.remove(id);
            }
        }, 5000);
    }
    private synchronized long activeSince() {
        long now = SystemClock.elapsedRealtime();
        if (BridgeNotification.wakesForCalls(app, AppConfig.mode(app))) return -1;
        int live = 0;
        for (Scope s : calls.values()) if (s.endedUntil == 0) live++;
        for (Scope s : calls.values()) {
            boolean ended = s.endedUntil != 0;
            if ((!ended || now < s.endedUntil)
                    && RemoteCallScreenPolicy.scopeAllows(s.eligible, s.owned, live, ended)) return s.since;
        }
        return -1;
    }
    private synchronized void request() {
        long since = activeSince();
        if (pending || since < 0) return;
        pending = true;
        ShizukuBridgeManager.get(app).restoreRemoteScreenOff(since, () -> activeSince() == since, result -> {
            synchronized (RemoteCallScreenGuard.this) {
                pending = false;
                if (result.equals("screen_guard=user_override"))
                    for (Scope s : calls.values()) if (s.since == since) s.eligible = false;
            }
            if (!result.equals("screen_guard=already_off")) BridgeLog.info(result);
        });
    }
}
