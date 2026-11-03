package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Build;
import android.telephony.SubscriptionManager;

/** Executes the production observer, including the SDK gate and service restart lifecycle. */
public final class SIMSlotObserverTests {
    public static void main(String[] args) {
        int originalSDK = Build.VERSION.SDK_INT;
        try {
            for (int sdk : new int[] {29, 30, 35}) verifyLifecycle(sdk);
        } finally {
            SIMSlotObserver.stop(new Context());
            Build.VERSION.SDK_INT = originalSDK;
        }
        System.out.println("SIMSlotObserver tests passed (API 29, 30, 35)");
    }

    private static void verifyLifecycle(int sdk) {
        Build.VERSION.SDK_INT = sdk;
        Context context = new Context();
        SubscriptionManager manager = new SubscriptionManager();
        context.setSystemService(SubscriptionManager.class, manager);
        int[] oldCallbacks = {0}, newCallbacks = {0};
        SIMSlotObserver.start(context, () -> oldCallbacks[0]++);
        check(manager.legacyRegistrations == (sdk < 30 ? 1 : 0), "legacy registration API " + sdk);
        check(manager.executorRegistrations == (sdk >= 30 ? 1 : 0), "executor registration API " + sdk);
        manager.dispatchSubscriptionsChanged();
        check(oldCallbacks[0] == 1, "subscription change callback");
        SubscriptionManager.OnSubscriptionsChangedListener first = manager.registeredListener;
        SIMSlotObserver.start(context, () -> newCallbacks[0]++);
        check(manager.removals == 1 && manager.removedListener == first, "restart removes exact old listener");
        check(manager.registeredListener != first, "restart registers fresh listener");
        manager.dispatchSubscriptionsChanged();
        check(oldCallbacks[0] == 1 && newCallbacks[0] == 1, "only current listener notified");
        SubscriptionManager.OnSubscriptionsChangedListener second = manager.registeredListener;
        SIMSlotObserver.stop(context);
        check(manager.removals == 2 && manager.removedListener == second, "stop removes current listener");
        SIMSlotObserver.stop(context);
        check(manager.removals == 2, "stop is idempotent");
        manager.dispatchSubscriptionsChanged();
        check(newCallbacks[0] == 1, "stopped listener is unregistered");
        SIMSlotObserver.start(new Context(), () -> { throw new AssertionError("no telephony service"); });
        SIMSlotObserver.stop(context);
        check(manager.removals == 2, "missing service does not retain old manager");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
