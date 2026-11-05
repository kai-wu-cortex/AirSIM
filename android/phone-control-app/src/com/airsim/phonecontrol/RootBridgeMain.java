package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Looper;
import android.os.Parcel;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.io.File;

/**
 * KernelSU root process. It hosts the same ShizukuBridgeUserService protocol
 * over a token-authenticated loopback socket so the app can run PCM, audio
 * mute/snapshot and dialer-role operations without Shizuku.
 */
public final class RootBridgeMain {
    private RootBridgeMain() {}

    public static void main(String[] args) {
        try {
            // app_process starts on a bare main thread. ActivityThread.systemMain()
            // constructs a Handler and otherwise throws
            // "Can't create handler inside thread ... that has not called Looper.prepare()".
            if (Looper.myLooper() == null) Looper.prepareMainLooper();
            if (args.length != 5) throw new IllegalArgumentException("usage: package port token-file owner-pid owner-start");
            String packageName = args[0];
            int port = Integer.parseInt(args[1]);
            String token = readToken(args[2]);
            Context app = appContext(packageName);
            int ownerPid = Integer.parseInt(args[3]);
            String ownerStart = args[4];
            if (!ownerAlive(ownerPid, ownerStart, args[2])) throw new IllegalStateException("app owner unavailable");
            retireLegacyHelpers(packageName, app.getCacheDir().getAbsolutePath());
            ShizukuBridgeUserService service = new ShizukuBridgeUserService(app);
            try (ServerSocket server = new ServerSocket(port, 4, InetAddress.getLoopbackAddress())) {
                Thread ownerMonitor = new Thread(() -> {
                    try {
                        while (!server.isClosed() && ownerAlive(ownerPid, ownerStart, args[2])) Thread.sleep(500);
                    } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
                    try { server.close(); } catch (Exception ignored) {}
                    service.shutdown();
                }, "airsim-root-owner");
                ownerMonitor.setDaemon(true);
                ownerMonitor.start();
                while (!server.isClosed()) {
                    try (Socket client = server.accept()) {
                        client.setSoTimeout(6_000);
                        if (!handle(client, service, token)) break;
                    } catch (Throwable error) {
                        // A malformed or timed-out client must not take down PCM.
                    }
                }
            } finally {
                service.shutdown();
                new File(args[2]).delete();
            }
            System.exit(0); // Binder pool threads otherwise keep this app_process alive.
        } catch (Throwable error) {
            System.err.println("root bridge failed: " + error);
            System.exit(1);
        }
    }

    private static boolean handle(Socket client, ShizukuBridgeUserService service, String token)
            throws Exception {
        BufferedReader reader = new BufferedReader(new InputStreamReader(
                client.getInputStream(), StandardCharsets.UTF_8));
        BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                client.getOutputStream(), StandardCharsets.UTF_8));
        String line = reader.readLine();
        if (line == null) return true;
        JSONObject request = new JSONObject(line);
        if (!RootBridgeTransport.sameToken(token, request.optString("token", ""))) {
            writer.write(new JSONObject().put("error", "unauthorized").toString());
            writer.newLine();
            writer.flush();
            return true;
        }
        JSONObject response = new JSONObject();
        boolean shutdown = "shutdown".equals(request.optString("op", ""));
        try {
            if (shutdown) {
                service.shutdown();
                response.put("result", "stopped");
            } else response.put("result", transact(service, request));
        } catch (Throwable error) {
            response.put("error", error.getClass().getSimpleName());
        }
        writer.write(response.toString());
        writer.newLine();
        writer.flush();
        return !shutdown;
    }

    private static boolean ownerAlive(int pid, String start, String leasePath) {
        if (pid <= 0 || start.isEmpty() || !new File(leasePath).isFile()) return false;
        try {
            String stat = new String(Files.readAllBytes(new File("/proc/" + pid + "/stat").toPath()), StandardCharsets.UTF_8);
            return start.equals(RootHelperIdentity.startTime(stat));
        } catch (Exception ignored) { return false; }
    }

    private static void retireLegacyHelpers(String packageName, String cachePath) throws Exception {
        File[] processes = new File("/proc").listFiles();
        if (processes == null) return;
        for (File entry : processes) {
            int pid;
            String command;
            String identity;
            try {
                pid = Integer.parseInt(entry.getName());
                command = new String(Files.readAllBytes(new File(entry, "cmdline").toPath()), StandardCharsets.UTF_8);
                identity = RootHelperIdentity.startTime(new String(Files.readAllBytes(new File(entry, "stat").toPath()), StandardCharsets.UTF_8));
            } catch (NumberFormatException | java.io.IOException | SecurityException ignored) { continue; }
            if (!RootHelperIdentity.isLegacyHelper(command, packageName, cachePath) || identity.isEmpty()) continue;
            try {
                String current = RootHelperIdentity.startTime(new String(Files.readAllBytes(new File(entry, "stat").toPath()), StandardCharsets.UTF_8));
                if (!identity.equals(current)) continue;
            } catch (java.io.IOException ignored) { continue; }
            // Retire only this package/user's legacy supervisor, before PCM orphan
            // cleanup. Current owner-aware helpers and Shizuku are never selected.
            android.os.Process.killProcess(pid);
            long deadline = android.os.SystemClock.elapsedRealtime() + 2000;
            while (entry.exists() && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(25);
            if (entry.exists()) throw new java.io.IOException("legacy Root supervisor did not stop");
        }
    }

    private static String transact(ShizukuBridgeUserService service, JSONObject request)
            throws Exception {
        String op = request.optString("op", "");
        int code;
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            switch (op) {
                case "start_bridge" -> code = PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE;
                case "status" -> code = PrivilegedBridgeProtocol.TRANSACTION_STATUS;
                case "muted" -> {
                    code = PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED;
                    data.writeInt(request.optBoolean("muted", false) ? 1 : 0);
                }
                case "output_policy" -> {
                    code = PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_POLICY;
                    data.writeInt(request.optBoolean("muted", false) ? 1 : 0);
                    data.writeString(request.optString("transport", "vowlan"));
                    data.writeString(request.getString("policy"));
                }
                case "audio_snapshot" -> code = PrivilegedBridgeProtocol.TRANSACTION_AUDIO_SNAPSHOT;
                case "ensure_dialer_role" -> code = PrivilegedBridgeProtocol.TRANSACTION_ENSURE_DIALER_ROLE;
                case "send_sms" -> {
                    code = PrivilegedBridgeProtocol.TRANSACTION_SEND_SMS;
                    data.writeString(request.optString("destination", ""));
                    data.writeString(request.optString("body", ""));
                    data.writeInt(request.optInt("subscription_id", -1));
                }
                default -> throw new IllegalArgumentException("unknown operation");
            }
            if (!service.transact(code, data, reply, 0)) throw new IllegalStateException("transaction rejected");
            reply.readException();
            String result = reply.readString();
            return result == null ? "" : result;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private static String readToken(String path) throws Exception {
        try (FileInputStream input = new FileInputStream(path)) {
            byte[] bytes = new byte[256];
            int count = input.read(bytes);
            if (count <= 0) throw new IllegalStateException("empty token");
            return new String(bytes, 0, count, StandardCharsets.UTF_8).trim();
        }
    }

    private static Context appContext(String packageName) throws Exception {
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("currentActivityThread").invoke(null);
        if (thread == null) thread = activityThread.getMethod("systemMain").invoke(null);
        Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        return system.createPackageContext(packageName, 0);
    }
}
