package com.airsim.bridge;

import android.media.AudioRecord;
import android.media.AudioManager;
import android.media.AudioAttributes;
import java.lang.reflect.InvocationTargetException;
import java.net.Socket;

/** Runs the real production startup; only Android allocation/query boundaries are replaced. */
public final class BridgeStartupFailureTests {
    public static void main(String[] args) throws Exception {
        var start = PhoneAudioBridge.class.getDeclaredMethod("streamCallAudio", Socket.class, long.class, BridgeStats.class);
        start.setAccessible(true);
        for (int attempt = 0; attempt < 4; attempt++) {
            AudioAttributes.failSetup = attempt % 2 == 0;
            AudioManager.denyQuery = attempt == 1;
            try (Socket socket = new Socket()) {
                try {
                    start.invoke(null, socket, 0L, new BridgeStats());
                    throw new AssertionError("unavailable platform playback setup must fail startup");
                } catch (InvocationTargetException expected) {
                    if (!(expected.getCause() instanceof AudioStartupFailure failure)) throw expected;
                    String expectedPhase = AudioAttributes.failSetup ? "create_attributes" : "select_uplink_route";
                    if (!expectedPhase.equals(failure.diagnosticFields().get("error_phase")))
                        throw new AssertionError("startup failed before reaching the intended OS boundary", failure);
                    String expectedCode = AudioAttributes.failSetup ? "attributes_create_failed"
                            : AudioManager.denyQuery ? "permission_denied" : "telephony_tx_unavailable";
                    if (!expectedCode.equals(failure.diagnosticFields().get("error_code")))
                        throw new AssertionError("a rejected OEM query was mislabeled as an absent cellular route", failure);
                }
            }
            if (AudioRecord.live != 0 || AudioRecord.released != attempt + 1)
                throw new AssertionError("playback setup failure leaked the already-created capture on attempt " + attempt);
        }
        readyWriteFailureIsNotCaptureFailure(start);
        redmi9BindsRxAndUsesNativeTx(start);
        receiveOnlyNeverCreatesPlayback();
        System.out.println("BridgeStartupFailureTests passed: real startup releases capture and distinguishes denied queries from absent routes");
    }

    private static void receiveOnlyNeverCreatesPlayback() throws Exception {
        AudioManager.exposeRx=true; AudioRecord.rejectPreferred=false;
        var method=PhoneAudioBridge.class.getDeclaredMethod("streamEarlyAudio",Socket.class,long.class,BridgeStats.class);
        method.setAccessible(true);
        int tracks=android.media.AudioTrack.released;
        java.util.concurrent.atomic.AtomicReference<Throwable> failure=new java.util.concurrent.atomic.AtomicReference<>();
        try(java.net.ServerSocket listener=new java.net.ServerSocket(0,1,java.net.InetAddress.getLoopbackAddress())) {
            Thread server=new Thread(() -> {
                try(Socket accepted=listener.accept()) { method.invoke(null,accepted,0L,new BridgeStats()); }
                catch(Throwable error) { failure.set(error); }
            });
            server.start();
            try(Socket client=new Socket(java.net.InetAddress.getLoopbackAddress(),listener.getLocalPort())) {
                client.setSoTimeout(3000);
                byte[] ready=new byte[BridgeProtocol.SERVER_READY.length];
                new java.io.DataInputStream(client.getInputStream()).readFully(ready);
                if(!java.util.Arrays.equals(ready,BridgeProtocol.SERVER_READY)) throw new AssertionError("missing recv-only READY");
                byte[] frame=new byte[320]; new java.io.DataInputStream(client.getInputStream()).readFully(frame);
                if(!PhoneAudioBridge.hasSignal(frame,frame.length)) throw new AssertionError("synthetic downlink missing");
                client.getOutputStream().write(1); // must terminate; never create AudioTrack.
                server.join(3000);
                if(server.isAlive()) throw new AssertionError("uplink byte failed to stop recv-only capture");
            }
        }
        if(failure.get()!=null) throw new AssertionError("recv-only fixture",failure.get());
        if(AudioRecord.live!=0 || android.media.AudioTrack.live!=0 || android.media.AudioTrack.released!=tracks)
            throw new AssertionError("receive-only created playback or leaked capture");
        if(PhoneAudioBridge.hasSignal(new byte[320],320)) throw new AssertionError("silence counted as carrier audio");
        if(!BridgeProtocol.readMediaHello(new java.io.ByteArrayInputStream("AIRSIMRX01\n".getBytes(java.nio.charset.StandardCharsets.US_ASCII))))
            throw new AssertionError("receive-only hello not distinct");
        if(BridgeProtocol.readMediaHello(new java.io.ByteArrayInputStream(BridgeProtocol.CLIENT_HELLO)))
            throw new AssertionError("duplex regressed");
        System.out.println("Receive-only startup passed: synthetic downlink, no playback, uplink rejection and cleanup");
    }

    private static void readyWriteFailureIsNotCaptureFailure(java.lang.reflect.Method start) throws Exception {
        int priorReleased = android.media.AudioTrack.released;
        AudioAttributes.failSetup = false; AudioManager.denyQuery = false; AudioManager.exposeTx = true;
        var logs = new java.io.ByteArrayOutputStream();
        var previous = System.out;
        AudioStartupFailure observed = null;
        try (Socket socket = new Socket() {
            @Override public java.io.InputStream getInputStream() {
                return new java.io.ByteArrayInputStream(BridgeProtocol.CLIENT_HELLO);
            }
            @Override public java.io.OutputStream getOutputStream() {
                return new java.io.OutputStream() {
                    @Override public void write(int value) throws java.io.IOException {
                        throw new java.io.IOException("peer closed during READY");
                    }
                };
            }
        }) {
            System.setOut(new java.io.PrintStream(logs));
            try { start.invoke(null, socket, 0L, new BridgeStats()); }
            catch (InvocationTargetException error) {
                if (!(error.getCause() instanceof AudioStartupFailure)) throw error;
                observed = (AudioStartupFailure) error.getCause();
            }
        } finally { System.setOut(previous); }
        if (observed == null || !"handshake_write_failed".equals(observed.diagnosticFields().get("error_code")))
            throw new AssertionError("READY transport write failure was mistaken for capture/HAL failure", observed);
        if (AudioRecord.live != 0 || android.media.AudioTrack.live != 0 || android.media.AudioTrack.released != priorReleased + 1)
            throw new AssertionError("READY write failure did not release both started native endpoints");
        String text = logs.toString(java.nio.charset.StandardCharsets.UTF_8);
        if (!text.contains("\"event\":\"audio_initialized\"") || text.contains("\"event\":\"client_ready\""))
            throw new AssertionError("READY write failure falsely announced usable media or skipped endpoint setup");
    }

    private static void redmi9BindsRxAndUsesNativeTx(java.lang.reflect.Method start) throws Exception {
        android.os.Build.MANUFACTURER = "Xiaomi"; android.os.Build.DEVICE = "lancelot"; android.os.Build.HARDWARE = "mt6768";
        AudioManager.exposeRx = true;
        android.media.AudioTrack.reject8kMono = true;
        readyWriteFailureIsNotCaptureFailure(start);
        if (AudioRecord.preferred == null || !AudioRecord.preferred.isSource()
                || AudioRecord.requestedSource != 3 || AudioRecord.requestedRate != 8000)
            throw new AssertionError("Redmi 9 capture must bind telephony source without switching to microphone/VOICE_CALL");
        if (android.media.AudioFormat.rate != 48000 || android.media.AudioFormat.channels != 12)
            throw new AssertionError("Redmi 9 native 48k stereo playback profile was not applied");
        for (boolean missing : new boolean[]{true, false}) {
            AudioManager.exposeRx = !missing; AudioRecord.rejectPreferred = !missing;
            try (Socket socket = new Socket()) {
                try { start.invoke(null, socket, 0L, new BridgeStats()); throw new AssertionError("Rx failure silently fell back to microphone"); }
                catch (InvocationTargetException error) {
                    if (!(error.getCause() instanceof AudioStartupFailure failure)) throw error;
                    String expected = missing ? "capture_route_unavailable" : "capture_route_rejected";
                    if (!expected.equals(failure.diagnosticFields().get("error_code"))) throw new AssertionError("wrong capture failure", failure);
                }
            }
            if (AudioRecord.live != 0 || android.media.AudioTrack.live != 0) throw new AssertionError("Redmi Rx failure leaked endpoints");
        }
        System.out.println("Redmi 9 real startup fixture passed: Rx binding, 48k stereo Tx, denied/missing Rx cleanup");
    }
}
