package com.airsim.phonecontrol;

import java.io.IOException;

public final class PureLocalModeCoordinatorTests {
    static final class Environment implements PureLocalModeCoordinator.Environment {
        boolean active, required, confirmed, restoreFails;
        int snapshots, discards;
        String registration = "original";
        public boolean callActive() { return active; }
        public boolean avfRequired() { return required; }
        public String snapshotRegistration() { snapshots++; return registration; }
        public void discardCloudBacklog() { discards++; }
        public boolean synchronizeAgent(PureLocalModeStore.Record record) { return confirmed; }
        public void restoreRegistration(String snapshot) throws IOException {
            if (restoreFails) throw new IOException("restore_failed");
            registration = snapshot;
        }
    }
    public static void main(String[] args) throws Exception {
        var disk = new PureLocalModeStoreTests.Memory();
        var store = new PureLocalModeStore("fixture-agent", disk);
        var gate = new RelayEgressGate(true);
        var env = new Environment();
        var coordinator = new PureLocalModeCoordinator(store, gate, env, 0);
        coordinator.resume();
        assert !gate.isBlocked();
        var peer = new PureLocalModePolicy.AuthenticatedPeer("wlan:paired");
        var enter = PureLocalModePolicyTests.command(true, 0, PureLocalModePolicyTests.nextOp(1), 1);
        env.active = true;
        PureLocalModePolicyTests.reject("active_call", () -> coordinator.apply(enter, peer));
        assert !gate.isBlocked() && disk.value == null;
        env.active = false;
        var lease = gate.acquire(() -> {});
        var pending = coordinator.apply(enter, peer);
        assert pending.enabled && !pending.drained && gate.isBlocked();
        assert store.read().blocked && env.snapshots == 1 && env.discards == 0;
        lease.close();
        assert gate.disableAndDrain(1000);
        assert coordinator.apply(enter, peer).drained;
        assert env.snapshots == 1;
        env.registration = "changed-by-old-client";
        var restarted = new PureLocalModeCoordinator(store, new RelayEgressGate(true), env, 0);
        assert restarted.resume().enabled && env.snapshots == 1;
        var exit = PureLocalModePolicyTests.command(false, 1, PureLocalModePolicyTests.nextOp(2), 1);
        env.restoreFails = true;
        try { coordinator.apply(exit, peer); throw new AssertionError("restore must fail"); }
        catch (IOException expected) {}
        assert gate.isBlocked() && store.read().blocked && !store.read().state.enabled;
        env.restoreFails = false;
        assert coordinator.apply(exit, peer).drained;
        assert !gate.isBlocked() && "original".equals(env.registration);
        PureLocalModePolicyTests.reject("revision_conflict", () -> coordinator.apply(enter, peer));

        var avfDisk = new PureLocalModeStoreTests.Memory();
        var avfGate = new RelayEgressGate(true);
        var avfEnv = new Environment(); avfEnv.required = true;
        var avfStore = new PureLocalModeStore("fixture-agent", avfDisk);
        var avf = new PureLocalModeCoordinator(avfStore, avfGate, avfEnv, 0);
        avf.resume();
        var awaiting = avf.apply(enter, peer);
        assert awaiting.avfRequired && !awaiting.avfConfirmed && !awaiting.drained;
        avfEnv.confirmed = true;
        assert avf.resume().drained;
        assert avf.exitLocally(PureLocalModePolicyTests.nextOp(3)).revision == 2;
        assert !avfGate.isBlocked();
        assert avf.resume().avfConfirmed : "exit retry lost the verified AVF restoration status";
        PureLocalModePolicyTests.reject("revision_conflict", () -> avf.apply(enter, peer));

        var failedDisk = new PureLocalModeStoreTests.Memory(); failedDisk.fail = true;
        var failedGate = new RelayEgressGate(true);
        var failed = new PureLocalModeCoordinator(new PureLocalModeStore("fixture-agent", failedDisk), failedGate, new Environment(), 0);
        failed.resume();
        try { failed.apply(enter, peer); throw new AssertionError("commit must fail"); }
        catch (IOException expected) {}
        assert failedGate.isBlocked() : "failed entry is not allowed to resume outgoing traffic";
        System.out.println("PureLocalModeCoordinatorTests passed");
    }
}
