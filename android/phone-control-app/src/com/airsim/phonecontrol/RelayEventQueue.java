package com.airsim.phonecontrol;

import java.util.ArrayDeque;

/** Cloud-only transient events. Local history is stored independently. */
final class RelayEventQueue<T> {
    private record Entry<T>(T value, RelayEgressGate.Generation generation) {}
    private final ArrayDeque<Entry<T>> entries = new ArrayDeque<>();
    private final RelayEgressGate gate;
    RelayEventQueue(RelayEgressGate gate) { this.gate = gate; }
    synchronized boolean add(T value) {
        var generation = gate.generation();
        if (!generation.isCurrent()) return false;
        entries.add(new Entry<>(value, generation));
        return true;
    }
    synchronized T peek() {
        while (!entries.isEmpty() && !entries.peek().generation.isCurrent()) entries.poll();
        return entries.isEmpty() ? null : entries.peek().value;
    }
    synchronized T poll() {
        T value = peek();
        if (value != null) entries.poll();
        return value;
    }
    synchronized void clear() { entries.clear(); }
}
