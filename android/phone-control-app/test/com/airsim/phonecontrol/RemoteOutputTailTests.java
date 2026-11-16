package com.airsim.phonecontrol;
public final class RemoteOutputTailTests {
    public static void main(String[] args) {
        for (String transport : new String[]{"vowlan", "voble", "cloud"}) {
            RemoteOutputTail tail = new RemoteOutputTail();
            check(!tail.update("a", false, true, transport, 10));
            check(tail.update("a", true, false, "", 20));
            check(tail.transport().equals(transport));
            check(tail.update("a", true, false, "", 2019));
            check(!tail.update("a", true, true, transport, 2020));
            check(!tail.update("a", true, true, transport, 9000)); // no extension
            check(!tail.update("b", true, false, transport, 9001)); // no cross-call mute
            tail.update("a", false, true, transport, 1);
            check(!tail.update("a", false, false, transport, 2)); // ordinary media loss
            check(!tail.update("a", true, false, transport, 3)); // no stale ownership
            tail.update("a", false, true, transport, 1);
            check(!tail.update("", false, false, transport, 2)); // multi-call / removal
            check(!tail.update("a", true, false, transport, 3));
            tail.update("a", false, true, transport, 1);
            tail.clear(); // service destruction
            check(!tail.update("a", true, false, transport, 2));
        }
        System.out.println("RemoteOutputTailTests passed: timeout, duplicate, loss, replacement, multi-call, destroy x 3 transports");
    }
    static void check(boolean value) { if (!value) throw new AssertionError("tail scope/lifetime"); }
}
