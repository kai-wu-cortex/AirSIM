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
     * @param transport current remote audio owner. VoBLE mutes the stream (its uplink is
     *                  BLE); VoWLAN suppresses built-in device output without a global stream mute.
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
        LocalOutputMuteController.Strategy policy = next.equals(PrivilegedBridgeProtocol.TRANSPORT_VOBLE)
                ? LocalOutputMuteController.vobleStrategy() : LocalOutputMuteController.physicalOutputStrategy();
        BridgeLog.info("local_call_output_requested target_suppressed=" + shouldSilence
                + " transport=" + next
                + " policy=" + LocalOutputMuteController.policyName(policy)
                + " backend=privileged");
    }

    synchronized void update(boolean shouldSilence) {
        update(shouldSilence, transport);
    }

    synchronized void reassertIfSilencing() {
        if (silencing) privilegedBridge.setLocalOutputMuted(true, transport);
    }

    void updateWatchdog(boolean active, String key, String transports) {
        privilegedBridge.updateAudioWatchdog(active, key, transports);
    }
}
