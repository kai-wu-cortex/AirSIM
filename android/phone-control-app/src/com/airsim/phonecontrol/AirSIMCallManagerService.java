package com.airsim.phonecontrol;

import android.telecom.Connection;
import android.telecom.ConnectionRequest;
import android.telecom.ConnectionService;
import android.telecom.DisconnectCause;
import android.telecom.PhoneAccountHandle;

/**
 * Acts as the Telecom SIM Call Manager for the default dialer so AirSIM is
 * authorized by TelecomServiceImpl.isCallerSimCallManager() to bridge headless
 * IMS incoming calls into Telecom via TelecomManager.addNewIncomingCall() on
 * data-centric firmware where config_voice_capable=false.
 *
 * Returning DisconnectCause.CONNECTION_MANAGER_NOT_SUPPORTED (10) instructs
 * Telecom's CreateConnectionProcessor to immediately fall back to the native
 * PSTN TelephonyConnectionService for both incoming and outgoing calls.
 */
public final class AirSIMCallManagerService extends ConnectionService {
    @Override
    public Connection onCreateIncomingConnection(
            PhoneAccountHandle connectionManagerPhoneAccount,
            ConnectionRequest request) {
        BridgeLog.info("sim_call_manager_incoming_fallback account="
                + (request != null ? request.getAccountHandle() : null));
        return Connection.createFailedConnection(
                new DisconnectCause(DisconnectCause.CONNECTION_MANAGER_NOT_SUPPORTED, "Fallback to PSTN"));
    }

    @Override
    public Connection onCreateOutgoingConnection(
            PhoneAccountHandle connectionManagerPhoneAccount,
            ConnectionRequest request) {
        BridgeLog.info("sim_call_manager_outgoing_fallback account="
                + (request != null ? request.getAccountHandle() : null));
        return Connection.createFailedConnection(
                new DisconnectCause(DisconnectCause.CONNECTION_MANAGER_NOT_SUPPORTED, "Fallback to PSTN"));
    }
}
