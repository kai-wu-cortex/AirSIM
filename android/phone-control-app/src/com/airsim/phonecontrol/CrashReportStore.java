package com.airsim.phonecontrol;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/** Persists only the most recent crash report in the app-private files directory. */
public final class CrashReportStore {
    private static final String FILE_NAME = "airsim-last-crash.txt";
    private static final String TEMP_FILE_NAME = "airsim-last-crash.tmp";

    private CrashReportStore() {}

    public static void write(File directory, String report) throws Exception {
        if (directory == null) throw new IllegalArgumentException("directory required");
        if (!directory.isDirectory() && !directory.mkdirs()) {
            throw new IllegalStateException("crash report directory unavailable");
        }
        String safe = DebugRedactor.sanitize(report);
        if (safe.length() > CrashReportFormatter.MAX_REPORT_CHARS) {
            safe = safe.substring(0, CrashReportFormatter.MAX_REPORT_CHARS);
        }
        File temporary = new File(directory, TEMP_FILE_NAME);
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(safe.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        File destination = new File(directory, FILE_NAME);
        try {
            Files.move(temporary.toPath(), destination.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (Exception ignored) {
            Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }
    }

    public static boolean hasReport(File directory) {
        return directory != null && new File(directory, FILE_NAME).isFile();
    }

    public static String read(File directory) {
        if (!hasReport(directory)) return "";
        File file = new File(directory, FILE_NAME);
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int remaining = CrashReportFormatter.MAX_REPORT_CHARS * 4;
            int count;
            while (remaining > 0
                    && (count = input.read(buffer, 0, Math.min(buffer.length, remaining))) >= 0) {
                output.write(buffer, 0, count);
                remaining -= count;
            }
            return DebugRedactor.sanitize(new String(output.toByteArray(), StandardCharsets.UTF_8));
        } catch (Exception ignored) {
            return "";
        }
    }

    public static void clear(File directory) {
        if (directory == null) return;
        File report = new File(directory, FILE_NAME);
        if (report.exists()) report.delete();
        File temporary = new File(directory, TEMP_FILE_NAME);
        if (temporary.exists()) temporary.delete();
    }
}
