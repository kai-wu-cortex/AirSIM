package com.airsim.phonecontrol;

import java.io.PrintWriter;
import java.io.StringWriter;
import java.time.Instant;

/** Builds a bounded, sanitized report suitable for explicit user sharing. */
public final class CrashReportFormatter {
    public static final int MAX_REPORT_CHARS = 48 * 1024;
    private static final String TRUNCATED = "\n[truncated]\n";

    private CrashReportFormatter() {}

    public static String format(
            String version, String packageName, String manufacturer, String model,
            int sdk, String threadName, Throwable error) {
        StringWriter stack = new StringWriter();
        if (error != null) error.printStackTrace(new PrintWriter(stack));
        String report = "AirSIM Android Crash Report\n"
                + "captured_at=" + Instant.now() + "\n"
                + "app_version=" + DebugRedactor.safeIdentifier(version) + "\n"
                + "package=" + DebugRedactor.safeIdentifier(packageName) + "\n"
                + "device=" + DebugRedactor.safeIdentifier(manufacturer) + " "
                + DebugRedactor.safeIdentifier(model) + "\n"
                + "android_sdk=" + sdk + "\n"
                + "thread=" + DebugRedactor.safeIdentifier(threadName) + "\n\n"
                + stack;
        String safe = DebugRedactor.sanitize(report);
        if (safe.length() <= MAX_REPORT_CHARS) return safe;
        return safe.substring(0, MAX_REPORT_CHARS - TRUNCATED.length()) + TRUNCATED;
    }
}
