package com.airsim.phonecontrol;

import java.io.IOException;

/** Preserves the Relay response status so retry behavior does not depend on message text. */
final class RelayHTTPException extends IOException {
    private final int statusCode;
    private final long retryAfterMillis;
    private final String detail;

    RelayHTTPException(int statusCode, String detail) {
        this(statusCode, detail, 0);
    }
    RelayHTTPException(int statusCode, String detail, long retryAfterMillis) {
        super("Relay HTTP " + statusCode + (detail == null || detail.isBlank() ? "" : ": " + detail));
        this.statusCode = statusCode;
        this.retryAfterMillis = Math.max(0, retryAfterMillis);
        this.detail = detail == null ? "" : detail;
    }

    int statusCode() { return statusCode; }
    long retryAfterMillis() { return retryAfterMillis; }
    String detailBody() { return detail; }
    static long heartbeatRetryDelay(Exception error) {
        long requested = error instanceof RelayHTTPException
                ? ((RelayHTTPException) error).retryAfterMillis() : 0;
        return Math.max(30_000, Math.min(3_600_000, requested));
    }
    static long parseRetryAfter(String value, long wallTimeMillis) {
        if (value == null) return 0;
        try {
            if (value.matches("[0-9]+")) {
                long seconds = Long.parseLong(value);
                return seconds > Long.MAX_VALUE / 1000 ? Long.MAX_VALUE : seconds * 1000;
            }
            long date = java.time.ZonedDateTime.parse(value, java.time.format.DateTimeFormatter.RFC_1123_DATE_TIME)
                    .toInstant().toEpochMilli();
            return Math.max(0, Math.subtractExact(date, wallTimeMillis));
        } catch (RuntimeException ignored) { return 0; }
    }

    static RelayHTTPException fromHandshakeStatusLine(String line) throws IOException {
        if (line == null) throw new IOException("WebSocket 握手失败: empty");
        String[] parts = line.split(" ", 3);
        if (parts.length < 2 || !parts[0].startsWith("HTTP/")) {
            throw new IOException("WebSocket 握手响应无效: " + line);
        }
        try {
            return new RelayHTTPException(Integer.parseInt(parts[1]), "WebSocket 握手失败: " + line);
        } catch (NumberFormatException error) {
            throw new IOException("WebSocket 握手响应无效: " + line, error);
        }
    }
}
