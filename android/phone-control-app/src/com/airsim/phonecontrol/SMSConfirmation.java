package com.airsim.phonecontrol;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Tracks one sent callback per SMS segment; duplicate broadcasts never confirm another part. */
final class SMSConfirmation {
    record Outcome(boolean complete, boolean success, int errorCode) {}

    private final boolean[] received;
    private final CountDownLatch pending;
    private int firstErrorCode;

    SMSConfirmation(int segments) {
        if (segments <= 0) throw new IllegalArgumentException("SMS has no segments");
        received = new boolean[segments];
        pending = new CountDownLatch(segments);
    }

    synchronized void record(int index, int resultCode) {
        if (index < 0 || index >= received.length || received[index]) return;
        received[index] = true;
        if (resultCode != -1 && firstErrorCode == 0) firstErrorCode = resultCode;
        pending.countDown();
    }

    Outcome await(long timeoutMillis) throws InterruptedException {
        boolean complete = pending.await(timeoutMillis, TimeUnit.MILLISECONDS);
        synchronized (this) {
            return new Outcome(complete, complete && firstErrorCode == 0, firstErrorCode);
        }
    }
}
