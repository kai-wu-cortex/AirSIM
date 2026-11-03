package com.airsim.phonecontrol;

public final class RelayEventQueueTests {
    public static void main(String[] args) throws Exception {
        var gate = new RelayEgressGate(false);
        var queue = new RelayEventQueue<String>(gate);
        assert queue.add("stale-call");
        assert "stale-call".equals(queue.peek());
        gate.disableAndDrain(0);
        assert !queue.add("local-call");
        gate.enableAfterRestore();
        assert queue.peek() == null : "exit replayed an old call";
        assert queue.add("new-call");
        assert "new-call".equals(queue.poll());
        assert queue.peek() == null;
        System.out.println("RelayEventQueueTests passed");
    }
}
