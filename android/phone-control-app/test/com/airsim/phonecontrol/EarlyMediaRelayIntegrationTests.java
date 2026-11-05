package com.airsim.phonecontrol;

import android.content.Context;
import android.telecom.Call;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Real signed TCP receive-only transport; only OS storage/Telecom/audio are fixtures. */
public final class EarlyMediaRelayIntegrationTests {
    public static void main(String[] args) throws Exception {
        android.os.Build.MANUFACTURER="Xiaomi"; android.os.Build.DEVICE="lancelot"; android.os.Build.HARDWARE="mt6768";
        RuntimeMode.standalone=true;
        try {
            for(String stop : new String[]{"uplink","active","ended","unpair","close"}) run(stop);
        } finally { RuntimeMode.standalone=false; }
        System.out.println("Early media TCP integration passed: signature, recv-only, active/ended/unpair revocation, no hangup and gate reuse");
    }
    private static void run(String stop) throws Exception {
        Inet4Address host=(Inet4Address)InetAddress.getLoopbackAddress();
        Call call=new Call(Call.STATE_CONNECTING,Call.Details.DIRECTION_OUTGOING,"test-number");
        String androidID=CallRepository.add(call), backend="backend-"+UUID.randomUUID();
        AndroidEarlyMedia.LEASES.register("test-pairing","agent",backend,androidID);
        CallRepository.earlyMediaCallStateChanged(androidID, Call.STATE_CONNECTING);
        CallRepository.earlyMediaCallStateChanged(androidID, Call.STATE_CONNECTING);
        call.setStateForTest(Call.STATE_DIALING);
        CallRepository.earlyMediaCallStateChanged(androidID, Call.STATE_DIALING);
        var grant=AndroidEarlyMedia.LEASES.grant("test-pairing",backend,System.currentTimeMillis()/1000L);
        if(grant==null) throw new AssertionError("missing setup grant");
        ExecutorService executor=Executors.newSingleThreadExecutor();
        AtomicInteger accepts=new AtomicInteger(), uplink=new AtomicInteger();
        try(ServerSocket shell=new ServerSocket(7580,4,host); VoWLANPCMRelay relay=new VoWLANPCMRelay(new Context())) {
            shell.setSoTimeout(3000);
            Future<?> nativeSide=executor.submit(() -> {
                try(Socket socket=shell.accept()) {
                    accepts.incrementAndGet();socket.setSoTimeout(2500);
                    byte[] hello=new byte[11];new DataInputStream(socket.getInputStream()).readFully(hello);
                    if(!Arrays.equals(hello,"AIRSIMRX01\n".getBytes(StandardCharsets.US_ASCII))) throw new AssertionError("opened duplex backend");
                    socket.getOutputStream().write("AIRSIMREADY".getBytes(StandardCharsets.US_ASCII));
                    byte[] frame=new byte[320];frame[0]=64;socket.getOutputStream().write(frame);socket.getOutputStream().flush();
                    int value;while((value=socket.getInputStream().read())>=0) uplink.incrementAndGet();
                } catch(Exception error) { throw new RuntimeException(error); }
            });
            int port=relay.start(host,0,new InetSocketAddress(host,7580));
            try(Socket invalid=new Socket(host,port)) {
                invalid.setSoTimeout(1500);
                writePreface(invalid,grant,false);
                if(invalid.getInputStream().read()!=-1) throw new AssertionError("bad signature accepted");
            }
            if(accepts.get()!=0) throw new AssertionError("invalid peer opened native audio");
            try(Socket peer=new Socket(host,port)) {
                peer.setSoTimeout(2000);writePreface(peer,grant,true);
                if(!VoWLANPCMProtocol.acceptReady(peer.getInputStream())) throw new AssertionError("missing ready: "+stop);
                byte[] frame=new byte[320];new DataInputStream(peer.getInputStream()).readFully(frame);
                if(frame[0]!=64) throw new AssertionError("downlink not forwarded");
                switch(stop) {
                    case "uplink" -> { peer.getOutputStream().write(7);peer.getOutputStream().flush(); }
                    case "active" -> call.setStateForTest(Call.STATE_ACTIVE);
                    case "ended" -> call.setStateForTest(Call.STATE_DISCONNECTED);
                    case "unpair" -> VoWLANPairingStore.paired=false;
                    case "close" -> relay.close();
                }
                if(peer.getInputStream().read()!=-1) throw new AssertionError("session not revoked: "+stop);
            }
            nativeSide.get(3,TimeUnit.SECONDS);
            if(uplink.get()!=0) throw new AssertionError("peer bytes reached native backend");
            if(!stop.equals("ended") && call.getState()==Call.STATE_DISCONNECTED) throw new AssertionError("early cleanup hung up carrier call");
            long until=System.nanoTime()+TimeUnit.SECONDS.toNanos(2);
            while(relay.hasActiveSession() && System.nanoTime()<until) Thread.sleep(10);
            if(relay.hasActiveSession()) throw new AssertionError("global PCM gate not released");
        } finally {
            executor.shutdownNow(); VoWLANPairingStore.paired=true;
            CallRepository.remove(call); AndroidEarlyMedia.LEASES.revokeAndroid(androidID);
        }
    }
    private static void writePreface(Socket socket, EarlyMediaLeases.Grant grant, boolean valid) throws Exception {
        long now=System.currentTimeMillis()/1000L;String nonce=UUID.randomUUID().toString();
        String canonical=VoWLANAuth.canonicalRequest("PCM","/v1/pcm/early-media",grant.binding().getBytes(StandardCharsets.UTF_8),now,nonce);
        byte[] key=new byte[32];if(!valid)key[0]=1;
        String signature=VoWLANAuth.sign(key,canonical);
        String line="AIRSIMEM1 "+now+" "+nonce+" "+signature+" "+Base64.getEncoder().encodeToString(grant.binding().getBytes(StandardCharsets.UTF_8))+"\n";
        socket.getOutputStream().write(line.getBytes(StandardCharsets.US_ASCII));socket.getOutputStream().flush();
    }
}
