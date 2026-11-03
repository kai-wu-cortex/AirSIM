package com.airsim.phonecontrol;

import java.io.IOException;

/** Serial durable transaction coordinator; transport adapters supply authenticated peers only. */
public final class PureLocalModeCoordinator {
    public interface Environment {
        boolean callActive();
        boolean avfRequired();
        String snapshotRegistration() throws IOException;
        void discardCloudBacklog() throws IOException;
        // Must verify identity, revision, operation and drain status using the trusted Agent channel.
        // android_local restoration is a separate trusted local override, not a forged owner command.
        // For an already completed exit (blocked=false), query only; never replay a restore.
        boolean synchronizeAgent(PureLocalModeStore.Record record) throws IOException;
        void restoreRegistration(String snapshot) throws IOException;
    }
    public static final class Status {
        public final int version = 1;
        public final String agentID, lastOperationID, ownerFingerprint, source;
        public final long revision;
        public final boolean enabled, drained, avfRequired, avfConfirmed;
        Status(PureLocalModeStore.Record r, boolean drained, boolean confirmed) {
            PureLocalModePolicy.State s = r.state;
            agentID = s.agentID; enabled = s.enabled; revision = s.revision;
            lastOperationID = s.lastOperationID; ownerFingerprint = s.ownerFingerprint; source = s.source;
            this.drained = drained; avfRequired = r.avfRequired; avfConfirmed = confirmed;
        }
    }
    private final PureLocalModeStore store;
    private final RelayEgressGate gate;
    private final Environment environment;
    private final long drainTimeoutMillis;
    private boolean storageFailed;

    public PureLocalModeCoordinator(PureLocalModeStore store, RelayEgressGate gate,
                                    Environment environment, long drainTimeoutMillis) {
        this.store = store; this.gate = gate; this.environment = environment;
        this.drainTimeoutMillis = Math.max(0, drainTimeoutMillis);
    }
    public synchronized Status apply(PureLocalModeProof.Command command,
                                      PureLocalModePolicy.AuthenticatedPeer peer)
            throws IOException, InterruptedException, PureLocalModePolicy.Rejected {
        PureLocalModeStore.Record before = store.read();
        PureLocalModePolicy.Transition transition = PureLocalModePolicy.apply(before.state, command, peer, environment.callActive());
        if (transition.changed) {
            // Keep the first snapshot across retries, process death and pending exit.
            String snapshot = before.blocked ? before.priorRegistration : environment.snapshotRegistration();
            boolean avf = before.blocked ? before.avfRequired : environment.avfRequired();
            commitRestricted(new PureLocalModeStore.Record(transition.state, true, snapshot, avf, command));
        }
        return resume();
    }
    public synchronized Status exitLocally(String operation)
            throws IOException, InterruptedException, PureLocalModePolicy.Rejected {
        PureLocalModeStore.Record before = store.read();
        if (!before.blocked) return resume();
        PureLocalModePolicy.State state = PureLocalModePolicy.exitLocally(before.state, operation, environment.callActive());
        commitRestricted(new PureLocalModeStore.Record(state, true, before.priorRegistration, before.avfRequired, null));
        return resume();
    }
    /** Reconcile on startup or an explicit retry. No cached ACK survives an Agent disconnect. */
    public synchronized Status resume() throws IOException, InterruptedException {
        PureLocalModeStore.Record record = store.read();
        if (storageFailed || record.state.corrupt) {
            gate.disableAndDrain(drainTimeoutMillis);
            return new Status(record, false, false);
        }
        if (!record.blocked) {
            gate.enableAfterRestore();
            boolean confirmed = !record.avfRequired || environment.synchronizeAgent(record);
            return new Status(record, confirmed, confirmed);
        }
        if (!gate.disableAndDrain(drainTimeoutMillis)) return new Status(record, false, false);
        environment.discardCloudBacklog();
        boolean confirmed = !record.avfRequired || environment.synchronizeAgent(record);
        if (!confirmed) return new Status(record, false, false);
        if (!record.state.enabled) {
            environment.restoreRegistration(record.priorRegistration);
            // Keep the gate closed if restoring or persisting completion fails.
            commitRestricted(new PureLocalModeStore.Record(record.state, false, null, record.avfRequired, null));
            gate.enableAfterRestore();
        }
        return new Status(record, true, true);
    }
    private void commitRestricted(PureLocalModeStore.Record record) throws IOException, InterruptedException {
        try { store.commit(record); storageFailed = false; }
        catch (IOException error) {
            storageFailed = true;
            gate.disableAndDrain(drainTimeoutMillis);
            throw error;
        }
    }
}
