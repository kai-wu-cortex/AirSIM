package com.airsim.phonecontrol;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.atomic.AtomicBoolean;

public final class EarlyMediaLeaseTests {
    private static int checks;
    public static void main(String[] args) {
        long[] mono={0}; AtomicBoolean dialing=new AtomicBoolean(true);
        var leases=new EarlyMediaLeases(() -> mono[0], id -> dialing.get() && id.equals("android-call"));
        leases.register("owner","agent","call","android-call");
        check(leases.grant("stranger","call",100)==null,"cross-pair grant");
        var grant=leases.grant("owner","call",100);
        check(grant!=null && grant.expires()==120,"bounded lease");
        check(leases.authorize("owner",grant.binding(),100).equals("android-call"),"exact call authorization");
        check(leases.authorize("stranger",grant.binding(),100)==null,"cross-pair media");
        check(leases.authorize("owner",grant.binding().replace("recvonly","sendrecv"),100)==null,"uplink permission");
        check(leases.authorize("owner",grant.binding().replace("agent","other"),100)==null,"cross-agent media");
        check(leases.authorize("owner",grant.binding().replace("\n120\n","\n150\n"),100)==null,"forged lifetime");
        check(leases.authorize("owner",grant.binding(),120)==null,"expired handshake");
        var renewal=leases.grant("owner","call",110);
        check(renewal.session().equals(grant.session()) && renewal.expires()==130,"renewal keeps session");
        check(leases.live("owner","call",grant.session(),125),"live stream renewal");
        String payload=Base64.getEncoder().encodeToString(renewal.binding().getBytes(StandardCharsets.UTF_8));
        byte[] secret=new byte[32]; java.util.Arrays.fill(secret,(byte)7);
        check(VoWLANAuth.sign(secret,new EarlyMediaLeases.Grant("agent","call","session",120).proof("nonce-early"))
            .equals("62OnqedbB9kLe7hUUT3JYr6GLeVm3L9HQcCztzCoOcs"), "iPhone protocol proof vector");
        String canonical=VoWLANAuth.canonicalRequest("PCM","/v1/pcm/early-media",renewal.binding().getBytes(StandardCharsets.UTF_8),110,"nonce-early");
        String signature=VoWLANAuth.sign(secret,canonical);
        var preface=VoWLANPCMProtocol.parseEarly("AIRSIMEM1 110 nonce-early "+signature+" "+payload+"\n");
        check(VoWLANAuth.verify(secret,signature,VoWLANPCMProtocol.canonical(preface),110,110),"early wire signature");
        check(!VoWLANAuth.verify(secret,signature,VoWLANAuth.canonicalRequest("PCM","/v1/pcm",new byte[0],110,"nonce-early"),110,110),"no downgrade to duplex");
        reject(() -> VoWLANPCMProtocol.parseEarly("AIRSIMVWL1 110 nonce-early "+signature+" "+payload+"\n"));
        reject(() -> VoWLANPCMProtocol.parseEarly("AIRSIMEM1 110 nonce-early "+signature+" not_base64\n"));
        dialing.set(false);
        check(!leases.live("owner","call",grant.session(),115),"active/ended revokes immediately");
        dialing.set(true);
        check(leases.grant("owner","call",116)==null,"old grant cannot resurrect after terminal");
        leases.register("owner","agent","new-call","android-call");
        var next=leases.grant("owner","new-call",117);
        check(leases.authorize("owner",grant.binding(),117)==null,"late previous call handshake");
        leases.revokeAndroid("android-call");
        check(!leases.live("owner","new-call",next.session(),118),"explicit user hangup revokes");
        leases.register("owner","agent","last-call","android-call");
        leases.grant("owner","last-call",119); mono[0]=120_000;
        check(leases.grant("owner","last-call",120)==null,"renewal cannot exceed total window");
        System.out.println("EarlyMediaLeaseTests passed: "+checks+" assertions");
    }
    private static void reject(Runnable r) { try { r.run(); throw new AssertionError("malformed preface accepted"); } catch(IllegalArgumentException expected) { checks++; } }
    private static void check(boolean ok,String name) { checks++; if(!ok) throw new AssertionError(name); }
}
