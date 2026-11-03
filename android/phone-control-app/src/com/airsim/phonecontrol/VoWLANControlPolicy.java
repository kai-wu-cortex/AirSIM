package com.airsim.phonecontrol;

import java.util.Set;

public final class VoWLANControlPolicy {
    private static final Set<String> GET_ROUTES = Set.of(
            "/v1/health", "/api/health", "/api/status", "/api/debug", "/api/events",
            "/api/calls/status", "/api/calls/events", "/api/calls/audio/host/config",
            "/api/push/status", "/api/sms", "/api/sms/status", "/api/feedback", "/api/local-mode");
    private static final Set<String> POST_ROUTES = Set.of(
            "/api/calls/dial", "/api/calls/answer", "/api/calls/reject",
            "/api/calls/hangup", "/api/calls/dtmf", "/api/calls/audio/mute",
            "/api/calls/audio/host/warmup", "/api/calls/audio/host/register", "/api/push/register", "/api/push/mode",
			"/api/sms/send", "/api/sms/ack", "/api/sms/refresh", "/api/local-mode");

    private VoWLANControlPolicy() {}

    public static boolean allowed(String method, String pathAndQuery) {
        if (method == null || pathAndQuery == null) return false;
        int query = pathAndQuery.indexOf('?');
        String path = query < 0 ? pathAndQuery : pathAndQuery.substring(0, query);
        if ("GET".equalsIgnoreCase(method)) return GET_ROUTES.contains(path);
        if ("POST".equalsIgnoreCase(method)) return POST_ROUTES.contains(path);
        return false;
    }

    static boolean ownsCallAfterResponse(String path, int status, boolean currentlyOwnsCall) {
        if (status < 200 || status >= 300) return currentlyOwnsCall;
        if ("/api/calls/dial".equals(path) || "/api/calls/answer".equals(path)) return true;
        if ("/api/calls/hangup".equals(path) || "/api/calls/reject".equals(path)) return false;
        return currentlyOwnsCall;
    }
}
