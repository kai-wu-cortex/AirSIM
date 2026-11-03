package com.airsim.phonecontrol;

import java.io.*;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Base64;

/** App-private durable transaction. A backend write must synchronously confirm persistence. */
public final class PureLocalModeStore {
    public interface Backend {
        String read() throws IOException;
        void write(String value) throws IOException;
    }
    public static final class Record {
        public final PureLocalModePolicy.State state;
        // Remains true during exit until the required remote agent has restored its snapshot.
        public final boolean blocked, avfRequired;
        public final String priorRegistration;
        public final PureLocalModeProof.Command pendingCommand;
        public Record(PureLocalModePolicy.State state, boolean blocked, String priorRegistration,
                      boolean avfRequired, PureLocalModeProof.Command pendingCommand) {
            this.state = state; this.blocked = blocked; this.priorRegistration = priorRegistration;
            this.avfRequired = avfRequired; this.pendingCommand = pendingCommand;
        }
        public static Record initial(String agentID) {
            return new Record(PureLocalModePolicy.State.initial(agentID), false, null, false, null);
        }
    }
    private final String agentID;
    private final Backend backend;
    public PureLocalModeStore(String agentID, Backend backend) {
        if (!PureLocalModeProof.validID(agentID)) throw new IllegalArgumentException("invalid_agent_id");
        this.agentID = agentID; this.backend = backend;
    }
    public synchronized Record read() {
        try {
            String saved = backend.read();
            if (saved == null) return Record.initial(agentID);
            if (saved.length() > 262144) throw new IOException("oversized_record");
            byte[] envelope = Base64.getDecoder().decode(saved);
            if (envelope.length < 36) throw new IOException("invalid_record");
            byte[] body = Arrays.copyOfRange(envelope, 32, envelope.length);
            if (!MessageDigest.isEqual(Arrays.copyOf(envelope, 32), digest(body))) throw new IOException("corrupt_record");
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(body));
            if (in.readInt() != 1) throw new IOException("unsupported_record");
            PureLocalModePolicy.State state = new PureLocalModePolicy.State(in.readUTF(), in.readBoolean(),
                    in.readLong(), in.readUTF(), in.readUTF(), in.readUTF(), in.readBoolean());
            boolean blocked = in.readBoolean(), avfRequired = in.readBoolean();
            String prior = in.readBoolean() ? in.readUTF() : null;
            PureLocalModeProof.Command pending = null;
            if (in.readBoolean()) pending = new PureLocalModeProof.Command(in.readInt(), in.readUTF(),
                    in.readUTF(), in.readBoolean(), in.readLong(), in.readUTF(), in.readUTF());
            Record record = new Record(state, blocked, prior, avfRequired, pending);
            validate(record);
            if (in.available() != 0) throw new IOException("trailing_record");
            return record;
        } catch (Exception error) {
            // Never infer cloud permission from malformed, mismatched or unreadable storage.
            return new Record(PureLocalModePolicy.State.corrupt(agentID), true, null, true, null);
        }
    }
    public synchronized void commit(Record record) throws IOException {
        validate(record);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        DataOutputStream out = new DataOutputStream(bytes);
        out.writeInt(1);
        PureLocalModePolicy.State s = record.state;
        out.writeUTF(s.agentID); out.writeBoolean(s.enabled); out.writeLong(s.revision);
        out.writeUTF(s.ownerFingerprint); out.writeUTF(s.lastOperationID); out.writeUTF(s.source);
        out.writeBoolean(s.corrupt); out.writeBoolean(record.blocked); out.writeBoolean(record.avfRequired);
        out.writeBoolean(record.priorRegistration != null);
        if (record.priorRegistration != null) out.writeUTF(record.priorRegistration);
        PureLocalModeProof.Command c = record.pendingCommand;
        out.writeBoolean(c != null);
        if (c != null) {
            out.writeInt(c.version); out.writeUTF(c.agentID); out.writeUTF(c.operationID);
            out.writeBoolean(c.enabled); out.writeLong(c.expectedRevision);
            out.writeUTF(c.ownerPublicKey); out.writeUTF(c.signature);
        }
        out.flush();
        byte[] body = bytes.toByteArray();
        ByteArrayOutputStream envelope = new ByteArrayOutputStream();
        envelope.write(digest(body)); envelope.write(body);
        // No in-memory success cache: a failed backend commit must never become an ACK.
        backend.write(Base64.getEncoder().encodeToString(envelope.toByteArray()));
    }
    private void validate(Record r) throws IOException {
        if (r == null || r.state == null) throw new IOException("invalid_record");
        PureLocalModePolicy.State s = r.state;
        if (!agentID.equals(s.agentID) || s.corrupt || s.revision < 0
                || (!"remote".equals(s.source) && !"android_local".equals(s.source))
                || s.ownerFingerprint == null || s.lastOperationID == null
                || (s.enabled && !r.blocked)) throw new IOException("invalid_record");
        if (s.revision == 0) {
            if (s.enabled || !s.ownerFingerprint.isEmpty() || !s.lastOperationID.isEmpty()) throw new IOException("invalid_initial_record");
        } else if (!s.ownerFingerprint.matches("[0-9a-f]{64}") || !PureLocalModeProof.validOperation(s.lastOperationID)) {
            throw new IOException("invalid_owner_record");
        }
        if (r.pendingCommand != null) {
            try {
                PureLocalModeProof.Command c = r.pendingCommand;
                if (!r.blocked || !"remote".equals(s.source) || c.enabled != s.enabled
                        || c.expectedRevision != s.revision - 1 || !c.operationID.equals(s.lastOperationID)
                        || !PureLocalModeProof.verify(c, agentID).equals(s.ownerFingerprint)) throw new IOException("invalid_pending_record");
            } catch (PureLocalModePolicy.Rejected error) { throw new IOException("invalid_pending_record", error); }
        }
    }
    private static byte[] digest(byte[] bytes) throws IOException {
        try { return MessageDigest.getInstance("SHA-256").digest(bytes); }
        catch (java.security.NoSuchAlgorithmException error) { throw new IOException(error); }
    }
}
