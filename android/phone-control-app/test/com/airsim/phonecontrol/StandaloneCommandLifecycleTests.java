package com.airsim.phonecontrol;

import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.net.*;
import java.io.*;
import javax.net.ssl.*;

/** Real command configuration coordinator and socket connector, with no phone/network I/O. */
public final class StandaloneCommandLifecycleTests {
    static void check(boolean value,String reason) { if (!value) throw new AssertionError(reason); }
    static void await(CountDownLatch latch) throws Exception { check(latch.await(2,TimeUnit.SECONDS),"latch timeout"); }
    public static void main(String[] args) throws Exception {
        var deniedSocket = new BlockingSocket("none");
        try {
            StandaloneWebSocket.connect(URI.create("wss://127.0.0.1/connect"), "test-only",
                    value -> true, () -> deniedSocket);
            throw new AssertionError("pure-local admitted a socket");
        } catch (IOException expected) {
            check(deniedSocket.connectTimeout == 0, "pure-local must reject before TCP/DNS");
        }
        RelayEgressGate.shared.enableAfterRestore();
        var config=new AtomicReference<String>("A");
        var retry=new RelayCommandRetryState();
        var owner=new RelayCommandConfiguration<String>(config::get,value->value,retry);
        var old=owner.snapshot();
        var entered=new CountDownLatch(1);var resume=new CountDownLatch(1);
        var pulls=new AtomicInteger();var closes=new AtomicInteger();
        var executor=Executors.newSingleThreadExecutor();
        try {
            var pending=executor.submit(()-> { entered.countDown(); await(resume);
                if (owner.isCurrent(old)) pulls.incrementAndGet(); return null; });
            await(entered);config.set("B");var current=owner.snapshot();
            retry.attach(current.epoch(),()->closes.incrementAndGet());
            resume.countDown();pending.get(2,TimeUnit.SECONDS);
            check(pulls.get()==0 && closes.get()==0,"old heartbeat snapshot resurrected or closed new socket");
            check(owner.isCurrent(current),"old consumer changed authoritative scope");
            config.set(null);
            check(!owner.isCurrent(current) && closes.get()==1,"cloud off failed to cancel pending results");
            owner.stop();config.set("C");check(owner.snapshot().scope()==null,"stopped owner revived");
        } finally {executor.shutdownNow();}

        for(String stage:new String[]{"tcp","tls","upgrade"}) {
            var socket=new BlockingSocket(stage);
            var state=new RelayCommandRetryState();long epoch=state.configure("A");
            var pool=Executors.newSingleThreadExecutor();
            try {
                var future=pool.submit(()-> { try {
                    // The injected socket performs no real I/O; a numeric host also
                    // prevents InetSocketAddress from consulting external DNS here.
                    StandaloneWebSocket.connect(URI.create("wss://127.0.0.1/connect"),"test-only",
                        value->state.attach(epoch,value),()->socket);
                    throw new AssertionError("cancelled attempt succeeded");
                } catch(IOException expected) {} return null; });
                await(socket.entered);state.configure(null);future.get(2,TimeUnit.SECONDS);
                check(socket.closed.get(),"pending "+stage+" socket leaked");
                check(socket.connectTimeout==8000,"TCP timeout missing");
                check("HTTPS".equals(socket.endpointAlgorithm),"TLS hostname verification disabled");
            } finally {pool.shutdownNow();socket.close();}
        }
        System.out.println("Standalone command lifecycle tests passed (paused heartbeat, pending TCP/TLS/upgrade)");
    }
    static final class BlockingSocket extends SSLSocket {
        final String stage;final CountDownLatch entered=new CountDownLatch(1), released=new CountDownLatch(1);
        final AtomicBoolean closed=new AtomicBoolean();int connectTimeout;String endpointAlgorithm;
        BlockingSocket(String stage) { this.stage=stage; }
        void block(String at) throws IOException {
            if (!stage.equals(at)) return;
            entered.countDown();try {released.await();}catch(InterruptedException e){Thread.currentThread().interrupt();}
            throw new IOException("synthetic cancelled connection");
        }
        @Override public void connect(SocketAddress endpoint,int timeout) throws IOException {connectTimeout=timeout;block("tcp");}
        @Override public void startHandshake() throws IOException {block("tls");}
        @Override public InputStream getInputStream() {return new InputStream(){@Override public int read() throws IOException {block("upgrade");return -1;}};}
        @Override public OutputStream getOutputStream(){return new ByteArrayOutputStream();}
        @Override public void close(){closed.set(true);released.countDown();}
        @Override public SSLParameters getSSLParameters(){return new SSLParameters();}
        @Override public void setSSLParameters(SSLParameters p){endpointAlgorithm=p.getEndpointIdentificationAlgorithm();}
        public String[] getSupportedCipherSuites(){return new String[0];} public String[] getEnabledCipherSuites(){return new String[0];}
        public void setEnabledCipherSuites(String[] v){} public String[] getSupportedProtocols(){return new String[0];}
        public String[] getEnabledProtocols(){return new String[0];} public void setEnabledProtocols(String[] v){}
        public SSLSession getSession(){return null;} public void addHandshakeCompletedListener(HandshakeCompletedListener v){}
        public void removeHandshakeCompletedListener(HandshakeCompletedListener v){} public void setUseClientMode(boolean v){}
        public boolean getUseClientMode(){return true;} public void setNeedClientAuth(boolean v){} public boolean getNeedClientAuth(){return false;}
        public void setWantClientAuth(boolean v){} public boolean getWantClientAuth(){return false;}
        public void setEnableSessionCreation(boolean v){} public boolean getEnableSessionCreation(){return true;}
    }
}
