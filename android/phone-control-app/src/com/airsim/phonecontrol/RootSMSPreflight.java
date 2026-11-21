package com.airsim.phonecontrol;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

/** Runs only `id -u`, never a carrier command. Failure is safe to fall back from. */
final class RootSMSPreflight {
    interface Launch { Process start() throws IOException; }
    static String check(Launch launch, long timeoutMillis) {
        Process process = null;
        try {
            process = launch.start();
            if (!process.waitFor(timeoutMillis, TimeUnit.MILLISECONDS)) return "unavailable";
            if (process.exitValue() != 0) return "unavailable";
            byte[] bytes = new byte[128];
            int size = 0;
            try (var input = process.getInputStream()) {
                int count;
                while (size < bytes.length && (count = input.read(bytes, size, bytes.length - size)) > 0)
                    size += count;
            }
            String uid = new String(bytes, 0, size, StandardCharsets.UTF_8).trim();
            return "0".equals(uid) ? "ready" : "unavailable";
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return "error:interrupted"; // Cancellation must not start another sender.
        } catch (IOException | RuntimeException error) {
            return "unavailable";
        } finally {
            if (process != null && process.isAlive()) process.destroyForcibly();
        }
    }
    static String launchFailure(boolean started, Exception error) {
        return "error:" + (started ? "send_unknown:" : "prepare:") + error.getClass().getSimpleName();
    }
}
