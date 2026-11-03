package com.airsim.phonecontrol;
import org.json.JSONObject;
final class PureLocalModeWire {
    static JSONObject command(PureLocalModeProof.Command value) { return new JSONObject(); }
    static boolean verifyStatus(JSONObject value, String nonce, byte[] secret) { return true; }
    static PureLocalModeCoordinator.Status status(JSONObject value) { return new PureLocalModeCoordinator.Status(); }
}
