package com.airsim.phonecontrol;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;

/** Same-boot recovery only; contains audio flags/indices, never phone or call data. */
final class IsolationRecoveryJournal implements LocalAudioIsolationController.Store {
    private final Path file;
    private final String bootID;

    IsolationRecoveryJournal(Path file, String bootID) {
        this.file = file;
        this.bootID = bootID;
    }

    static IsolationRecoveryJournal forPackage(String name) throws IOException {
        Path file = pathForPackage(name);
        String boot = new String(Files.readAllBytes(Paths.get("/proc/sys/kernel/random/boot_id")),
                StandardCharsets.US_ASCII).trim();
        if (!boot.matches("[a-fA-F0-9-]{36}")) throw new IOException("isolation recovery boot unavailable");
        return new IsolationRecoveryJournal(file, boot);
    }

    static boolean hasSavedState(String name) throws IOException {
        return Files.exists(pathForPackage(name), LinkOption.NOFOLLOW_LINKS);
    }

    private static Path pathForPackage(String name) throws IOException {
        if (name == null || !name.matches("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+"))
            throw new IOException("isolation recovery package unavailable");
        return Paths.get("/data/local/tmp/airsim-isolation-" + name + ".state");
    }

    public LocalAudioIsolationController.Snapshot read() throws IOException {
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) return null;
        if (Files.isSymbolicLink(file) || Files.size(file) > 512)
            throw new IOException("invalid isolation recovery file");
        try (DataInputStream input = new DataInputStream(Files.newInputStream(file))) {
            if (input.readInt() != 0x41495331) throw new IOException("invalid isolation recovery format");
            if (!bootID.equals(input.readUTF())) {
                // The OS resets audio state on reboot; do not replay yesterday's microphone state.
                clear();
                return null;
            }
            try {
                var value = new LocalAudioIsolationController.Snapshot(input.readBoolean(), input.readBoolean(),
                        input.readInt(), input.readInt());
                if (input.read() != -1) throw new IOException("invalid isolation recovery length");
                return value;
            } catch (IllegalArgumentException invalid) { throw new IOException("invalid isolation recovery values", invalid); }
        }
    }

    public void save(LocalAudioIsolationController.Snapshot value) throws IOException {
        Path temporary = Files.createTempFile(file.getParent(), "airsim-isolation-", ".tmp");
        try {
            // createTempFile is owner-only on Android/Linux. Do not make a recovery file public.
            try (FileOutputStream stream = new FileOutputStream(temporary.toFile());
                    DataOutputStream output = new DataOutputStream(stream)) {
                output.writeInt(0x41495331); output.writeUTF(bootID);
                output.writeBoolean(value.microphone()); output.writeBoolean(value.streamMuted());
                output.writeInt(value.earpiece()); output.writeInt(value.speaker());
                output.flush(); stream.getFD().sync();
            }
            Files.move(temporary, file, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temporary); }
    }

    public void clear() throws IOException { Files.deleteIfExists(file); }
}
