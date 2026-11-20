package com.airsim.phonecontrol;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.telephony.PhoneStateListener;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyCallback;
import android.telephony.TelephonyDisplayInfo;
import android.telephony.TelephonyManager;

/** Read the Android app's default data connection for status display. */
final class AndroidDataNetwork {
    private final Context context;
    private TelephonyManager telephony;
    private int subscription = SubscriptionManager.INVALID_SUBSCRIPTION_ID;
    private Runnable unregister;
    private Object observation;
    private Integer displayOverride;
    private boolean closed;

    AndroidDataNetwork(Context context) {
        this.context = context;
    }

    synchronized String snapshot() {
        if (closed) return null;
        try {
            ConnectivityManager manager = context.getSystemService(ConnectivityManager.class);
            Network network = manager == null ? null : manager.getActiveNetwork();
            NetworkCapabilities capabilities = network == null ? null : manager.getNetworkCapabilities(network);
            if (capabilities == null) return null;
            boolean wifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
            boolean cellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);
            if (wifi == cellular) return null;
            if (wifi) return "wifi";

            int dataSubscription = Build.VERSION.SDK_INT >= 30
                    ? SubscriptionManager.getActiveDataSubscriptionId()
                    : SubscriptionManager.getDefaultDataSubscriptionId();
            if (!SubscriptionManager.isValidSubscriptionId(dataSubscription)) return "cellular";
            if (telephony == null || subscription != dataSubscription) observe(dataSubscription);
            if (telephony == null) return "cellular";
            try {
                return cellularLabel(telephony.getDataNetworkType(), displayOverride, unregister != null);
            } catch (RuntimeException unavailable) {
                return "cellular";
            }
        } catch (RuntimeException unavailable) {
            return null;
        }
    }

    static String cellularLabel(int networkType, Integer override, boolean awaitingDisplayInfo) {
        if (networkType == TelephonyManager.NETWORK_TYPE_NR) return "5g";
        if (networkType != TelephonyManager.NETWORK_TYPE_LTE) return "cellular";
        if (override == null) return awaitingDisplayInfo ? "cellular" : "4g";
        return switch (override) {
            case TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA,
                 TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA_MMWAVE,
                 TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED -> "5g";
            default -> "4g";
        };
    }

    private void observe(int dataSubscription) {
        stopObserving();
        TelephonyManager manager = context.getSystemService(TelephonyManager.class);
        if (manager == null) return;
        TelephonyManager data = manager.createForSubscriptionId(dataSubscription);
        telephony = data;
        subscription = dataSubscription;
        Object token = new Object();
        observation = token;
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                DisplayCallback callback = new DisplayCallback(info -> receive(token, info));
                data.registerTelephonyCallback(context.getMainExecutor(), callback);
                unregister = () -> data.unregisterTelephonyCallback(callback);
            } else if (Build.VERSION.SDK_INT >= 30) {
                PhoneStateListener listener = new PhoneStateListener(context.getMainExecutor()) {
                    @Override public void onDisplayInfoChanged(TelephonyDisplayInfo info) {
                        receive(token, info);
                    }
                };
                data.listen(listener, PhoneStateListener.LISTEN_DISPLAY_INFO_CHANGED);
                unregister = () -> data.listen(listener, PhoneStateListener.LISTEN_NONE);
            }
        } catch (SecurityException unavailable) {
            // Phone permission can be granted after the service starts.
            telephony = null;
        }
    }

    private synchronized void receive(Object token, TelephonyDisplayInfo info) {
        if (observation == token) displayOverride = info.getOverrideNetworkType();
    }

    synchronized void close() {
        closed = true;
        stopObserving();
    }

    private void stopObserving() {
        observation = null;
        displayOverride = null;
        if (unregister != null) {
            try { unregister.run(); }
            catch (RuntimeException unavailable) { }
            unregister = null;
        }
    }

    private static final class DisplayCallback extends TelephonyCallback
            implements TelephonyCallback.DisplayInfoListener {
        private final java.util.function.Consumer<TelephonyDisplayInfo> listener;

        DisplayCallback(java.util.function.Consumer<TelephonyDisplayInfo> listener) {
            this.listener = listener;
        }

        @Override public void onDisplayInfoChanged(TelephonyDisplayInfo info) {
            listener.accept(info);
        }
    }
}
