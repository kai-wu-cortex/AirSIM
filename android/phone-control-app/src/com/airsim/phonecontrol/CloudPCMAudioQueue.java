package com.airsim.phonecontrol;

import java.util.ArrayDeque;

/** Cloud-only 8 kHz mono PCM reserve. Clock is monotonic, never wall-clock time. */
final class CloudPCMAudioQueue {
    private static final int MAX_FRAMES = 12; // 240 ms, not a second of stale speech.
    private final boolean playout;
    private final ArrayDeque<Frame> frames = new ArrayDeque<>();
    private int target = 4;
    private boolean primed;
    private long lastArrival = -1;
    private double jitter;
    private int stableFrames, missingFrames;
    private byte[] lastGood;
    private long dropped, underruns, concealed;

    private static final class Frame {
        final byte[] pcm;
        final long capturedAt;
        Frame(byte[] pcm, long now) { this.pcm = pcm.clone(); capturedAt = now; }
    }

    CloudPCMAudioQueue(boolean playout) { this.playout = playout; }
    synchronized void offer(byte[] pcm, long nowMillis) {
        if (pcm.length != 320) return;
        if (playout && lastArrival >= 0 && nowMillis >= lastArrival) {
            long delta = nowMillis - lastArrival;
            jitter += (Math.abs(delta - 20) - jitter) / 16;
            target = Math.max(target, Math.min(10, 4 + (int) (jitter / 20)));
            stableFrames = delta >= 15 && delta <= 25 ? stableFrames + 1 : 0;
            if (stableFrames >= 100) {
                target = Math.max(4, target - 1);
                stableFrames = 0;
                trim(target + 2);
            }
        }
        lastArrival = nowMillis;
        frames.addLast(new Frame(pcm, nowMillis));
        trim(MAX_FRAMES);
        if (playout && !primed && frames.size() >= target) primed = true;
    }
    synchronized byte[] poll(long nowMillis) {
        if (!playout) {
            while (!frames.isEmpty() && nowMillis - frames.peekFirst().capturedAt > 250) {
                frames.removeFirst(); dropped++;
            }
            return frames.isEmpty() ? null : frames.removeFirst().pcm;
        }
        if (!primed) return null;
        if (!frames.isEmpty()) {
            byte[] pcm = frames.removeFirst().pcm;
            if (missingFrames > 0 && lastGood != null) {
                int previous = sample(lastGood, 159) / 4;
                for (int i = 0; i < 40; i++) put(pcm, i, (previous * (40 - i) + sample(pcm, i) * i) / 40);
            }
            missingFrames = 0;
            lastGood = pcm.clone();
            return pcm;
        }
        underruns++; missingFrames++; stableFrames = 0;
        if (lastGood != null && missingFrames <= 2) {
            byte[] pcm = new byte[320];
            double gain = missingFrames == 1 ? 0.5 : 0.2;
            for (int i = 0; i < 160; i++) put(pcm, i, (int) (sample(lastGood, i) * gain * (1 - i / 320.0)));
            concealed++;
            return pcm;
        }
        target = Math.min(10, target + 1);
        primed = false;
        return null;
    }
    private void trim(int maximum) {
        while (frames.size() > maximum) { frames.removeFirst(); dropped++; }
    }
    private static int sample(byte[] pcm, int index) {
        return (short) ((pcm[index * 2] & 0xff) | (pcm[index * 2 + 1] << 8));
    }
    private static void put(byte[] pcm, int index, int value) {
        pcm[index * 2] = (byte) value; pcm[index * 2 + 1] = (byte) (value >> 8);
    }
    synchronized int size() { return frames.size(); }
    synchronized int targetFrames() { return target; }
    synchronized long droppedFrames() { return dropped; }
    synchronized long underruns() { return underruns; }
    synchronized long concealedFrames() { return concealed; }
    synchronized void clear() { frames.clear(); primed = false; lastGood = null; missingFrames = 0; }
    static long nextTickNanos(long previous, long now) {
        long next = previous + 20_000_000L;
        return next < now ? now + 20_000_000L : next;
    }
}
