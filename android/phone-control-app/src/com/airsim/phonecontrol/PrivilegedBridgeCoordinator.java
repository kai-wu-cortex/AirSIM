package com.airsim.phonecontrol;

final class PrivilegedBridgeCoordinator {
    interface Transport {
        String startBridge() throws Exception;
        String status() throws Exception;
        String setLocalOutputMuted(boolean muted) throws Exception;
        /** Transport tag lets the privileged side choose a stream-safe policy. */
        default String setLocalOutputMuted(boolean muted, String transport) throws Exception {
            return setLocalOutputMuted(muted);
        }
        default String audioSnapshot() throws Exception { throw new java.io.IOException("snapshot unsupported"); }
    }

    private Transport transport;
    private volatile long connectionGeneration;

    long connectionGeneration() { return connectionGeneration; }
    private boolean desiredMuted;
    private boolean hasMuteIntent;
    private String desiredTransport = PrivilegedBridgeProtocol.TRANSPORT_VOWLAN;
    private String lastResult = "disconnected";
    private String lastBridgeStatus = "disconnected";

    synchronized void connect(Transport value) throws Exception {
        connectionGeneration++;
        transport = value;
        lastBridgeStatus = value.startBridge();
        lastResult = lastBridgeStatus;
        if (hasMuteIntent) lastResult = value.setLocalOutputMuted(desiredMuted, desiredTransport);
    }

    synchronized void disconnect() {
        connectionGeneration++;
        transport = null;
        lastResult = "disconnected";
        lastBridgeStatus = "disconnected";
    }

    synchronized void setLocalOutputMuted(boolean muted) throws Exception {
        setLocalOutputMuted(muted, desiredTransport);
    }

    synchronized void setLocalOutputMuted(boolean muted, String transportTag) throws Exception {
        desiredMuted = muted;
        hasMuteIntent = hasMuteIntent || muted;
        desiredTransport = PrivilegedBridgeProtocol.TRANSPORT_VOBLE.equals(transportTag)
                ? PrivilegedBridgeProtocol.TRANSPORT_VOBLE
                : PrivilegedBridgeProtocol.TRANSPORT_VOWLAN;
        if (transport != null && hasMuteIntent) {
            lastResult = transport.setLocalOutputMuted(muted, desiredTransport);
        }
    }

    synchronized boolean desiredMuted() {
        return desiredMuted;
    }

    AudioWatchdogSnapshot audioSnapshot() throws Exception {
        Transport current;
        synchronized (this) { current = transport; }
        if (current == null) throw new java.io.IOException("privileged transport disconnected");
        // A slow OEM AudioManager query must not hold the mute/restore coordinator lock.
        return AudioWatchdogSnapshot.parse(current.audioSnapshot());
    }

    void reassertLocalOutputMuted() throws Exception {
        Transport current;
        synchronized (this) {
            if (!desiredMuted || !hasMuteIntent) throw new java.io.IOException("obsolete mute intent");
            current = transport;
        }
        if (current == null) throw new java.io.IOException("privileged transport disconnected");
        String result = current.setLocalOutputMuted(true, desiredTransport);
        synchronized (this) { if (current == transport && desiredMuted) lastResult = result; }
    }

    synchronized String lastResult() {
        return lastResult;
    }

    synchronized String refreshStatus() throws Exception {
        if (transport != null) {
            lastBridgeStatus = transport.status();
            lastResult = lastBridgeStatus;
        }
        return lastResult;
    }

    synchronized boolean bridgeRunning() {
        return PCMBridgeStatus.isRunning(lastBridgeStatus);
    }

    synchronized boolean connected() {
        return transport != null;
    }
}
