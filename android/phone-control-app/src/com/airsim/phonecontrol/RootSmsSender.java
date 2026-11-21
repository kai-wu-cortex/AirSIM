package com.airsim.phonecontrol;

import android.content.Context;
import android.app.PendingIntent;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.ArrayList;
import java.util.concurrent.TimeUnit;

/** Root SMS channel with App-owned sent callbacks; no user text in a shell command. */
final class RootSmsSender {
    private static final String MARKER = "AIRSIM_ROOT_SMS:";

    private RootSmsSender() {}

    static void install(Context context) {
        Context app = context.getApplicationContext();
        SMSCommandExecutor.setRootSender((destination, body, subscriptionId) ->
                PrivilegeChannelPreference.get(app) == PrivilegeChannelPreference.Channel.SHIZUKU
                        ? "unavailable" : send(app, destination, body, subscriptionId));
    }

    private static String send(Context context, String destination, String body, int subscriptionId) {
        String su = new File("/system/bin/su").canExecute() ? "/system/bin/su" : "su";
        String readiness = RootSMSPreflight.check(() -> new ProcessBuilder(su, "-c", "id -u")
                .redirectErrorStream(true).start(), 5_000L);
        if (!"ready".equals(readiness)) {
            BridgeLog.info("sms_root_preflight result=" + readiness + " dispatched=false");
            return readiness;
        }
        return PrivilegedSmsConfirmation.send(context, destination, body, subscriptionId,
                callbacks -> dispatch(context, su, destination, body, subscriptionId, callbacks));
    }

    private static String dispatch(Context context, String su, String destination, String body,
            int subscriptionId, ArrayList<PendingIntent> callbacks) {
        Process process = null;
        String callbackToken = null;
        File payloadFile = null;
        try {
            callbackToken = RootSMSCallbackProvider.register(callbacks);
            payloadFile = new File(context.getCacheDir(), "root-sms-" + UUID.randomUUID() + ".json");
            JSONObject payload = new JSONObject()
                    .put("package_name", context.getPackageName())
                    .put("user_id", context.getApplicationInfo().uid / 100_000)
                    .put("callback_token", callbackToken)
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
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return "error:interrupted";
        } catch (Exception error) {
            return RootSMSPreflight.launchFailure(process != null, error);
        } finally {
            RootSMSCallbackProvider.revoke(callbackToken);
            if (process != null && process.isAlive()) process.destroyForcibly();
            //noinspection ResultOfMethodCallIgnored
            if (payloadFile != null) payloadFile.delete();
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
