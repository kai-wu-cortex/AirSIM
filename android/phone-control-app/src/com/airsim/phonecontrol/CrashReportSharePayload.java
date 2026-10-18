package com.airsim.phonecontrol;

/** Produces a Binder-safe text payload only when an actual crash report exists. */
public final class CrashReportSharePayload {
    public static final int MAX_SHARE_CHARS = 64 * 1024;
    private static final int MAX_DEBUG_CHARS = 12 * 1024;

    private CrashReportSharePayload() {}

    public static String compose(String crashReport, String debugLog) {
        if (crashReport == null || crashReport.isBlank()) return "";
        String recent = debugLog == null ? "" : debugLog;
        if (recent.length() > MAX_DEBUG_CHARS) {
            recent = recent.substring(recent.length() - MAX_DEBUG_CHARS);
        }
        String payload = crashReport;
        if (!recent.isBlank()) payload += "\n\n--- Recent sanitized debug log ---\n" + recent;
        payload = DebugRedactor.sanitize(payload);
        return payload.length() <= MAX_SHARE_CHARS
                ? payload : payload.substring(0, MAX_SHARE_CHARS);
    }
}
