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
            if (args.length < 3) throw new IllegalArgumentException("usage: package port token-file");
            String packageName = args[0];
            int port = Integer.parseInt(args[1]);
            String token = readToken(args[2]);
            Context app = appContext(packageName);
            ShizukuBridgeUserService service = new ShizukuBridgeUserService(app);
            try (ServerSocket server = new ServerSocket(port, 4, InetAddress.getLoopbackAddress())) {
                while (true) {
                    try (Socket client = server.accept()) {
                        client.setSoTimeout(6_000);
                        handle(client, service, token);
                    } catch (Throwable error) {
                        // A malformed or timed-out client must not take down PCM.
                    }
                }
            }
        } catch (Throwable error) {
            System.err.println("root bridge failed: " + error);
            System.exit(1);
        }
    }

    private static void handle(Socket client, ShizukuBridgeUserService service, String token)
            throws Exception {
        BufferedReader reader = new BufferedReader(new InputStreamReader(
                client.getInputStream(), StandardCharsets.UTF_8));
        BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                client.getOutputStream(), StandardCharsets.UTF_8));
        String line = reader.readLine();
        if (line == null) return;
        JSONObject request = new JSONObject(line);
        if (!RootBridgeTransport.sameToken(token, request.optString("token", ""))) {
            writer.write(new JSONObject().put("error", "unauthorized").toString());
            writer.newLine();
            writer.flush();
            return;
        }
        JSONObject response = new JSONObject();
        try {
            response.put("result", transact(service, request));
        } catch (Throwable error) {
            response.put("error", error.getClass().getSimpleName());
        }
        writer.write(response.toString());
        writer.newLine();
        writer.flush();
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
