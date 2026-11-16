package com.airsim.phonecontrol;

import android.content.Context;
import android.telecom.Call;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.*;

/** Real PCM ingress with issued grants, call termination and live parent revocation. */
public final class WatchMediaRelayIntegrationTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        Context context = new Context();
        Inet4Address loopback = (Inet4Address) InetAddress.getByName("127.0.0.1");
        ExecutorService workers = Executors.newSingleThreadExecutor();
        Call call = new Call(Call.STATE_ACTIVE), next = new Call(Call.STATE_ACTIVE);
        String id = CallRepository.add(call), nextID = CallRepository.add(next);
        byte[] control = WatchMediaGrant.controlKey(new byte[32]);
        try (ServerSocket shell = new ServerSocket(7580,4,loopback); VoWLANPCMRelay relay = new VoWLANPCMRelay(context)) {
            Future<?> backend = workers.submit(() -> {
                for(int i=0;i<3;i++) try(Socket connection=shell.accept()) {
                    connection.setSoTimeout(3000);
                    check(new String(connection.getInputStream().readNBytes(11),StandardCharsets.US_ASCII).equals("AIRSIMPCM1\n"),"duplex backend preface");
                    connection.getOutputStream().write(VoWLANPCMProtocol.READY.getBytes(StandardCharsets.US_ASCII));
                    int byteValue=connection.getInputStream().read();
                    connection.getOutputStream().write(byteValue); connection.getOutputStream().flush();
                    while(connection.getInputStream().read()>=0) {}
                } catch(Exception error) { throw new RuntimeException(error); }
            });
            int port=relay.start(loopback,0,new InetSocketAddress(loopback,7580));
            long now=System.currentTimeMillis()/1000L;
            var grant = new WatchMediaGrant("test-pairing","agent","call-A",UUID.randomUUID().toString(),1,id,now);
            WatchMediaSessions.register(grant, () -> true);
            String nonce=UUID.randomUUID().toString();
            String preface=preface(grant,control,now,nonce);
            try(Socket peer=send(loopback,port,preface)) {
                check(VoWLANPCMProtocol.acceptReady(peer.getInputStream()),"call-bound READY");
                peer.getOutputStream().write(42); peer.getOutputStream().flush();
                check(peer.getInputStream().read()==42,"both audio directions pass");
                try(Socket duplicate=send(loopback,port,preface)) { check(duplicate.getInputStream().read()==-1,"replayed preface rejected"); }
                try(Socket duplicate=send(loopback,port,preface(grant,control,now,UUID.randomUUID().toString()))) {
                    check(duplicate.getInputStream().read()==-1,"second PCM cannot steal mutex");
                }
                VoWLANPairingStore.paired=false;
                check(peer.getInputStream().read()==-1,"unpair closes attached media");
            }
            VoWLANPairingStore.paired=true;
            Thread.sleep(150); // allow the real worker to release its PCM mutex
            try(Socket old=send(loopback,port,preface(grant,control,now,UUID.randomUUID().toString()))) {
                check(old.getInputStream().read()==-1,"revoked grant cannot reconnect");
            }
            var newGrant = new WatchMediaGrant("test-pairing","agent","call-B",UUID.randomUUID().toString(),2,nextID,now);
            WatchMediaSessions.register(newGrant, () -> true);
            try(Socket peer=send(loopback,port,preface(newGrant,control,now,UUID.randomUUID().toString()))) {
                check(VoWLANPCMProtocol.acceptReady(peer.getInputStream()),"new call acquires released mutex");
                peer.getOutputStream().write(43); peer.getOutputStream().flush(); check(peer.getInputStream().read()==43,"new call PCM");
                next.setStateForTest(Call.STATE_DISCONNECTED);
                check(peer.getInputStream().read()==-1,"native termination closes media");
            }
            Thread.sleep(150);
            var identityCurrent = new java.util.concurrent.atomic.AtomicBoolean(true);
            var identityGrant = new WatchMediaGrant("test-pairing","agent","call-C",UUID.randomUUID().toString(),3,id,now);
            WatchMediaSessions.register(identityGrant, identityCurrent::get);
            try(Socket peer=send(loopback,port,preface(identityGrant,control,now,UUID.randomUUID().toString()))) {
                check(VoWLANPCMProtocol.acceptReady(peer.getInputStream()),"current tuple attaches");
                peer.getOutputStream().write(44); peer.getOutputStream().flush();
                check(peer.getInputStream().read()==44,"current tuple audio");
                identityCurrent.set(false);
                check(peer.getInputStream().read()==-1,"changed tuple closes attached media even while native call is active");
                check(call.getState()==Call.STATE_ACTIVE,"tuple revocation does not hang up unrelated native call");
            }
            identityCurrent.set(true);
            check(WatchMediaSessions.media(context,identityGrant.encoded,now,true)==null,"stale tuple grant cannot resurrect");
            String nonce2=UUID.randomUUID().toString();
            String legacy=VoWLANAuth.sign(control,VoWLANAuth.canonicalRequest("PCM","/v1/pcm",new byte[0],now,nonce2));
            try(Socket old=send(loopback,port,"AIRSIMVWL1 "+now+" "+nonce2+" "+legacy+"\n")) {
                check(old.getInputStream().read()==-1,"limited Watch key rejected by ordinary PCM");
            }
            backend.get(4,TimeUnit.SECONDS);
        } finally { VoWLANPairingStore.paired=true; CallRepository.remove(call); CallRepository.remove(next); workers.shutdownNow(); }
        System.out.println("WatchMediaRelayIntegrationTests: "+checks+" checks passed");
    }
    static String preface(WatchMediaGrant grant,byte[] control,long now,String nonce) {
        byte[] key=WatchMediaGrant.mediaKey(control,grant.encoded);
        return "AIRSIMWATCH2 "+grant.encoded+" "+now+" "+nonce+" "+VoWLANAuth.sign(key,WatchMediaGrant.pcmCanonical(grant.encoded,now,nonce))+"\n";
    }
    static Socket send(InetAddress host,int port,String preface) throws Exception {
        Socket socket=new Socket(host,port); socket.setSoTimeout(3000);
        socket.getOutputStream().write(preface.getBytes(StandardCharsets.US_ASCII)); socket.getOutputStream().flush();return socket;
    }
}
