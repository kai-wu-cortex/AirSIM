package com.airsim.phonecontrol;

import android.os.Handler;
import android.os.Looper;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * If the iPhone that owns an answered call is force-quit or loses its media/control
 * socket, Android must still be able to end the carrier call. A short grace period
 * allows a normal reconnect; after it expires, disconnect only that exact call.
 */
final class RemoteCallHangupGuard {
    private static final long GRACE_SECONDS = 12;
    private static final ScheduledExecutorService scheduler =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread thread = new Thread(r, "airsim-remote-call-hangup");
                thread.setDaemon(true);
                return thread;
            });
    private static final Map<String, ScheduledFuture<?>> pending = new HashMap<>();

    private RemoteCallHangupGuard() {}

    static synchronized void ownerBound(String callID) {
        if (callID == null || callID.isEmpty()) return;
        ScheduledFuture<?> future = pending.remove(callID);
        if (future != null) future.cancel(false);
    }

    static synchronized void ownerLost(String callID) {
        if (callID == null || callID.isEmpty()) return;
        ScheduledFuture<?> previous = pending.remove(callID);
        if (previous != null) previous.cancel(false);
        pending.put(callID, scheduler.schedule(() -> expire(callID), GRACE_SECONDS, TimeUnit.SECONDS));
    }

    private static void expire(String callID) {
        synchronized (RemoteCallHangupGuard.class) {
            pending.remove(callID);
        }
        if (RemoteAudioSessionRegistry.ownsCall(callID)) return;
        int state = CallRepository.state(callID);
        if (state == android.telecom.Call.STATE_ACTIVE
                || state == android.telecom.Call.STATE_RINGING
                || state == android.telecom.Call.STATE_DIALING
                || state == android.telecom.Call.STATE_HOLDING) {
            BridgeLog.info("remote_owner_lost_hangup");
            new Handler(Looper.getMainLooper()).post(() -> CallRepository.disconnect(callID));
        }
    }
}
