package com.airsim.phonecontrol;

import android.content.Context;
final class LocalCallAudioController {
    private final ShizukuBridgeManager privilegedBridge;
    private boolean silencing;
    private String transport = PrivilegedBridgeProtocol.TRANSPORT_VOWLAN;

    LocalCallAudioController(Context context) {
        privilegedBridge = ShizukuBridgeManager.get(context);
    }

    /**
     * @param transport current remote audio owner; output/capture volume preference
     *                  is applied independently by the privileged coordinator.
     */
    synchronized void update(boolean shouldSilence, String transport) {
        String next = PrivilegedBridgeProtocol.TRANSPORT_VOBLE.equals(transport)
                ? PrivilegedBridgeProtocol.TRANSPORT_VOBLE
                : PrivilegedBridgeProtocol.TRANSPORT_VOWLAN;
        boolean transportChanged = !next.equals(this.transport);
        this.transport = next;
        // Re-apply when the transport swaps policies even if silence stays requested.
        if (shouldSilence == silencing && !transportChanged) return;
        silencing = shouldSilence;
        privilegedBridge.setLocalOutputMuted(shouldSilence, next);

        BridgeLog.info("local_call_output_requested target_suppressed=" + shouldSilence
                + " transport=" + next
                + " policy=selected_in_privileged_coordinator"
                + " backend=privileged");
    }

    synchronized void update(boolean shouldSilence) {
        update(shouldSilence, transport);
    }

    void updateWatchdog(boolean active, String key, String transports) {
        privilegedBridge.updateAudioWatchdog(active, key, transports);
    }
}
