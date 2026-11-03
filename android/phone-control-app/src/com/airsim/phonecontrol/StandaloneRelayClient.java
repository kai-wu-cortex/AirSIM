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
    record Response(int status, String body, long retryAfterMillis) {}

    Response post(JSONObject registration, String path, JSONObject payload, int timeoutMillis) throws Exception {
        return post(registration, path, payload, timeoutMillis, RelayEgressGate.shared.generation(), null, 0);
    }

    private Response post(JSONObject registration, String path, JSONObject payload, int timeoutMillis,
                          RelayEgressGate.Generation generation,
                          RelayCommandRetryState lifetime, long epoch) throws Exception {
        String base = registration.getString("relay_url");
        URI target = URI.create(base + path);
        if (!"https".equalsIgnoreCase(target.getScheme()) || target.getHost() == null
                || target.getRawUserInfo() != null) {
            throw new IllegalArgumentException("Relay 必须使用无凭据 HTTPS 地址");
        }
        HttpURLConnection connection = (HttpURLConnection) new URL(target.toString()).openConnection();
        RelayEgressGate.Lease lease = null;
        try {
            lease = RelayEgressGate.shared.acquire(generation, connection::disconnect);
            lease.checkCurrent();
            if (lifetime != null && !lifetime.attach(epoch, connection::disconnect)) {
                throw new java.io.IOException("stale_sms_operation");
            }
            connection.setRequestMethod("POST");
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(8_000);
            connection.setReadTimeout(timeoutMillis);
            connection.setUseCaches(false);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            connection.setRequestProperty("User-Agent", "AirSIM-Standalone/0.1");
            byte[] body = payload.toString().getBytes(StandardCharsets.UTF_8);
            if (lifetime != null && !lifetime.isCurrent(epoch)) throw new java.io.IOException("stale_sms_operation");
            lease.checkCurrent();
            try (OutputStream output = connection.getOutputStream()) { output.write(body); }
            int status = connection.getResponseCode();
            InputStream stream = status >= 200 && status < 300
                    ? connection.getInputStream() : connection.getErrorStream();
            Response response = new Response(status, read(stream), RelayHTTPException.parseRetryAfter(
                    connection.getHeaderField("Retry-After"), System.currentTimeMillis()));
            lease.checkCurrent();
            if (lifetime != null && !lifetime.isCurrent(epoch)) throw new java.io.IOException("stale_sms_operation");
            return response;
        } finally {
            try { connection.disconnect(); }
            finally { if (lease != null) lease.close(); }
        }
    }

    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeoutMillis)
            throws Exception {
        return postJSON(registration, path, payload, timeoutMillis, RelayEgressGate.shared.generation());
    }

    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeoutMillis,
                        RelayEgressGate.Generation generation) throws Exception {
        return postJSON(registration, path, payload, timeoutMillis, generation, null, 0);
    }

    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeoutMillis,
                        RelayEgressGate.Generation generation,
                        RelayCommandRetryState lifetime, long epoch) throws Exception {
        Response response = post(registration, path, payload, timeoutMillis, generation, lifetime, epoch);
        if (response.status < 200 || response.status >= 300) {
            throw new RelayHTTPException(response.status, response.body, response.retryAfterMillis);
        }
        return response.body.isBlank() ? new JSONObject() : new JSONObject(response.body);
    }

    private static String read(InputStream input) throws Exception {
        if (input == null) return "";
        try (input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
