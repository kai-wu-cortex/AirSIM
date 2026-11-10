package com.airsim.phonecontrol;

/** Pure validation shared by the real PCM admission path and its regression tests. */
final class EarlyMediaLeaseRules {
    private EarlyMediaLeaseRules() {}
    static boolean matches(String expectedPeer, String peer, String agent, String call, String session,
                           long leaseExpiry, String binding, long now, boolean live) {
        if (!live || !expectedPeer.equals(peer) || binding == null || binding.length() > 768) return false;
        String[] f = binding.split("\n", -1);
        if (f.length != 6 || !f[0].equals(agent) || !f[1].equals(call) || !f[2].equals(session)
            || !f[4].equals("recvonly") || !f[5].equals("s16le-8000-mono")) return false;
        try {
            long expiry = Long.parseLong(f[3]);
            return expiry > now && expiry <= leaseExpiry && expiry <= now + 30;
        } catch (NumberFormatException e) { return false; }
    }
}
