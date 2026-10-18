package com.airsim.phonecontrol.voble;

import java.util.ArrayDeque;

public final class VoBLEAudioQueue {
    public record Frame(long sequence, byte[] payload) {
        public Frame { payload = payload.clone(); }
        @Override public byte[] payload() { return payload.clone(); }
    }

    private final int capacity;
    private final ArrayDeque<Frame> frames = new ArrayDeque<>();
    private boolean discontinuity;
    private long droppedFrames;

    public VoBLEAudioQueue(int capacity) {
        if (capacity <= 0) throw new IllegalArgumentException("capacity must be positive");
        this.capacity = capacity;
    }

    public synchronized void offer(long sequence, byte[] payload) {
        if (payload == null) throw new IllegalArgumentException("payload is required");
        if (frames.size() == capacity) {
            frames.removeFirst();
            discontinuity = true;
            droppedFrames++;
        }
        frames.addLast(new Frame(sequence, payload));
    }

    public synchronized Frame poll() {
        return frames.pollFirst();
    }

    public synchronized int size() {
        return frames.size();
    }

    public synchronized long droppedFrames() { return droppedFrames; }

    public synchronized void clear() {
        frames.clear();
    }

    public synchronized boolean consumeDiscontinuity() {
        boolean value = discontinuity;
        discontinuity = false;
        return value;
    }
}
