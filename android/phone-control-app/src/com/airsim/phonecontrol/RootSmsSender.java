package com.airsim.phonecontrol;

import android.content.Context;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

/** KernelSU/root SMS channel. Payload goes over stdin; no user text in a shell command. */
final class RootSmsSender {
    private static final String MARKER = "AIRSIM_ROOT_SMS:";

    private RootSmsSender() {}

    static void install(Context context) {
        Context app = context.getApplicationContext();
        SMSCommandExecutor.setRootSender((destination, body, subscriptionId) ->
                send(app, destination, body, subscriptionId));
    }

    private static String send(Context context, String destination, String body, int subscriptionId) {
        Process process = null;
        File payloadFile = new File(context.getCacheDir(), "root-sms-" + UUID.randomUUID() + ".json");
        try {
            JSONObject payload = new JSONObject()
                    .put("destination", destination)
                    .put("body", body)
                    .put("subscription_id", subscriptionId);
            try (FileOutputStream output = new FileOutputStream(payloadFile)) {
                output.write(payload.toString().getBytes(StandardCharsets.UTF_8));
            }
            String apk = context.getApplicationInfo().sourceDir;
            String escapedApk = apk.replace("'", "'\\''");
            String escapedPayload = payloadFile.getAbsolutePath().replace("'", "'\\''");
            String command = "CLASSPATH='" + escapedApk
                    + "' /system/bin/app_process /system/bin com.airsim.phonecontrol.RootSmsMain '"
                    + escapedPayload + "'";
            String su = new File("/system/bin/su").canExecute() ? "/system/bin/su"
                    : (new File("/debug_ramdisk/su").canExecute() ? "/debug_ramdisk/su" : "su");
            process = new ProcessBuilder(su, "-c", command)
                    .redirectErrorStream(true)
                    .start();
            if (!process.waitFor(20, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                return "error:timeout";
            }
            String output = readAll(process.getInputStream());
            int marker = output.lastIndexOf(MARKER);
            if (marker < 0) return "error:no_result";
            String value = output.substring(marker + MARKER.length()).trim();
            int newline = value.indexOf('\n');
            if (newline >= 0) value = value.substring(0, newline).trim();
            return value;
        } catch (Exception error) {
            return "error:" + error.getClass().getSimpleName();
        } finally {
            if (process != null && process.isAlive()) process.destroyForcibly();
            //noinspection ResultOfMethodCallIgnored
            payloadFile.delete();
        }
    }

    private static String readAll(InputStream input) throws java.io.IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = input.read(buffer)) >= 0) {
            if (count > 0) output.write(buffer, 0, count);
            if (output.size() > 64 * 1024) throw new java.io.IOException("output too large");
        }
        return new String(output.toByteArray(), StandardCharsets.UTF_8);
    }
}
