package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Build;
import android.os.Process;
import android.util.Log;

import java.util.concurrent.atomic.AtomicBoolean;

/** Installs a last-chance handler that saves one private, sanitized crash report. */
public final class CrashReporter {
    private static final String TAG = "AirSIMCrash";
    private static boolean installed;

    private CrashReporter() {}

    public static synchronized void install(Context context) {
        if (installed || context == null) return;
        Context app = context.getApplicationContext();
        Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler(new Handler(app, previous));
        installed = true;
    }

    private static final class Handler implements Thread.UncaughtExceptionHandler {
        private final Context context;
        private final Thread.UncaughtExceptionHandler previous;
        private final AtomicBoolean handling = new AtomicBoolean();

        Handler(Context context, Thread.UncaughtExceptionHandler previous) {
            this.context = context;
            this.previous = previous;
        }

        @Override public void uncaughtException(Thread thread, Throwable error) {
            if (handling.compareAndSet(false, true)) {
                try {
                    CrashReportStore.write(context.getFilesDir(), CrashReportFormatter.format(
                            AppInformation.version(context), context.getPackageName(),
                            Build.MANUFACTURER, Build.MODEL, Build.VERSION.SDK_INT,
                            thread == null ? "unknown" : thread.getName(), error));
                } catch (Throwable reportError) {
                    Log.e(TAG, "crash_report_write_failed error="
                            + reportError.getClass().getSimpleName());
                }
            }
            if (previous != null) {
                previous.uncaughtException(thread, error);
            } else {
                Process.killProcess(Process.myPid());
                System.exit(10);
            }
        }
    }

}
