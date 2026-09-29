package com.airsim.bridge;

final class BridgeStats {
    private long downlinkBytes;
    private int downlinkPeak;
    private long uplinkBytes;
    private int uplinkPeak;
    private long rejectedClients;

    synchronized void recordDownlink(byte[] pcm, int length) {
        validatePCM(pcm, length);
        downlinkBytes += length;
        downlinkPeak = Math.max(downlinkPeak, pcm16LEPeak(pcm, length));
    }

    synchronized void recordUplink(byte[] pcm, int length) {
        validatePCM(pcm, length);
        uplinkBytes += length;
        uplinkPeak = Math.max(uplinkPeak, pcm16LEPeak(pcm, length));
    }

    synchronized void recordRejectedClient() {
        rejectedClients++;
    }

    synchronized Snapshot snapshot() {
        return new Snapshot(
            downlinkBytes,
            downlinkBytes / BridgeProtocol.FRAME_BYTES,
            downlinkPeak,
            uplinkBytes,
            uplinkBytes / BridgeProtocol.FRAME_BYTES,
            uplinkPeak,
            rejectedClients);
    }

    private static void validatePCM(byte[] pcm, int length) {
        if (length < 0 || length > pcm.length || (length & 1) != 0) {
            throw new IllegalArgumentException("PCM length must be even and within buffer");
        }
    }

    private static int pcm16LEPeak(byte[] pcm, int length) {
        int peak = 0;
        for (int offset = 0; offset < length; offset += 2) {
            int sample = (short) ((pcm[offset] & 0xff) | (pcm[offset + 1] << 8));
            int magnitude = sample == Short.MIN_VALUE ? 32768 : Math.abs(sample);
            peak = Math.max(peak, magnitude);
        }
        return peak;
    }

    record Snapshot(
        long downlinkBytes,
        long downlinkFrames,
        int downlinkPeak,
        long uplinkBytes,
        long uplinkFrames,
        int uplinkPeak,
        long rejectedClients) {}
}
