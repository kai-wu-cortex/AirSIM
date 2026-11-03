package com.airsim.phonecontrol;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Best-effort notification egress owned by Android. It never blocks call/SMS
 * handling, never goes through Relay/APNs, and therefore survives iPhone force
 * quit and Relay quota outages.
 */
final class NotificationForwarder {
    private static final ExecutorService WORKERS = Executors.newSingleThreadExecutor(r -> {
        Thread thread = new Thread(r, "AirSIMForwarder");
        thread.setDaemon(true);
        return thread;
    });

    private NotificationForwarder() {}

    static void handle(Context context, JSONObject event) {
        RelayEgressGate.Generation generation = RelayEgressGate.shared.generation();
        if (!generation.isCurrent()) return;
        JSONObject config = ForwardingConfigStore.config(context);
        if (!config.optBoolean("enabled", false)) return;
        JSONArray destinations = config.optJSONArray("destinations");
        if (destinations == null || destinations.length() == 0) return;

        String type = event.optString("event", "");
        // Older SMS events had no event field; delivery_id + no call direction is
        // the stable SMS identity. Keep both forms so existing queues forward too.
        boolean sms = "incoming_sms".equals(type) || "sms".equals(type)
                || (event.has("delivery_id") && !event.has("call_id"));
        boolean call = type.contains("call") || event.has("direction");
        boolean ringing = "incoming".equals(event.optString("direction"))
                && "incoming".equals(event.optString("state"));
        // Legacy call events had no missed field. Preserve forwarding for queued
        // missed calls; new events carry the authoritative missed flag.
        boolean missed = event.has("missed")
                ? event.optBoolean("missed", false)
                : "incoming".equals(event.optString("direction"))
                    && "ended".equals(event.optString("state"));

        for (int i = 0; i < destinations.length(); i++) {
            JSONObject destination = destinations.optJSONObject(i);
            if (destination == null || !destination.optBoolean("enabled", true)) continue;
            if (sms && !destination.optBoolean("sendSMS", true)) continue;
            if (call && ringing && !destination.optBoolean("sendIncomingCall", true)) continue;
            if (call && missed && !destination.optBoolean("sendMissedCall", true)) continue;
            if (call && !ringing && !missed) continue;
            if (!sms && !call) continue;
            if (call && ringing && !destination.optBoolean("sendIncomingCall", true)) {
                BridgeLog.info("notification_forward_skipped channel="
                        + destination.optString("channel") + " reason=incoming_disabled");
                continue;
            }
            final JSONObject target = destination;
            final JSONObject payload = event;
            WORKERS.execute(() -> {
                if (generation.isCurrent()) send(context, target, payload, sms, missed, generation);
            });
        }
    }

    private static void send(Context context, JSONObject destination, JSONObject event,
                             boolean sms, boolean missed, RelayEgressGate.Generation generation) {
        try {
            String delivery = event.optString("delivery_id", "");
            if (delivery.isEmpty()) {
                // Call events do not carry delivery_id/call_uuid. A constant
                // ":incoming" key used to suppress every call after the first.
                delivery = event.optString("call_id",
                        event.optString("event_id", "call"))
                        + ":" + event.optString("state")
                        + ":" + event.optString("direction");
            }
            if (delivery.isEmpty() || alreadyForwarded(context, destination, delivery)) return;

            String text = render(destination, event, sms, missed);
            String channel = destination.optString("channel", "webhook");
            String url = destination.optString("webhookURL", "");
            JSONObject body = new JSONObject();
            String method = "POST";
            String contentType = "application/json";

            switch (channel) {
                case "bark" -> {
                    String[] target = barkTarget(url, destination.optString("deviceKey", ""));
                    url = target[0];
                    body.put("device_key", target[1])
                            .put("title", barkTitle(sms, missed))
                            .put("body", text)
                            .put("group", "AirSIM")
                            // timeSensitive can be suppressed by Focus; use active
                            // for reliable call alerts, matching SMS behavior.
                            .put("level", "active")
                            .put("isArchive", "1");
                }
                case "discord" -> body.put("content", text);
                case "slack" -> body.put("text", text);
                case "wecom" -> body.put("msgtype", "text")
                        .put("text", new JSONObject().put("content", text));
                case "feishu" -> {
                    body.put("msg_type", "text")
                            .put("content", new JSONObject().put("text", text));
                    addFeishuSignature(destination, body);
                }
                case "telegram" -> {
                    String token = destination.optString("token", "");
                    if (url.isEmpty()) url = "https://api.telegram.org/bot" + token + "/sendMessage";
                    body.put("chat_id", destination.optString("chatID", ""));
                    body.put("text", text);
                }
                case "qq" -> {
                    String chatID = destination.optString("chatID", "");
                    if (url.isEmpty()) url = "https://api.sgroup.qq.com/v2/users/"
                            + java.net.URLEncoder.encode(chatID, "UTF-8") + "/messages";
                    body.put("content", text).put("msg_type", 0);
                    contentType = "application/json";
                }
                default -> body.put("text", text)
                        .put("event", event.optString("event"))
                        .put("device", deviceName())
                        .put("number", destination.optBoolean("includeNumber", true)
                                ? event.optString("number") : "")
                        .put("sender", event.optString("sender"))
                        .put("content", destination.optBoolean("includeBody", true)
                                ? event.optString("content") : "")
                        .put("time", Instant.now().toString());
            }
            if (url.isBlank()) return;
            if ("qq".equals(channel) && !destination.optString("token", "").isBlank()) {
                // Authorization is passed separately below.
            }
            if (!generation.isCurrent()) return;
            post(url, body.toString(), destination, channel, generation);
            if (!generation.isCurrent()) return;
            markForwarded(context, destination, delivery);
            BridgeLog.info("notification_forwarded channel=" + channel);
        } catch (Exception error) {
            BridgeLog.error("notification_forward_failed", error);
        }
    }

    private static String barkTitle(boolean sms, boolean missed) {
        return sms ? "AirSIM 短信" : missed ? "AirSIM 未接来电" : "AirSIM 来电";
    }

    private static String[] barkTarget(String configured, String key) throws Exception {
        String value = configured == null ? "" : configured.trim();
        if (value.isEmpty()) value = "https://api.day.app/push";
        URL url = new URL(value);
        if (!"https".equalsIgnoreCase(url.getProtocol())) {
            throw new IllegalArgumentException("Bark endpoint must use HTTPS");
        }
        String path = url.getPath();
        if (path.endsWith("/push")) {
            if (key == null || key.isBlank()) throw new IllegalArgumentException("Bark device key missing");
            return new String[]{url.toString(), key.trim()};
        }
        String[] segments = path.split("/");
        String pathKey = segments.length == 0 ? "" : segments[segments.length - 1].trim();
        String deviceKey = key == null || key.isBlank() ? pathKey : key.trim();
        if (deviceKey.isBlank()) throw new IllegalArgumentException("Bark device key missing");
        String endpoint = url.getProtocol() + "://" + url.getAuthority() + "/push";
        return new String[]{endpoint, deviceKey};
    }

    private static String render(JSONObject destination, JSONObject event,
                                 boolean sms, boolean missed) {
        String template = missed
                ? destination.optString("missedTemplate", "")
                : destination.optString("template", "");
        if (template.isBlank()) {
            template = missed
                    ? "{event}\n{device}\n{number}\n{time}"
                    : "{event}\n{device}\n{number}\n{sender}\n{content}\n{time}";
        }
        String number = destination.optBoolean("includeNumber", true)
                ? event.optString("number", "") : "";
        String content = destination.optBoolean("includeBody", true)
                ? event.optString("content", "") : "";
        String eventName = sms ? "短信" : missed ? "未接来电" : "来电";
        String device = deviceName();
        return template
                .replace("{event}", eventName)
                .replace("{device}", device)
                .replace("{number}", number)
                .replace("{sender}", event.optString("sender", ""))
                .replace("{content}", content)
                .replace("{time}", Instant.now().toString());
    }

    private static void post(String endpoint, String body, JSONObject destination,
                             String channel, RelayEgressGate.Generation generation) throws Exception {
        URL url = new URL(endpoint);
        if (!"https".equalsIgnoreCase(url.getProtocol())) {
            throw new IllegalArgumentException("forwarding webhook must use HTTPS");
        }
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        RelayEgressGate.Lease lease = null;
        try {
            lease = RelayEgressGate.shared.acquire(generation, connection::disconnect);
            lease.checkCurrent();
            connection.setInstanceFollowRedirects(false);
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(8_000);
            connection.setReadTimeout(10_000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            if ("qq".equals(channel)) {
                String token = destination.optString("token", "");
                if (!token.isBlank()) connection.setRequestProperty("Authorization", "QQBot " + token);
            }
            try (OutputStream output = connection.getOutputStream()) {
                output.write(body.getBytes(StandardCharsets.UTF_8));
            }
            int status = connection.getResponseCode();
            String responseBody = read(status >= 200 && status < 300
                    ? connection.getInputStream() : connection.getErrorStream());
            lease.checkCurrent();
            if (status < 200 || status >= 300) {
                throw new IllegalStateException("forwarding HTTP " + status);
            }
            if (!responseBody.isBlank()) {
                JSONObject reply = new JSONObject(responseBody);
                if ("feishu".equals(channel)) {
                    int code = reply.optInt("code", reply.optInt("StatusCode", 0));
                    if (code != 0) {
                        throw new IllegalStateException("feishu code=" + code
                                + " msg=" + reply.optString("msg", reply.optString("StatusMessage", "")));
                    }
                } else if ("wecom".equals(channel)) {
                    int errcode = reply.optInt("errcode", 0);
                    if (errcode != 0) {
                        throw new IllegalStateException("wecom errcode=" + errcode
                                + " msg=" + reply.optString("errmsg", ""));
                    }
                } else if ("slack".equals(channel) || "telegram".equals(channel)) {
                    if (reply.has("ok") && !reply.optBoolean("ok", true)) {
                        throw new IllegalStateException(channel + " rejected: "
                                + reply.optString("error", reply.optString("description", "")));
                    }
                } else if ("qq".equals(channel)) {
                    int code = reply.optInt("code", 0);
                    if (code != 0) {
                        throw new IllegalStateException("qq code=" + code
                                + " message=" + reply.optString("message", ""));
                    }
                }
            }
        } finally {
            try { connection.disconnect(); }
            finally { if (lease != null) lease.close(); }
        }
    }

    private static void addFeishuSignature(JSONObject destination, JSONObject body) throws Exception {
        String secret = destination.optString("secret", "");
        if (secret.isBlank()) return;
        long timestamp = System.currentTimeMillis() / 1000;
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec((timestamp + "\n" + secret).getBytes(StandardCharsets.UTF_8),
                "HmacSHA256"));
        String sign = Base64.getEncoder().encodeToString(
                mac.doFinal(new byte[0]));
        body.put("timestamp", String.valueOf(timestamp)).put("sign", sign);
    }

    private static String read(InputStream input) throws Exception {
        if (input == null) return "";
        try (input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            return output.toString(StandardCharsets.UTF_8.name());
        }
    }

    private static boolean alreadyForwarded(Context context, JSONObject destination, String delivery) {
        String id = destination.optString("id", "") + ":" + delivery;
        return context.getSharedPreferences("notification_forwarding", Context.MODE_PRIVATE)
                .getStringSet("sent", java.util.Collections.emptySet()).contains(id);
    }

    private static void markForwarded(Context context, JSONObject destination, String delivery) {
        String id = destination.optString("id", "") + ":" + delivery;
        android.content.SharedPreferences preferences =
                context.getSharedPreferences("notification_forwarding", Context.MODE_PRIVATE);
        java.util.Set<String> sent = new java.util.HashSet<>(
                preferences.getStringSet("sent", java.util.Collections.emptySet()));
        sent.add(id);
        while (sent.size() > 256) sent.remove(sent.iterator().next());
        preferences.edit().putStringSet("sent", sent).apply();
    }

    private static String deviceName() {
        return android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL;
    }
}
