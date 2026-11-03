package com.airsim.phonecontrol;

import org.json.JSONObject;

public final class PureLocalModeWireTests {
    public static void main(String[] args) throws Exception {
        var command = PureLocalModePolicyTests.command(true, 0, PureLocalModePolicyTests.nextOp(1), 1);
        JSONObject json = PureLocalModeWire.command(command);
        var decoded = PureLocalModeWire.command(json);
        assert PureLocalModeProof.verify(decoded, "fixture-agent").length() == 64;
        for (Object wrong : new Object[]{"0", 0.5, true, -1}) {
            JSONObject invalid = new JSONObject(json.toString()).put("expected_revision", wrong);
            try { PureLocalModeWire.command(invalid); throw new AssertionError("non-integer revision accepted"); }
            catch (IllegalArgumentException expected) {}
        }
        var state = PureLocalModePolicy.apply(PureLocalModePolicy.State.initial("fixture-agent"), command,
                new PureLocalModePolicy.AuthenticatedPeer("paired"), false).state;
        var status = new PureLocalModeCoordinator.Status(new PureLocalModeStore.Record(state, true, null, false, command), true, true);
        byte[] key = new byte[32]; java.util.Arrays.fill(key, (byte) 3);
        JSONObject signed = PureLocalModeWire.signedStatus(status, "fixture-nonce", key);
        assert PureLocalModeWire.verifyStatus(signed, "fixture-nonce", key);
        assert !PureLocalModeWire.verifyStatus(signed, "other-nonce", key);
        signed.put("drained", false);
        assert !PureLocalModeWire.verifyStatus(signed, "fixture-nonce", key);
        System.out.println("PureLocalModeWireTests passed");
    }
}
