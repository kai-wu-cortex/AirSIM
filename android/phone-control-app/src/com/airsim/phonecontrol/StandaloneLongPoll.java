package com.airsim.phonecontrol;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Revision cursor and bounded wait used by the embedded Agent event endpoints. */
final class StandaloneLongPoll {
    record Request(long after, int timeoutMillis) {}

    private long revision;
    private int waiters;

    static Request parse(String pathAndQuery, int defaultTimeoutMillis) {
        Map<String, String> query = new LinkedHashMap<>();
        int marker = pathAndQuery.indexOf('?');
        if (marker >= 0 && marker + 1 < pathAndQuery.length()) {
            for (String pair : pathAndQuery.substring(marker + 1).split("&")) {
                int equals = pair.indexOf('=');
                String name = equals < 0 ? pair : pair.substring(0, equals);
                String value = equals < 0 ? "" : pair.substring(equals + 1);
                query.putIfAbsent(decode(name), decode(value));
            }
        }
        long after;
        try {
            after = Long.parseUnsignedLong(query.getOrDefault("after", ""));
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException("after cursor is invalid", error);
        }
        int timeout = defaultTimeoutMillis;
        if (query.containsKey("timeout_ms")) {
            try {
                timeout = Integer.parseInt(query.get("timeout_ms"));
            } catch (NumberFormatException error) {
                throw new IllegalArgumentException("timeout_ms is invalid", error);
            }
        }
        if (timeout < 100 || timeout > 30_000) {
            throw new IllegalArgumentException("timeout_ms must be between 100 and 30000");
        }
        return new Request(after, timeout);
    }

    synchronized long revision() { return revision; }

    synchronized long advance() {
        revision++;
        notifyAll();
        return revision;
    }

    synchronized long awaitChange(long after, int timeoutMillis) throws InterruptedException {
        if (Long.compareUnsigned(after, revision) != 0) return revision;
        long remainingNanos = TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        long deadline = System.nanoTime() + remainingNanos;
        waiters++;
        try {
            while (Long.compareUnsigned(after, revision) == 0 && remainingNanos > 0) {
                long millis = TimeUnit.NANOSECONDS.toMillis(remainingNanos);
                int nanos = (int) (remainingNanos - TimeUnit.MILLISECONDS.toNanos(millis));
                wait(millis, nanos);
                remainingNanos = deadline - System.nanoTime();
            }
            return revision;
        } finally {
            waiters--;
        }
    }

    synchronized int waiterCount() { return waiters; }

    private static String decode(String value) {
        try {
            return URLDecoder.decode(value, StandardCharsets.UTF_8);
        } catch (IllegalArgumentException error) {
            throw new IllegalArgumentException("query encoding is invalid", error);
        }
    }
}
