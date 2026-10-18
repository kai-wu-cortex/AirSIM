package com.airsim.phonecontrol.voble;

import java.util.HashMap;
import java.util.Map;

/** Tracks GATT ownership and each CCCD independently. Health reads never authenticate a peer. */
public final class VoBLEControlChannel {
    private static final class Subscription {
        boolean control;
        boolean audio;
    }

    private final Map<String, Subscription> subscriptions = new HashMap<>();
    private String authenticatedOwner;

    public synchronized boolean authenticate(String deviceId) {
        if (!canAuthenticate(deviceId)) return false;
        authenticatedOwner = deviceId;
        subscriptions.computeIfAbsent(deviceId, ignored -> new Subscription());
        return true;
    }

    public synchronized boolean canAuthenticate(String deviceId) {
        return deviceId != null && !deviceId.isBlank()
                && (authenticatedOwner == null || authenticatedOwner.equals(deviceId));
    }

    public synchronized boolean isReady(String deviceId) {
        return owns(deviceId) && isControlSubscribed(deviceId);
    }

    public synchronized void subscribeControl(String deviceId) {
        state(deviceId).control = true;
    }

    public synchronized void unsubscribeControl(String deviceId) {
        Subscription value = subscriptions.get(deviceId);
        if (value != null) value.control = false;
    }

    public synchronized void subscribeAudio(String deviceId) {
        state(deviceId).audio = true;
    }

    public synchronized void unsubscribeAudio(String deviceId) {
        Subscription value = subscriptions.get(deviceId);
        if (value != null) value.audio = false;
    }

    public synchronized boolean isControlSubscribed(String deviceId) {
        Subscription value = subscriptions.get(deviceId);
        return value != null && value.control;
    }

    public synchronized boolean isAudioSubscribed(String deviceId) {
        Subscription value = subscriptions.get(deviceId);
        return value != null && value.audio;
    }

    public synchronized boolean owns(String deviceId) {
        return authenticatedOwner != null && authenticatedOwner.equals(deviceId);
    }

    public synchronized void disconnect(String deviceId) {
        subscriptions.remove(deviceId);
        if (owns(deviceId)) authenticatedOwner = null;
    }

    /** Revokes the authenticated central without trusting any other connected central. */
    public synchronized boolean revokeOwner(String deviceId) {
        if (!owns(deviceId)) return false;
        subscriptions.remove(deviceId);
        authenticatedOwner = null;
        return true;
    }

    public boolean revokeOwnerAndDisconnect(String deviceId, Runnable disconnectTransport) {
        if (!revokeOwner(deviceId)) return false;
        // Do not hold the channel monitor while invoking the Bluetooth stack.
        disconnectTransport.run();
        return true;
    }

    private Subscription state(String deviceId) {
        if (deviceId == null || deviceId.isBlank()) {
            throw new IllegalArgumentException("Bluetooth device identity is required");
        }
        return subscriptions.computeIfAbsent(deviceId, ignored -> new Subscription());
    }
}
