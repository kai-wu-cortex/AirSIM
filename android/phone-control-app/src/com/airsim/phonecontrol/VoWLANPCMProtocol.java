package com.airsim.phonecontrol;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class VoWLANPCMProtocol {
    public static final String MAGIC = "AIRSIMVWL1";
    public static final String READY = "AIRSIMREADY";

    private VoWLANPCMProtocol() {}

    public static Preface parse(String line) {
        if (line == null || line.length() > 1024 || !line.endsWith("\n")) {
            throw new IllegalArgumentException("invalid VoWLAN PCM preface");
        }
        String[] fields = line.substring(0, line.length() - 1).split(" ", -1);
        if (fields.length != 4 || !MAGIC.equals(fields[0])
                || fields[2].length() < 7 || fields[2].length() > 128
                || fields[3].length() < 40 || fields[3].length() > 128) {
            throw new IllegalArgumentException("invalid VoWLAN PCM preface");
        }
        try { return new Preface(Long.parseLong(fields[1]), fields[2], fields[3]); }
        catch (NumberFormatException error) { throw new IllegalArgumentException("invalid VoWLAN PCM timestamp", error); }
    }

    public static String canonical(Preface preface) {
        return VoWLANAuth.canonicalRequest(
                "PCM", "/v1/pcm", new byte[0], preface.timestamp(), preface.nonce());
    }

    static boolean acceptReady(InputStream input) throws IOException {
        byte[] expected = READY.getBytes(StandardCharsets.US_ASCII);
        return Arrays.equals(input.readNBytes(expected.length), expected);
    }

    public record Preface(long timestamp, String nonce, String signature) {}

    public static final class SessionGate {
        private String owner;

        public synchronized boolean tryAcquire(String candidate) {
            if (owner != null || candidate == null || candidate.isEmpty()) return false;
            owner = candidate;
            return true;
        }

        public synchronized void release(String candidate) {
            if (owner != null && owner.equals(candidate)) owner = null;
        }
    }
}
