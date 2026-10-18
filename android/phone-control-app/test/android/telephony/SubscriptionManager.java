package android.telephony;

/** Minimal SubscriptionManager stub mirroring the Android APIs SIMSlotManager relies on. */
public class SubscriptionManager {
    public SubscriptionInfo info;
    public int numberReadCount;
    public java.util.List<SubscriptionInfo> active;
    public static int defaultVoiceId = -1;
    public static int defaultSmsId = -1;
    public java.util.List<OnSubscriptionsChangedListener> listeners = new java.util.ArrayList<>();

    public static int getDefaultVoiceSubscriptionId() { return defaultVoiceId; }
    public static int getDefaultSmsSubscriptionId() { return defaultSmsId; }

    public java.util.List<SubscriptionInfo> getActiveSubscriptionInfoList() { return active; }

    public SubscriptionInfo getActiveSubscriptionInfo(int id) {
        if (active != null) return active.stream().filter(value -> value.subscriptionId == id).findFirst().orElse(null);
        return info;
    }

    public String getPhoneNumber(int id) { numberReadCount++; return getActiveSubscriptionInfo(id).getNumber(); }

    public void addOnSubscriptionsChangedListener(
            java.util.concurrent.Executor executor, OnSubscriptionsChangedListener listener) {
        if (listener != null) listeners.add(listener);
    }

    /** Legacy overload without an executor, matching older Android API levels. */
    public void addOnSubscriptionsChangedListener(OnSubscriptionsChangedListener listener) {
        if (listener != null) listeners.add(listener);
    }

    public void removeOnSubscriptionsChangedListener(OnSubscriptionsChangedListener listener) {
        listeners.remove(listener);
    }

    /** Fires every registered listener, as a real subscription change would. */
    public void notifySubscriptionsChanged() {
        for (OnSubscriptionsChangedListener listener : new java.util.ArrayList<>(listeners)) {
            listener.onSubscriptionsChanged();
        }
    }

    public abstract static class OnSubscriptionsChangedListener {
        public void onSubscriptionsChanged() {}
    }
}
