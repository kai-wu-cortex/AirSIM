package com.airsim.phonecontrol;

import android.content.Context;
import java.io.IOException;

/** Process singleton joining authenticated local transports to one durable transaction. */
public final class PureLocalModeRuntime {
    private static volatile PureLocalModeRuntime instance;
    public static PureLocalModeRuntime get(Context context) {
        PureLocalModeRuntime value = instance;
        if (value == null) synchronized (PureLocalModeRuntime.class) {
            value = instance;
            if (value == null) instance = value = new PureLocalModeRuntime(context.getApplicationContext());
        }
        return value;
    }

    private final Context context;
    private final PureLocalModeCoordinator coordinator;

    private PureLocalModeRuntime(Context context) {
        this.context = context;
        coordinator = new PureLocalModeCoordinator(AndroidPureLocalModeStore.open(context), RelayEgressGate.shared,
                new Environment(), 5_000);
        try { coordinator.resume(); }
        catch (Exception error) { BridgeLog.error("pure_local_resume_failed", error); }
    }

    public synchronized PureLocalModeCoordinator.Status status() throws Exception { return coordinator.resume(); }

    public synchronized PureLocalModeCoordinator.Status apply(PureLocalModeProof.Command command, String peerIdentity)
            throws Exception {
        return coordinator.apply(command, new PureLocalModePolicy.AuthenticatedPeer(peerIdentity));
    }

    public synchronized PureLocalModeCoordinator.Status exitLocally(String operationID) throws Exception {
        return coordinator.exitLocally(operationID);
    }

    private final class Environment implements PureLocalModeCoordinator.Environment {
        public boolean callActive() { return !CallRepository.idForAction("end").isEmpty(); }
        public boolean avfRequired() { return !RuntimeMode.isStandalone(context); }
        public String snapshotRegistration() throws IOException {
            if (!RuntimeMode.isStandalone(context)) return "";
            try { return StandaloneAgentGateway.get(context).registrationSnapshot(); }
            catch (Exception error) { throw new IOException(error); }
        }
        public void discardCloudBacklog() throws IOException {
            if (!RuntimeMode.isStandalone(context)) return;
            try { StandaloneAgentGateway.get(context).discardCloudBacklog(); }
            catch (Exception error) { throw new IOException(error); }
        }
        public boolean synchronizeAgent(PureLocalModeStore.Record record) throws IOException {
            if (!avfRequired()) return true;
            try {
                AgentClient client = new AgentClient(context);
                PureLocalModeCoordinator.Status status = record.pendingCommand == null
                        ? client.localModeStatus() : client.setLocalMode(record.pendingCommand);
                PureLocalModePolicy.State expected = record.state;
                return status.agentID.equals(expected.agentID) && status.enabled == expected.enabled
                        && status.revision == expected.revision && status.lastOperationID.equals(expected.lastOperationID)
                        && status.ownerFingerprint.equals(expected.ownerFingerprint)
                        && status.drained && status.avfRequired && status.avfConfirmed;
            } catch (Exception error) {
                BridgeLog.error("pure_local_avf_sync_failed", error);
                return false;
            }
        }
        public void restoreRegistration(String snapshot) throws IOException {
            if (!RuntimeMode.isStandalone(context)) return;
            try { StandaloneAgentGateway.get(context).restoreRegistrationSnapshot(snapshot); }
            catch (Exception error) { throw new IOException(error); }
        }
    }
}
