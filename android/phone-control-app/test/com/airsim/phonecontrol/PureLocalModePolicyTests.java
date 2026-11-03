package com.airsim.phonecontrol;

import java.util.Base64;
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters;
import org.bouncycastle.crypto.signers.Ed25519Signer;

public final class PureLocalModePolicyTests {
    private static final String AGENT = "fixture-agent";
    private static final String OP = "00000000-0000-4000-8000-000000000001";
    private static final String KEY = "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=";
    private static final String SIG = "fOw9C+rw4HzGV4znLFF7TDD7l28ZnHuCNArerVlWy12I2KZq3M2qz/74FPQej314vFBa0rMLorhT7shVJPc6Dw==";
    private static final PureLocalModePolicy.AuthenticatedPeer WLAN = new PureLocalModePolicy.AuthenticatedPeer("wlan:paired");
    private static final PureLocalModePolicy.AuthenticatedPeer BLE = new PureLocalModePolicy.AuthenticatedPeer("ble:paired");

    public static void main(String[] args) throws Exception {
        PureLocalModeProof.Command fixed = new PureLocalModeProof.Command(1, AGENT, OP, true, 0, KEY, SIG);
        String owner = PureLocalModeProof.verify(fixed, AGENT);
        check(owner.length() == 64, "verified key fingerprint");
        reject("invalid_signature", () -> PureLocalModeProof.verify(new PureLocalModeProof.Command(1, AGENT, OP, false, 0, KEY, SIG), AGENT));
        reject("invalid_command", () -> PureLocalModeProof.verify(fixed, "different-agent"));
        reject("invalid_command", () -> PureLocalModeProof.verify(command(true, 0, "bad\noperation", 1), AGENT));
        reject("invalid_command", () -> PureLocalModeProof.verify(new PureLocalModeProof.Command(2, AGENT, OP, true, 0, KEY, SIG), AGENT));
        PureLocalModePolicy.State initial = PureLocalModePolicy.State.initial(AGENT);
        reject("unauthenticated", () -> PureLocalModePolicy.apply(initial, fixed, null, false));
        reject("active_call", () -> PureLocalModePolicy.apply(initial, fixed, WLAN, true));
        PureLocalModePolicy.Transition entered = PureLocalModePolicy.apply(initial, fixed, WLAN, false);
        check(entered.changed && entered.state.enabled && entered.state.revision == 1, "enable increments revision");
        check(!PureLocalModePolicy.apply(entered.state, fixed, BLE, false).changed, "same owner retry across transports is idempotent");
        reject("owner_mismatch", () -> PureLocalModePolicy.apply(entered.state, command(false, 1, nextOp(2), 2), BLE, false));
        reject("revision_conflict", () -> PureLocalModePolicy.apply(entered.state, command(false, 0, nextOp(2), 1), BLE, false));
        PureLocalModePolicy.State exited = PureLocalModePolicy.apply(entered.state, command(false, 1, nextOp(2), 1), BLE, false).state;
        check(!exited.enabled && exited.revision == 2, "owner may exit over BLE");
        reject("revision_conflict", () -> PureLocalModePolicy.apply(exited, fixed, WLAN, false));
        PureLocalModePolicy.State localExit = PureLocalModePolicy.exitLocally(entered.state, nextOp(3), false);
        check(!localExit.enabled && localExit.revision == 2 && "android_local".equals(localExit.source), "local override wins");
        reject("revision_conflict", () -> PureLocalModePolicy.apply(localExit, fixed, WLAN, false));
        reject("active_call", () -> PureLocalModePolicy.exitLocally(entered.state, nextOp(3), true));
        check(PureLocalModePolicy.State.corrupt(AGENT).enabled, "corrupt storage fails closed");
        reject("storage_corrupt", () -> PureLocalModePolicy.apply(PureLocalModePolicy.State.corrupt(AGENT), fixed, WLAN, false));
        System.out.println("PureLocalModePolicyTests passed: proof, ownership, replay, local override, fail-closed");
    }

    static String nextOp(int value) { return String.format("00000000-0000-4000-8000-%012d", value); }
    static PureLocalModeProof.Command command(boolean enabled, long revision, String operation, int seed) throws Exception {
        byte[] bytes = new byte[32]; java.util.Arrays.fill(bytes, (byte) seed);
        Ed25519PrivateKeyParameters key = new Ed25519PrivateKeyParameters(bytes, 0);
        String publicKey = Base64.getEncoder().encodeToString(key.generatePublicKey().getEncoded());
        byte[] message = ("airsim-pure-local-v1\n" + AGENT + "\n" + operation + "\n" + (enabled ? "1" : "0") + "\n" + revision).getBytes(java.nio.charset.StandardCharsets.UTF_8);
        Ed25519Signer signer = new Ed25519Signer(); signer.init(true, key); signer.update(message, 0, message.length);
        return new PureLocalModeProof.Command(1, AGENT, operation, enabled, revision, publicKey, Base64.getEncoder().encodeToString(signer.generateSignature()));
    }
    interface Throwing { void run() throws Exception; }
    static void reject(String code, Throwing action) throws Exception {
        try { action.run(); throw new AssertionError("expected " + code); }
        catch (PureLocalModePolicy.Rejected error) { check(code.equals(error.getMessage()), "expected " + code + " got " + error.getMessage()); }
    }
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
