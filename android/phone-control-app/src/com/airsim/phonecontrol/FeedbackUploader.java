package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Manual-only feedback upload; never invoked by Telecom, SMS or background timers. */
final class FeedbackUploader {
    private static final String ENDPOINT = "https://airsim-push.remotepilot.site/v1/feedback";
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();
    private static final String PREFS = "feedback_upload";
    private static final String EVENTS = "events";
    private static final String DESCRIPTION = "description";
    private static final String REMARK = "remark";

    private FeedbackUploader() {}

    static void setFields(Context context, String description, String remark) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(DESCRIPTION, description == null ? "" : description.trim())
                .putString(REMARK, remark == null ? "" : remark.trim())
                .apply();
    }

    static String description(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(DESCRIPTION, "");
    }

    static String remark(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(REMARK, "");
    }

    static void submit(Context context, String trigger, String eventID) {
        if (context == null || !FeedbackUploadPolicy.allows(trigger)) return;
        RelayEgressGate.Generation generation = RelayEgressGate.shared.generation();
        if (!generation.isCurrent()) return;
        Context app = context.getApplicationContext();
        WORKER.execute(() -> {
            try {
                if (!generation.isCurrent()) return;
                if (alreadyUploaded(app, eventID)) return;
                JSONObject body = new JSONObject()
                        .put("feedback_id", UUID.randomUUID().toString())
                        .put("trigger", trigger)
                        .put("platform", "Android")
                        .put("app_version", AppInformation.version(app))
                        .put("android_model", android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL)
                        .put("android_sdk", android.os.Build.VERSION.SDK_INT)
                        .put("connection_mode", "vowlan")
                        .put("route", "android-standalone")
                        .put("relay_status", "unknown")
                        .put("pcm", pcm(BridgeLog.read()))
                        .put("error_summary", "")
                        .put("description", description(app))
                        .put("remark", remark(app))
                        .put("android_log", BridgeLog.read());
                if (!generation.isCurrent()) return;
                post(body.toString(), generation);
                if (!generation.isCurrent()) return;
                markUploaded(app, eventID);
                BridgeLog.info("feedback_uploaded trigger=" + trigger);
            } catch (Exception error) {
                BridgeLog.error("feedback_upload_failed trigger=" + trigger, error);
            }
        });
    }

    private static void post(String body, RelayEgressGate.Generation generation) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(ENDPOINT).openConnection();
        RelayEgressGate.Lease lease = null;
        try {
            lease = RelayEgressGate.shared.acquire(generation, connection::disconnect);
            lease.checkCurrent();
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(10_000);
            connection.setReadTimeout(20_000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream output = connection.getOutputStream()) { output.write(bytes); }
            int status = connection.getResponseCode();
            lease.checkCurrent();
            if (status < 200 || status >= 300) throw new IllegalStateException("feedback HTTP " + status);
        } finally {
            try { connection.disconnect(); }
            finally { if (lease != null) lease.close(); }
        }
    }

    private static boolean alreadyUploaded(Context context, String eventID) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getStringSet(EVENTS, Set.of()).contains(eventID);
    }

    private static void markUploaded(Context context, String eventID) {
        SharedPreferences preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Set<String> values = new HashSet<>(preferences.getStringSet(EVENTS, Set.of()));
        values.add(eventID);
        if (values.size() > 200) {
            String[] all = values.toArray(new String[0]);
            values.clear();
            for (int index = Math.max(0, all.length - 200); index < all.length; index++) values.add(all[index]);
        }
        preferences.edit().putStringSet(EVENTS, values).apply();
    }

    private static JSONObject pcm(String log) throws Exception {
        String route = value("pcm_route", log);
        String capture = value("pcm_capture", log);
        boolean initialized = "true".equals(value("pcm_initialized", log));
        boolean verified = "verified".equals(route);
        int down = integer(value("pcm_down_peak", log));
        int up = integer(value("pcm_up_peak", log));
        String mode;
        if (!initialized || route.isEmpty()) mode = "not_connected";
        else if (verified && down > 0 && up > 0) mode = "vowlan_direct_full_duplex";
        else if (verified && down > 0) mode = "vowlan_direct_downlink_only";
        else if (verified && up > 0) mode = "vowlan_direct_uplink_only";
        else mode = "vowlan_direct_silent";
        return new JSONObject()
                .put("mode", mode)
                .put("route", route)
                .put("capture_source", capture.isEmpty() ? "voice_downlink" : capture)
                .put("initialized", initialized)
                .put("route_verified", verified)
                .put("capture", capture.isEmpty() ? "unverified" : capture)
                .put("down_peak", down)
                .put("up_peak", up)
                .put("down_bytes", integer(value("pcm_down_bytes", log)))
                .put("up_bytes", integer(value("pcm_up_bytes", log)))
                .put("failure", value("pcm_failure", log));
    }

    private static String value(String key, String log) {
        Matcher match = Pattern.compile("(?:^|\\s)" + Pattern.quote(key) + "=([^\\s]+)")
                .matcher(log == null ? "" : log);
        return match.find() ? match.group(1) : "";
    }

    private static int integer(String value) {
        try { return Integer.parseInt(value); } catch (NumberFormatException ignored) { return 0; }
    }
}
