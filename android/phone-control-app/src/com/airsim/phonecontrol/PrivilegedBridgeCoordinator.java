package com.airsim.phonecontrol;

final class PrivilegedBridgeCoordinator {
    interface Transport {
        String startBridge() throws Exception;
        String setLocalOutputMuted(boolean muted) throws Exception;
    }

    private Transport transport;
    private boolean desiredMuted;
    private boolean hasMuteIntent;
    private String lastResult = "disconnected";

    synchronized void connect(Transport value) throws Exception {
        transport = value;
        lastResult = value.startBridge();
        if (hasMuteIntent) lastResult = value.setLocalOutputMuted(desiredMuted);
    }

    synchronized void disconnect() {
        transport = null;
        lastResult = "disconnected";
    }

    synchronized void setLocalOutputMuted(boolean muted) throws Exception {
        desiredMuted = muted;
        hasMuteIntent = hasMuteIntent || muted;
        if (transport != null && hasMuteIntent) {
            lastResult = transport.setLocalOutputMuted(muted);
        }
    }

    synchronized boolean desiredMuted() {
        return desiredMuted;
    }

    synchronized String lastResult() {
        return lastResult;
    }
}
