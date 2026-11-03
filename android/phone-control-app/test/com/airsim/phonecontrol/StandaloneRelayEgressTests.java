package com.airsim.phonecontrol;

import java.io.*;
import java.net.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

/** Executes the real Relay client against a counting URL connection; never opens a real socket. */
public final class StandaloneRelayEgressTests {
    static final AtomicInteger sends = new AtomicInteger();
    static CountingConnection latest;
    static boolean verifyDisconnectDrain, prematurelyDrained;
    static final class CountingConnection extends HttpURLConnection {
        CountingConnection(URL url) { super(url); }
        public void connect() {}
        public void disconnect() {
            if (verifyDisconnectDrain) {
                verifyDisconnectDrain = false;
                try { prematurelyDrained = RelayEgressGate.shared.disableAndDrain(0); }
                catch (InterruptedException error) { throw new AssertionError(error); }
            }
        }
        public boolean usingProxy() { return false; }
        public OutputStream getOutputStream() { sends.incrementAndGet(); return new ByteArrayOutputStream(); }
        public int getResponseCode() { return 200; }
        public InputStream getInputStream() { return new ByteArrayInputStream("{}".getBytes()); }
    }
    public static void main(String[] args) throws Exception {
        URL.setURLStreamHandlerFactory(protocol -> "https".equals(protocol) ? new URLStreamHandler() {
            protected URLConnection openConnection(URL url) { latest = new CountingConnection(url); return latest; }
        } : null);
        var registration = new JSONObject().put("relay_url", "https://fixture.invalid");
        var client = new StandaloneRelayClient();
        try { client.post(registration, "/register", new JSONObject(), 100); }
        catch (IOException expected) {}
        assert sends.get() == 0 : "blocked Relay sent an HTTP request";
        RelayEgressGate.shared.enableAfterRestore();
        var manualGeneration = RelayEgressGate.shared.generation();
        RelayEgressGate.shared.disableAndDrain(1000);
        RelayEgressGate.shared.enableAfterRestore();
        try {
            client.postJSON(registration, "/v1/events/heartbeat", new JSONObject(), 100, manualGeneration);
            throw new AssertionError("stale manual heartbeat admitted after off/on");
        } catch (IOException expected) {}
        assert sends.get() == 0 : "stale manual heartbeat emitted network traffic";
        var smsLifetime = new RelayCommandRetryState();
        long smsEpoch = smsLifetime.configure("paired-device");
        try {
            client.postJSON(registration, "/v1/events/sms", new JSONObject(), 100,
                    manualGeneration, smsLifetime, smsEpoch);
            throw new AssertionError("SMS from a previous Relay generation admitted");
        } catch (IOException expected) {}
        smsLifetime.configure("different-device");
        try {
            client.postJSON(registration, "/v1/events/sms", new JSONObject(), 100,
                    RelayEgressGate.shared.generation(), smsLifetime, smsEpoch);
            throw new AssertionError("SMS from a previous pairing admitted");
        } catch (IOException expected) {}
        assert sends.get() == 0 : "cancelled SMS emitted network traffic";
        assert client.post(registration, "/register", new JSONObject(), 100).status() == 200;
        assert sends.get() == 1;
        assert !latest.getInstanceFollowRedirects() : "redirect bypasses admission";
        assert RelayEgressGate.shared.disableAndDrain(0) : "completed HTTP lease leaked";
        try { client.post(registration, "/heartbeat", new JSONObject(), 100); }
        catch (IOException expected) {}
        assert sends.get() == 1;
        RelayEgressGate.shared.enableAfterRestore();
        verifyDisconnectDrain = true;
        client.post(registration, "/status", new JSONObject(), 100);
        assert !prematurelyDrained : "HTTP lease released before disconnect completed";
        assert RelayEgressGate.shared.disableAndDrain(1000);
        System.out.println("StandaloneRelayEgressTests passed");
    }
}
