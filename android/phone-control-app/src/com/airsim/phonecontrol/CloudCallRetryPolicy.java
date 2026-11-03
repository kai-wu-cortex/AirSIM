package com.airsim.phonecontrol;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Bounds how long a cloud call event or media session keeps retrying the Relay. A 4xx other than
 * 401/408/429 is final at once (call ended or expired, illegal lifecycle transition).
 * Media 401 gets a bounded propagation window. Other failures may clear up, but one event must
 * not hold the in-memory FIFO, and the "ended" queued behind it, for more than a minute.
 */
final class CloudCallRetryPolicy {
    static final long GIVE_UP_AFTER_MILLIS = 60_000L;
    private static final Pattern REASON = Pattern.compile("\"reason\"\\s*:\\s*\"([^\"]*)\"");
    private static final Pattern ERROR = Pattern.compile("\"error\"\\s*:\\s*\"([^\"]*)\"");
    private String head;
    private long firstFailureAt;

    /** True when {@code event}, which just failed with {@code error}, must leave the queue now. */
    synchronized boolean shouldDrop(String event, Throwable error, long nowMillis) {
        if (!event.equals(head)) { head = event; firstFailureAt = nowMillis; }
        if (!eventRejected(error) && nowMillis - firstFailureAt < GIVE_UP_AFTER_MILLIS) return false;
        head = null;
        return true;
    }

    /** The Relay refused this call event and will refuse it again; 401 is left to re-registration. */
    static boolean eventRejected(Throwable error) {
        return error instanceof RelayHTTPException http && http.statusCode() != 401 && finalStatus(http.statusCode());
    }

    /** 401 is ambiguous with KV propagation; only other permanent rejections stop immediately. */
    static boolean mediaRejected(Throwable error) {
        return error instanceof RelayHTTPException http && http.statusCode() != 401 && finalStatus(http.statusCode());
    }

    enum MediaOutcome { RECONNECT, STOP, STOP_AND_RELEASE }

    /** One per media session, never shared with another call or the event FIFO. */
    static final class MediaRetry {
        private long unauthorizedSince = -1;

        void authenticated() { unauthorizedSince = -1; }

        MediaOutcome outcome(Throwable error, int telecomState, long nowMillis) {
            if (error instanceof RelayHTTPException http && http.statusCode() == 401
                    && unauthorizedSince < 0) unauthorizedSince = nowMillis;
            // Changing errors must not grant another window; only successful authentication can.
            boolean exhausted = unauthorizedSince >= 0 && nowMillis - unauthorizedSince >= GIVE_UP_AFTER_MILLIS;
            if (!mediaRejected(error) && !exhausted) return MediaOutcome.RECONNECT;
            // Keep a live call's slot to prevent queued rings creating duplicate VoIP pushes.
            return telecomState < 0 ? MediaOutcome.STOP_AND_RELEASE : MediaOutcome.STOP;
        }
    }

    /** Log-safe: exception type, HTTP status and the Relay's short reason, never the body itself. */
    static String describe(Throwable error) {
        if (error == null) return "type=unknown";
        String result = "type=" + error.getClass().getSimpleName();
        if (!(error instanceof RelayHTTPException http)) return result;
        result += " status=" + http.statusCode();
        String reason = reason(http.detailBody());
        return reason.isEmpty() ? result : result + " reason=" + reason;
    }

    private static boolean finalStatus(int status) {
        return status >= 400 && status < 500 && status != 408 && status != 429;
    }

    private static String reason(String body) {
        Matcher match = REASON.matcher(body);
        if (!match.find()) {
            match = ERROR.matcher(body);
            if (!match.find()) return "";
        }
        // Letters only: whatever the Relay echoes, digits (numbers, ids) never reach the log.
        String value = match.group(1).toLowerCase(Locale.ROOT).replaceAll("[^a-z]+", "_").replaceAll("^_+|_+$", "");
        return value.length() > 40 ? value.substring(0, 40) : value;
    }
}
