package com.airsim.bridge;

/** Streaming PCM16 LE interpolation. Wire stays 8k mono; HAL receives 48k stereo.
 * One source-sample delay, no packet queue; phase/history continue across frames. */
final class PCM8kTo48kStereo {
    private int previous;
    private boolean initialized;
    int convert(byte[] source, int count, byte[] target) {
        if (count < 0 || count > source.length || (count & 1) != 0 || target.length / 12 < count)
            throw new IllegalArgumentException("invalid PCM frame capacity/alignment");
        int out = 0;
        for (int index = 0; index < count; index += 2) {
            int current = (short) ((source[index] & 255) | (source[index + 1] << 8));
            if (!initialized) { previous = current; initialized = true; }
            for (int step = 1; step <= 6; step++) {
                int sample = previous + (current - previous) * step / 6;
                target[out++] = (byte) sample; target[out++] = (byte) (sample >> 8);
                target[out++] = (byte) sample; target[out++] = (byte) (sample >> 8);
            }
            previous = current;
        }
        return out;
    }
}
