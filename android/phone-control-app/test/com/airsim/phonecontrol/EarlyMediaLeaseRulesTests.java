package com.airsim.phonecontrol;
public class EarlyMediaLeaseRulesTests {
    public static void main(String[] args) {
        String binding = "agent\ncall\nsession\n1025\nrecvonly\ns16le-8000-mono";
        if (!EarlyMediaLeaseRules.matches("peer", "peer", "agent", "call", "session", 1025, binding, 1000, true)) throw new AssertionError("valid lease refused");
        for (String candidate : new String[] {binding.replace("agent", "other"), binding.replace("call", "other"),
            binding.replace("session", "other"), binding.replace("recvonly", "sendrecv"), binding.replace("1025", "999"),
            binding.replace("1025", "999999"), binding.replace("1025", "nan"), binding + "\nextra"}) {
            if (EarlyMediaLeaseRules.matches("peer", "peer", "agent", "call", "session", 1025, candidate, 1000, true)) throw new AssertionError("invalid lease accepted");
        }
        if (EarlyMediaLeaseRules.matches("peer", "other", "agent", "call", "session", 1025, binding, 1000, true)) throw new AssertionError("wrong pairing");
        if (EarlyMediaLeaseRules.matches("peer", "peer", "agent", "call", "session", 1025, binding, 1000, false)) throw new AssertionError("ended or answered call");
        if (EarlyMediaLeaseRules.matches("peer", "peer", "agent", "call", "session", 1025, binding, 1025, true)) throw new AssertionError("expired lease");
        System.out.println("Early media admission: valid lease and 11 rejection cases passed");
    }
}
