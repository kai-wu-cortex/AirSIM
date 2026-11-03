package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Build;
import android.telephony.SubscriptionManager;

/** Pushes a fresh SIM snapshot to the paired iPhone when subscriptions change. */
final class SIMSlotObserver {
    private static SubscriptionManager manager;
    private static SubscriptionManager.OnSubscriptionsChangedListener listener;

    private SIMSlotObserver() {}

    // Called from Service.onCreate on the main looper. The API 29 listener binds
    // to the creating thread's looper; keep construction here, not on a worker.
    @SuppressWarnings("deprecation")
    static synchronized void start(Context context, Runnable onChange) {
        stop(context);
        SubscriptionManager subscriptions = context.getSystemService(SubscriptionManager.class);
        if (subscriptions == null) return;
        manager = subscriptions;
        listener = new SubscriptionManager.OnSubscriptionsChangedListener() {
            @Override public void onSubscriptionsChanged() { onChange.run(); }
        };
        if (Build.VERSION.SDK_INT >= 30) {
            subscriptions.addOnSubscriptionsChangedListener(context.getMainExecutor(), listener);
        } else {
            // The Executor overload does not exist on Android 10 (minSdk 29).
            subscriptions.addOnSubscriptionsChangedListener(listener);
        }
    }

    static synchronized void stop(Context context) {
        if (manager != null && listener != null) {
            manager.removeOnSubscriptionsChangedListener(listener);
        }
        manager = null;
        listener = null;
    }
}
