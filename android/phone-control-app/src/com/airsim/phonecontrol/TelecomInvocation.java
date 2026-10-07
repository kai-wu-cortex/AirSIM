package com.airsim.phonecontrol;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

final class TelecomInvocation {
    private TelecomInvocation() {}

    static String run(Executor executor, Runnable action, long timeoutMillis) {
        CountDownLatch finished = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        try {
            executor.execute(() -> {
                try { action.run(); }
                catch (Throwable error) { failure.set(error); }
                finally { finished.countDown(); }
            });
        } catch (Throwable error) {
            return describe(error);
        }
        try {
            if (!finished.await(timeoutMillis, TimeUnit.MILLISECONDS)) {
                return "Telecom invocation timeout";
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return describe(error);
        }
        Throwable error = failure.get();
        return error == null ? "" : describe(error);
    }

    private static String describe(Throwable error) {
        String message = error.getMessage();
        return error.getClass().getSimpleName()
                + (message == null || message.isBlank() ? "" : ": " + message);
    }
}
