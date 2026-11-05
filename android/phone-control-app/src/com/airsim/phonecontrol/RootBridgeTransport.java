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
    private final File ownerFile;
    private volatile boolean closed;

    private RootBridgeTransport(Process process, int port, String token, File ownerFile) {
        this.process = process;
        this.port = port;
        this.token = token;
        this.ownerFile = ownerFile;
    }

    static RootBridgeTransport start(Context context) throws Exception {
        File daemonTokenFile = new File("/data/local/tmp/airsim-bridge.token");
        if (daemonTokenFile.isFile() && daemonTokenFile.canRead()) {
            try {
                String daemonToken = new String(java.nio.file.Files.readAllBytes(daemonTokenFile.toPath()), StandardCharsets.UTF_8).trim();
                if (!daemonToken.isEmpty()) {
                    RootBridgeTransport daemon = new RootBridgeTransport(null, 27580, daemonToken, daemonTokenFile);
                    daemon.request("status", new JSONObject());
                    BridgeLog.info("root_bridge_connected port=27580 mode=daemon");
                    return daemon;
                }
            } catch (Exception ignored) {}
        }
        int port = 20000 + new SecureRandom().nextInt(30000);
        String token = randomToken();
        int ownerPid = android.os.Process.myPid();
        String ownerStart = RootHelperIdentity.startTime(new String(java.nio.file.Files.readAllBytes(
                new File("/proc/" + ownerPid + "/stat").toPath()), StandardCharsets.UTF_8));
        if (ownerStart.isEmpty()) throw new IOException("app process identity unavailable");
        File tokenFile = new File(context.getNoBackupFilesDir(),
                "root-bridge-" + UUID.randomUUID() + ".token");
        try (FileOutputStream out = new FileOutputStream(tokenFile)) {
            out.write(token.getBytes(StandardCharsets.UTF_8));
        } catch (IOException error) {
            tokenFile.delete();
            throw error;
        }
        String apk = context.getApplicationInfo().sourceDir;
        String command = "CLASSPATH='" + shellEscape(apk)
                + "' /system/bin/app_process /system/bin com.airsim.phonecontrol.RootBridgeMain '"
                + shellEscape(context.getPackageName()) + "' " + port + " '"
                + shellEscape(tokenFile.getAbsolutePath()) + "' " + ownerPid + " " + ownerStart;
        String su = new File("/system/bin/su").canExecute() ? "/system/bin/su"
                : (new File("/debug_ramdisk/su").canExecute() ? "/debug_ramdisk/su" : "su");
        Process process;
        try {
            process = new ProcessBuilder(su, "-c", command)
                    .redirectErrorStream(true)
                    .redirectOutput(new File("/dev/null"))
                    .start();
        } catch (IOException | RuntimeException error) {
            tokenFile.delete();
            throw error;
        }
        RootBridgeTransport transport = new RootBridgeTransport(process, port, token, tokenFile);
        long deadline = SystemClock.elapsedRealtime() + STARTUP_TIMEOUT_MS;
        while (SystemClock.elapsedRealtime() < deadline) {
            try {
                transport.request("status", new JSONObject());
                // Keep the private file as a lifetime lease. Its removal also stops
                // the helper if an authenticated shutdown request cannot get through.
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
        // A removed Shizuku daemon may still be releasing the ownership socket.
        // Bounded retry permits that handover without killing its PCM process.
        for (int attempt = 0; ; attempt++) {
            try { return request("start_bridge", new JSONObject()); }
            catch (IOException error) {
                if (attempt >= 9 || closed || !ownerFile.exists()) throw error;
                Thread.sleep(250);
            }
        }
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

    synchronized void close() {
        if (closed) return;
        if (process == null) {
            closed = true;
            return;
        }
        try {
            // Killing su alone can leave app_process and its PCM supervisor alive.
            // The authenticated shutdown waits for the owned PCM child to stop.
            request("shutdown", new JSONObject());
        } catch (Exception ignored) {
            // The helper also watches the removed lease file and app process identity.
        } finally {
            ownerFile.delete();
            closed = true;
            process.destroy();
        }
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
