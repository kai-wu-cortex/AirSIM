package com.airsim.phonecontrol;

import android.content.Context;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Instant;

public final class BridgeLog {
    private static final String TAG = "DJOneHubBridge";
    private static final String FILE_NAME = "djonehub-debug.log";
    private static final String PREVIOUS_FILE_NAME = "djonehub-debug.previous.log";
    private static final long MAX_FILE_BYTES = 512L * 1024L;
    private static final Object LOCK = new Object();
    private static volatile Context applicationContext;

    private BridgeLog() {}

    public static void initialize(Context context) {
        if (context != null) applicationContext = context.getApplicationContext();
    }

    public static boolean isDebugEnabled() {
        Context context = applicationContext;
        return context != null && AppConfig.debugEnabled(context);
    }

    public static void setDebugEnabled(Context context, boolean enabled) {
        initialize(context);
        AppConfig.setDebugEnabled(applicationContext, enabled);
        if (enabled) append("INFO", "debug_logging_enabled");
        else Log.i(TAG, "debug_logging_disabled");
    }

    public static void debug(String message) {
        String safe = DebugRedactor.sanitize(message);
        if (isDebugEnabled()) {
            Log.d(TAG, safe);
            append("DEBUG", safe);
        }
    }

    public static void info(String message) {
        String safe = DebugRedactor.sanitize(message);
        Log.i(TAG, safe);
        if (isDebugEnabled()) append("INFO", safe);
    }

    public static void error(String message, Throwable error) {
        String detail = message + " error=" + error.getClass().getSimpleName();
        if (error.getMessage() != null && !error.getMessage().isBlank()) detail += " detail=" + error.getMessage();
        String safe = DebugRedactor.sanitize(detail);
        Log.e(TAG, safe);
        if (isDebugEnabled()) append("ERROR", safe);
    }

    public static String read() {
        Context context = applicationContext;
        if (context == null) return "日志尚未初始化";
        synchronized (LOCK) {
            String previous = readFile(new File(context.getFilesDir(), PREVIOUS_FILE_NAME));
            String current = readFile(new File(context.getFilesDir(), FILE_NAME));
            String value = previous + current;
            return value.isEmpty() ? "暂无 Debug 日志" : value;
        }
    }

    public static void clear() {
        Context context = applicationContext;
        if (context == null) return;
        synchronized (LOCK) {
            delete(new File(context.getFilesDir(), PREVIOUS_FILE_NAME));
            delete(new File(context.getFilesDir(), FILE_NAME));
        }
        info("debug_log_cleared");
    }

    private static void append(String level, String message) {
        Context context = applicationContext;
        if (context == null) return;
        synchronized (LOCK) {
            try {
                File current = new File(context.getFilesDir(), FILE_NAME);
                if (current.length() >= MAX_FILE_BYTES) {
                    File previous = new File(context.getFilesDir(), PREVIOUS_FILE_NAME);
                    delete(previous);
                    if (!current.renameTo(previous)) delete(current);
                }
                String line = Instant.now() + " " + level + " [" + Thread.currentThread().getName() + "] "
                        + DebugRedactor.sanitize(message).replace('\n', ' ') + "\n";
                try (FileOutputStream output = new FileOutputStream(current, true)) {
                    output.write(line.getBytes(StandardCharsets.UTF_8));
                }
            } catch (Exception error) {
                Log.e(TAG, "debug_log_write_failed error=" + error.getClass().getSimpleName());
            }
        }
    }

    private static String readFile(File file) {
        if (!file.isFile()) return "";
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            return output.toString(StandardCharsets.UTF_8);
        } catch (Exception error) {
            return "[日志读取失败: " + error.getClass().getSimpleName() + "]\n";
        }
    }

    private static void delete(File file) {
        if (file.exists() && !file.delete()) Log.w(TAG, "debug_log_delete_failed");
    }
}
