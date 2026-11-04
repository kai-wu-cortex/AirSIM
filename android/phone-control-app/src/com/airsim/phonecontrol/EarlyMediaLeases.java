package com.airsim.phonecontrol;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.function.LongSupplier;
import java.util.function.Predicate;

/** Short recv-only grants for a dial receipt's exact paired owner and Telecom call. */
final class EarlyMediaLeases {
    record Grant(String agent, String call, String session, long expires) {
        String binding() { return agent + "\n" + call + "\n" + session + "\n" + expires + "\nrecvonly\ns16le-8000-mono"; }
        String proof(String nonce) { return "AIRSIM-EARLY-MEDIA1\n" + nonce + "\n" + agent + "\n" + call + "\n" + session + "\n" + expires + "\nearly_media\nrecvonly\ns16le-8000-mono"; }
    }
    private static final class Entry {
        final String owner, agent, call, android, session = UUID.randomUUID().toString();
        final long deadline;
        long expires;
        Entry(String owner, String agent, String call, String android, long deadline) {
            this.owner=owner; this.agent=agent; this.call=call; this.android=android; this.deadline=deadline;
        }
    }
    private final Map<String, Entry> entries = new HashMap<>();
    private final LongSupplier monotonicMillis;
    private final Predicate<String> eligible;
    EarlyMediaLeases(LongSupplier clock, Predicate<String> eligible) { this.monotonicMillis=clock; this.eligible=eligible; }
    synchronized void register(String owner, String agent, String call, String android) {
        prune();
        if (!safe(owner) || !safe(agent) || !safe(call) || !safe(android) || entries.containsKey(call) || entries.size() >= 32) return;
        entries.put(call, new Entry(owner,agent,call,android,monotonicMillis.getAsLong()+120_000));
    }
    synchronized Grant grant(String owner, String call, long now) {
        prune();
        Entry e=entries.get(call);
        if(e==null || !e.owner.equals(owner)) return null;
        e.expires=now+20;
        return new Grant(e.agent,e.call,e.session,e.expires);
    }
    synchronized String authorize(String owner, String binding, long now) {
        prune();
        if(binding==null || binding.length()>640) return null;
        String[] f=binding.split("\n",-1);
        if(f.length!=6 || !f[4].equals("recvonly") || !f[5].equals("s16le-8000-mono")) return null;
        Entry e=entries.get(f[1]);
        if(e==null || !e.owner.equals(owner) || !e.agent.equals(f[0]) || !e.session.equals(f[2])) return null;
        try { long exp=Long.parseLong(f[3]); if(exp<=now || exp>e.expires || exp>now+30) return null; }
        catch(NumberFormatException invalid) { return null; }
        return e.android;
    }
    synchronized boolean live(String owner, String call, String session, long now) {
        prune(); Entry e=entries.get(call);
        return e!=null && e.owner.equals(owner) && e.session.equals(session) && e.expires>now;
    }
    synchronized void revokeAndroid(String android) { entries.values().removeIf(e -> e.android.equals(android)); }
    private void prune() { long now=monotonicMillis.getAsLong(); entries.values().removeIf(e -> now>=e.deadline || !eligible.test(e.android)); }
    private static boolean safe(String s) { return s!=null && !s.isEmpty() && s.length()<=128 && !s.contains("\n") && !s.contains("\r"); }
}
