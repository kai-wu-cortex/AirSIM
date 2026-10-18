package com.airsim.phonecontrol;

import android.content.Context;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;

/** Runs the real BridgeLog/CrashReportStore, not the JVM suite's BridgeLog double. */
public final class DiagnosticFileTests {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("airsim-diagnostic-file-test");
        try {
            Context context = new Context() {
                @Override public File getFilesDir() { return directory.toFile(); }
            };
            BridgeLog.initialize(context);
            equal("暂无 Debug 日志", BridgeLog.read());
            Files.write(directory.resolve("airsim-debug.previous.log"),
                    "旧日志：蓝牙\n".getBytes(StandardCharsets.UTF_8));
            Files.write(directory.resolve("airsim-debug.log"),
                    "新日志：已连接\n".getBytes(StandardCharsets.UTF_8));
            equal("旧日志：蓝牙\n新日志：已连接\n", BridgeLog.read());
            CrashReportStore.write(directory.toFile(), "异常：测试\n");
            equal("异常：测试\n", CrashReportStore.read(directory.toFile()));
            BridgeLog.watchdog("audio_watchdog muted=false verified_muted=unknown acoustic_check=unavailable");
            String watchdog = BridgeLog.read();
            if (!watchdog.contains("VERBOSE") || !watchdog.contains("verified_muted=unknown")) {
                throw new AssertionError("Watchdog evidence must be written even when general Debug is off");
            }
            BridgeLog.clear();
            equal("暂无 Debug 日志", BridgeLog.read());
            equal("异常：测试\n", CrashReportStore.read(directory.toFile()));
        } finally {
            try (var paths = Files.walk(directory)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
        System.out.println("Diagnostic UTF-8 file tests passed");
    }

    private static void equal(String expected, String actual) {
        if (!expected.equals(actual)) throw new AssertionError("expected=" + expected + " actual=" + actual);
    }
}
