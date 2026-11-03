package com.airsim.phonecontrol;

import java.io.IOException;

public final class PureLocalModeStoreTests {
    static final class Memory implements PureLocalModeStore.Backend {
        String value; boolean fail;
        public String read() throws IOException { return value; }
        public void write(String value) throws IOException { if (fail) throw new IOException("disk full"); this.value = value; }
    }
    public static void main(String[] args) throws Exception {
        Memory disk = new Memory();
        PureLocalModeStore store = new PureLocalModeStore("fixture-agent", disk);
        assert !store.read().blocked;
        var state = new PureLocalModePolicy.State("fixture-agent", true, 1, "a".repeat(64),
                "00000000-0000-4000-8000-000000000001", "remote", false);
        store.commit(new PureLocalModeStore.Record(state, true, "prior-cloud-fixture", false, null));
        var restarted = new PureLocalModeStore("fixture-agent", disk).read();
        assert restarted.blocked && restarted.state.enabled;
        assert restarted.state.revision == 1 && restarted.priorRegistration.equals("prior-cloud-fixture");
        disk.fail = true;
        try { store.commit(PureLocalModeStore.Record.initial("fixture-agent")); throw new AssertionError(); }
        catch (IOException expected) {}
        assert store.read().blocked : "failed writes must not clear the durable restriction";
        assert new PureLocalModeStore("wrong-agent", disk).read().blocked;
        disk.value = "broken";
        assert store.read().blocked && store.read().state.corrupt;
        System.out.println("PureLocalModeStoreTests passed");
    }
}
