package com.airsim.phonecontrol;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class AgentClient {
    public record ForwardResponse(int status, String payload) {}

    private final String endpoint;
    private final String token;

    public AgentClient(Context context) {
        Context appContext = context.getApplicationContext();
        endpoint = AppConfig.endpoint(appContext);
        token = AppConfig.token(appContext);
        BridgeLog.debug("agent_endpoint_selected endpoint=" + endpoint);
    }

    AgentClient(String endpoint, String token) {
        this.endpoint = endpoint;
        this.token = token;
    }

    public String status() throws Exception {
        return request("GET", "/api/android/status", null, 5_000);
    }

    public String nextCommand() throws Exception {
        return request("GET", "/api/android/commands/next?wait=25", null, 32_000);
    }

    public void sendEvent(String json) throws Exception {
        request("POST", "/api/android/calls/event", json, 8_000);
    }

	public void sendSMSEvent(String json) throws Exception {
		request("POST", "/api/android/sms/event", json, 8_000);
	}

    public void sendResult(String id, boolean success, String error) throws Exception {
        request("POST", "/api/android/commands/result", WireJson.commandResult(id, success, error), 8_000);
    }

	public void sendResult(String id, boolean success, String error, int segments) throws Exception {
		request("POST", "/api/android/commands/result", WireJson.commandResult(id, success, error, segments), 8_000);
	}

    public String registerPairing(String registrationJSON) throws Exception {
        return request("POST", "/api/android/pair/register", registrationJSON, 8_000);
    }

    public ForwardResponse forwardVoWLAN(String method, String path, String body) throws Exception {
        if (!VoWLANControlPolicy.allowed(method, path) || "/v1/health".equals(path)) {
            throw new IllegalArgumentException("VoWLAN route not allowed");
        }
        return requestRaw(method, path, body, path.startsWith("/api/events") || path.startsWith("/api/calls/events")
                ? 35_000 : 8_000);
    }

    private String request(String method, String path, String body, int readTimeout) throws Exception {
        ForwardResponse response = requestRaw(method, path, body, readTimeout);
        if (response.status < 200 || response.status >= 300) {
            throw new IllegalStateException("Agent HTTP " + response.status + ": " + response.payload);
        }
        return response.payload;
    }

    private ForwardResponse requestRaw(String method, String path, String body, int readTimeout) throws Exception {
        long started = System.nanoTime();
        String traceID = "android-" + System.currentTimeMillis();
        int requestBytes = body == null ? 0 : body.getBytes(StandardCharsets.UTF_8).length;
        BridgeLog.debug("http_request_started method=" + method + " path=" + path + " endpoint=" + endpoint
                + " timeout_ms=" + readTimeout + " request_bytes=" + requestBytes + " trace_id=" + traceID);
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(endpoint + path).openConnection();
            connection.setRequestMethod(method);
            connection.setConnectTimeout(3_000);
            connection.setReadTimeout(readTimeout);
            connection.setUseCaches(false);
            connection.setRequestProperty("Authorization", "Bearer " + token);
            connection.setRequestProperty("X-DJOneHub-Trace-ID", traceID);
            if (body != null) {
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                try (OutputStream output = connection.getOutputStream()) {
                    output.write(body.getBytes(StandardCharsets.UTF_8));
                }
            }
            int status = connection.getResponseCode();
            String payload = "";
            if (status != 204) {
                InputStream stream = status >= 200 && status < 300 ? connection.getInputStream() : connection.getErrorStream();
                payload = read(stream);
            }
            BridgeLog.debug("http_request_finished method=" + method + " path=" + path + " status=" + status
                    + " duration_ms=" + elapsedMillis(started) + " response_bytes="
                    + payload.getBytes(StandardCharsets.UTF_8).length + " trace_id=" + traceID);
            return new ForwardResponse(status, payload);
        } catch (Exception error) {
            BridgeLog.error("http_request_failed method=" + method + " path=" + path
                    + " duration_ms=" + elapsedMillis(started) + " trace_id=" + traceID, error);
            throw error;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private static long elapsedMillis(long started) {
        return (System.nanoTime() - started) / 1_000_000L;
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
