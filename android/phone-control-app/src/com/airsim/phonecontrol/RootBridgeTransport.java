package com.airsim.phonecontrol;

import android.content.Context;
import android.os.SystemClock;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.UUID;

/**
 * Root transport for the same privileged protocol used by the Shizuku user
 * service. A localhost port plus an app-private one-time token isolate the
 * root helper from other apps. No shell text contains SMS bodies.
 */
final class RootBridgeTransport implements PrivilegedBridgeCoordinator.Transport {
    private static final int STARTUP_TIMEOUT_MS = 20_000;

    private final Process process;
    private final int port;
    private final String token;
    private volatile boolean closed;

    private RootBridgeTransport(Process process, int port, String token) {
        this.process = process;
        this.port = port;
        this.token = token;
    }

    static RootBridgeTransport start(Context context) throws Exception {
        int port = 20000 + new SecureRandom().nextInt(30000);
        String token = randomToken();
        File tokenFile = new File(context.getCacheDir(),
                "root-bridge-" + UUID.randomUUID() + ".token");
        try (FileOutputStream out = new FileOutputStream(tokenFile)) {
            out.write(token.getBytes(StandardCharsets.UTF_8));
        }
        String apk = context.getApplicationInfo().sourceDir;
        String command = "CLASSPATH='" + shellEscape(apk)
                + "' /system/bin/app_process /system/bin com.airsim.phonecontrol.RootBridgeMain '"
                + shellEscape(context.getPackageName()) + "' " + port + " '"
                + shellEscape(tokenFile.getAbsolutePath()) + "'";
        String su = new File("/system/bin/su").canExecute() ? "/system/bin/su" : "su";
        Process process = new ProcessBuilder(su, "-c", command)
                .redirectErrorStream(true)
                .redirectOutput(new File("/dev/null"))
                .start();
        RootBridgeTransport transport = new RootBridgeTransport(process, port, token);
        long deadline = SystemClock.elapsedRealtime() + STARTUP_TIMEOUT_MS;
        while (SystemClock.elapsedRealtime() < deadline) {
            try {
                transport.request("status", new JSONObject());
                // The helper has read the token; the app-private copy is no longer needed.
                //noinspection ResultOfMethodCallIgnored
                tokenFile.delete();
                BridgeLog.info("root_bridge_connected port=" + port);
                return transport;
            } catch (Exception error) {
                if (!process.isAlive()) break;
                try { Thread.sleep(150); } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
        transport.close();
        //noinspection ResultOfMethodCallIgnored
        tokenFile.delete();
        throw new IOException("KernelSU root bridge did not become ready");
    }

    @Override public String startBridge() throws Exception {
        return request("start_bridge", new JSONObject());
    }

    @Override public String status() throws Exception {
        return request("status", new JSONObject());
    }

    @Override public String setLocalOutputMuted(boolean muted) throws Exception {
        return request("muted", new JSONObject().put("muted", muted));
    }

    @Override public String audioSnapshot() throws Exception {
        return request("audio_snapshot", new JSONObject());
    }

    String ensureDialerRole() throws Exception {
        return request("ensure_dialer_role", new JSONObject());
    }

    String restoreRemoteScreenOff(long since, long observedAt) throws Exception {
        return request("restore_remote_screen_off", new JSONObject().put("since", since).put("observed_at", observedAt));
    }

    String sendSms(String destination, String body, int subscriptionId) throws Exception {
        return request("send_sms", new JSONObject()
                .put("destination", destination)
                .put("body", body)
                .put("subscription_id", subscriptionId));
    }

    private String request(String op, JSONObject args) throws Exception {
        if (closed) throw new IOException("root transport closed");
        JSONObject request = new JSONObject(args.toString()).put("op", op).put("token", token);
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), port), 1_500);
            socket.setSoTimeout(6_000);
            BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                    socket.getOutputStream(), StandardCharsets.UTF_8));
            writer.write(request.toString());
            writer.newLine();
            writer.flush();
            BufferedReader reader = new BufferedReader(new InputStreamReader(
                    socket.getInputStream(), StandardCharsets.UTF_8));
            String line = reader.readLine();
            if (line == null) throw new IOException("root bridge closed the connection");
            JSONObject response = new JSONObject(line);
            if (response.has("error")) throw new IOException(response.optString("error"));
            String result = response.optString("result", "");
            return result;
        }
    }

    void close() {
        closed = true;
        process.destroy();
    }

    private static String randomToken() {
        byte[] bytes = new byte[24];
        new SecureRandom().nextBytes(bytes);
        StringBuilder value = new StringBuilder(bytes.length * 2);
        for (byte item : bytes) value.append(String.format("%02x", item));
        return value.toString();
    }

    private static String shellEscape(String value) {
        return value.replace("'", "'\\''");
    }

    static boolean sameToken(String expected, String actual) {
        if (expected == null || actual == null) return false;
        return MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8),
                actual.getBytes(StandardCharsets.UTF_8));
    }
}
