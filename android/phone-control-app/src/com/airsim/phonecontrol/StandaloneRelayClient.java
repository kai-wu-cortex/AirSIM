package com.airsim.phonecontrol;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Small HTTPS-only Relay client used by the embedded Android Agent. */
final class StandaloneRelayClient {
    record Response(int status, String body) {}

    Response post(JSONObject registration, String path, JSONObject payload, int timeoutMillis) throws Exception {
        String base = registration.getString("relay_url");
        URI target = URI.create(base + path);
        if (!"https".equalsIgnoreCase(target.getScheme()) || target.getHost() == null
                || target.getRawUserInfo() != null) {
            throw new IllegalArgumentException("Relay 必须使用无凭据 HTTPS 地址");
        }
        HttpURLConnection connection = (HttpURLConnection) new URL(target.toString()).openConnection();
        try {
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(8_000);
            connection.setReadTimeout(timeoutMillis);
            connection.setUseCaches(false);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            connection.setRequestProperty("User-Agent", "AirSIM-Standalone/0.1");
            byte[] body = payload.toString().getBytes(StandardCharsets.UTF_8);
            try (OutputStream output = connection.getOutputStream()) { output.write(body); }
            int status = connection.getResponseCode();
            InputStream stream = status >= 200 && status < 300
                    ? connection.getInputStream() : connection.getErrorStream();
            return new Response(status, read(stream));
        } finally {
            connection.disconnect();
        }
    }

    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeoutMillis)
            throws Exception {
        Response response = post(registration, path, payload, timeoutMillis);
        if (response.status < 200 || response.status >= 300) {
            throw new IllegalStateException("Relay HTTP " + response.status + ": " + response.body);
        }
        return response.body.isBlank() ? new JSONObject() : new JSONObject(response.body);
    }

    private static String read(InputStream input) throws Exception {
        if (input == null) return "";
        try (input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            return output.toString(StandardCharsets.UTF_8);
        }
    }
}
