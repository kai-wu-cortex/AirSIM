package com.airsim.phonecontrol;

/** Pure reducer. The caller must durably commit then drain before acknowledging a transition. */
public final class PureLocalModePolicy {
    public static final class Rejected extends Exception { public Rejected(String code) { super(code); } }
    public static final class AuthenticatedPeer {
        public final String identity;
        // Construct only after WLAN request authentication or BLE session decryption.
        public AuthenticatedPeer(String identity) { this.identity = identity; }
    }
    public static final class State {
        public final String agentID, ownerFingerprint, lastOperationID, source;
        public final long revision;
        public final boolean enabled, corrupt;
        public State(String agentID, boolean enabled, long revision, String owner, String operation, String source, boolean corrupt) {
            this.agentID = agentID; this.enabled = enabled; this.revision = revision;
            this.ownerFingerprint = owner; this.lastOperationID = operation; this.source = source; this.corrupt = corrupt;
        }
        public static State initial(String agentID) { return new State(agentID, false, 0, "", "", "android_local", false); }
        public static State corrupt(String agentID) { return new State(agentID, true, 0, "", "", "android_local", true); }
    }
    public static final class Transition {
        public final State state;
        public final boolean changed;
        Transition(State state, boolean changed) { this.state = state; this.changed = changed; }
    }
    public static Transition apply(State state, PureLocalModeProof.Command command, AuthenticatedPeer peer, boolean callActive) throws Rejected {
        if (peer == null || peer.identity == null || peer.identity.isEmpty()) throw new Rejected("unauthenticated");
        if (state.corrupt) throw new Rejected("storage_corrupt");
        String owner = PureLocalModeProof.verify(command, state.agentID);
        if (state.enabled && !state.ownerFingerprint.equals(owner)) throw new Rejected("owner_mismatch");
        // A retry reads only the current operation. Older operations never regain authority.
        if (command.operationID.equals(state.lastOperationID) && state.ownerFingerprint.equals(owner)
                && command.enabled == state.enabled && command.expectedRevision == state.revision - 1 && "remote".equals(state.source))
            return new Transition(state, false);
        if (command.expectedRevision != state.revision) throw new Rejected("revision_conflict");
        if (callActive) throw new Rejected("active_call");
        if (!command.enabled && !state.ownerFingerprint.equals(owner)) throw new Rejected("owner_mismatch");
        if (state.revision == Long.MAX_VALUE) throw new Rejected("revision_exhausted");
        return new Transition(new State(state.agentID, command.enabled, state.revision + 1, owner, command.operationID, "remote", false), true);
    }
    public static State exitLocally(State state, String operation, boolean callActive) throws Rejected {
        if (state.corrupt) throw new Rejected("storage_corrupt");
        if (callActive) throw new Rejected("active_call");
        if (!PureLocalModeProof.validOperation(operation)) throw new Rejected("invalid_command");
        if (state.revision == Long.MAX_VALUE) throw new Rejected("revision_exhausted");
        return new State(state.agentID, false, state.revision + 1, state.ownerFingerprint, operation, "android_local", false);
    }
    private PureLocalModePolicy() {}
}
