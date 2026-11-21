package com.airsim.phonecontrol;

import android.app.PendingIntent;
import android.os.Bundle;
import android.telephony.SmsManager;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

/**
 * Root-only helper launched as app_process by KernelSU. It never receives shell
 * metacharacters on its command line: the JSON payload is read from an app-private file.
 */
public final class RootSmsMain {
    private RootSmsMain() {}

    public static void main(String[] args) {
        run(args);
        // The callback handoff starts Binder threads. The App owns the actual
        // receivers, so the helper must exit without waiting for those threads.
        System.exit(0);
    }

    private static void run(String[] args) {
        String stage = "prepare";
        try {
            if (android.os.Looper.myLooper() == null) android.os.Looper.prepareMainLooper();
            String input = args.length > 0 && !args[0].isEmpty()
                    ? readAll(new java.io.FileInputStream(args[0])) : readAll(System.in);
            JSONObject payload = new JSONObject(input);
            String destination = payload.optString("destination", "").trim();
            String body = payload.optString("body", "");
            int subscriptionId = payload.optInt("subscription_id", -1);
            if (destination.isEmpty() || body.trim().isEmpty()) { result("error:invalid"); return; }
            String packageName = payload.optString("package_name", "");
            if (!packageName.matches("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+")) { result("error:invalid"); return; }
            SmsManager manager = PrivilegedSmsRuntime.manager(RootBridgeMain.appContext(packageName), subscriptionId);
            if (manager == null) { result("error:no_service"); return; }
            ArrayList<String> parts = manager.divideMessage(body);
            if (parts == null || parts.isEmpty()) { result("error:divide"); return; }
            int userId = payload.optInt("user_id", -1);
            if (userId < 0) { result("error:prepare:missing_user"); return; }
            // A bare app_process cannot register ordinary App receivers reliably.
            // Claim the real App's PendingIntents via Binder before dispatching anything.
            Bundle bundle = ShellProviderQuery.call(packageName + RootSMSCallbackProvider.SUFFIX,
                    userId, RootSMSCallbackProvider.CLAIM, payload.optString("callback_token", ""));
            if (bundle == null) { result("error:prepare:missing_callbacks"); return; }
            bundle.setClassLoader(PendingIntent.class.getClassLoader());
            ArrayList<PendingIntent> callbacks = bundle.getParcelableArrayList(RootSMSCallbackProvider.CALLBACKS);
            if (callbacks == null || callbacks.size() != parts.size() || callbacks.contains(null)) {
                result("error:prepare:callback_count"); return;
            }
            stage = "send_unknown";
            if (parts.size() == 1) {
                manager.sendTextMessage(destination, null, parts.get(0), callbacks.get(0), null);
            } else {
                manager.sendMultipartTextMessage(destination, null, parts, callbacks, null);
            }
            result("ok:" + parts.size());
        } catch (SecurityException error) {
            result("error:" + stage + ":SecurityException");
        } catch (Throwable error) {
            result("error:" + stage + ":" + error.getClass().getSimpleName());
        }
    }

    private static String readAll(InputStream input) throws java.io.IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = input.read(buffer)) >= 0) {
            if (count > 0) output.write(buffer, 0, count);
            if (output.size() > 64 * 1024) throw new java.io.IOException("payload too large");
        }
        return new String(output.toByteArray(), StandardCharsets.UTF_8);
    }

    private static void result(String value) {
        System.out.println("AIRSIM_ROOT_SMS:" + value);
        System.out.flush();
    }
}
