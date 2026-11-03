package android.telephony;
public class SubscriptionManager {
    public static class OnSubscriptionsChangedListener {
        public void onSubscriptionsChanged() {}
    }
    public int legacyRegistrations, executorRegistrations, removals;
    public OnSubscriptionsChangedListener registeredListener, removedListener;
    private java.util.concurrent.Executor callbackExecutor;
    public void addOnSubscriptionsChangedListener(OnSubscriptionsChangedListener listener) {
        legacyRegistrations++;
        registeredListener = listener;
        callbackExecutor = Runnable::run;
    }
    public void addOnSubscriptionsChangedListener(java.util.concurrent.Executor executor,
                                                  OnSubscriptionsChangedListener listener) {
        // Model the missing Android 10 method: an unguarded call must fail tests.
        if (android.os.Build.VERSION.SDK_INT < 30) throw new NoSuchMethodError("API 30 required");
        executorRegistrations++;
        registeredListener = listener;
        callbackExecutor = executor;
    }
    public void removeOnSubscriptionsChangedListener(OnSubscriptionsChangedListener listener) {
        removals++;
        removedListener = listener;
        if (registeredListener == listener) registeredListener = null;
    }
    public void dispatchSubscriptionsChanged() {
        if (registeredListener != null) callbackExecutor.execute(registeredListener::onSubscriptionsChanged);
    }
    public SubscriptionInfo info;
    public int numberReadCount;
    public java.util.List<SubscriptionInfo> active;
    public static int defaultVoiceId = -1;
    public static int getDefaultVoiceSubscriptionId() { return defaultVoiceId; }
    public java.util.List<SubscriptionInfo> getActiveSubscriptionInfoList() { return active; }
    public SubscriptionInfo getActiveSubscriptionInfo(int id) {
        if (active != null) return active.stream().filter(value -> value.subscriptionId == id).findFirst().orElse(null);
        return info;
    }
    public String getPhoneNumber(int id) { numberReadCount++; return getActiveSubscriptionInfo(id).getNumber(); }
}
