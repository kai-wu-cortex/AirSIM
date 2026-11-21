package com.airsim.phonecontrol;
import android.app.PendingIntent;
import android.content.Context;
import android.os.Build;
import android.os.SystemClock;
import android.telephony.SmsManager;

public class PrivilegedSmsConfirmationTests {
    static Context reset(int segments) {
        PendingIntent.created.clear(); SmsManager.segments = segments; SystemClock.now = 0;
        return new Context();
    }
    static void check(String expected, Context context, PrivilegedSmsConfirmation.Dispatch dispatch) {
        String actual = PrivilegedSmsConfirmation.send(context, "fixture", "fixture", 7, dispatch);
        if (!expected.equals(actual)) throw new AssertionError(expected + " != " + actual);
        if (context.receiver != null) throw new AssertionError("leaked receiver");
        for (var callback : PendingIntent.created) if (!callback.cancelled) throw new AssertionError("leaked callback");
    }
    public static void main(String[] args) throws Exception {
        for (int api : new int[]{29, 33, 36}) {
            Build.VERSION.SDK_INT = api;
            check("ok:1", reset(1), callbacks -> { callbacks.get(0).deliver(-1); return "ok:1"; });
            // A privileged API may throw AFTER dispatch; a later system receipt wins.
            final Thread[] late = new Thread[1];
            check("ok:1", reset(1), callbacks -> {
                late[0] = new Thread(() -> { try { Thread.sleep(10); } catch (InterruptedException e) { throw new AssertionError(e); }
                    callbacks.get(0).deliver(-1); });
                late[0].start(); throw new NullPointerException("OEM post-dispatch fixture");
            });
            late[0].join();
            check("ok:2", reset(2), callbacks -> {
                callbacks.get(1).deliver(-1); callbacks.get(1).deliver(-1); callbacks.get(0).deliver(-1); return "error:no_result";
            });
            check("error:sent:4", reset(2), callbacks -> { callbacks.get(0).deliver(4); return "ok:2"; });
            // Helper startup consumes the same budget. API acceptance alone cannot succeed.
            check("error:send_unknown:callback_timeout", reset(1), callbacks -> { SystemClock.now += 45_001; return "ok:1"; });
            check("error:send_unknown:callback_timeout", reset(2), callbacks -> {
                callbacks.get(0).deliver(-1); callbacks.get(0).deliver(-1); SystemClock.now += 45_001; return "ok:2";
            });
            check("error:prepare:missing_callbacks", reset(1), callbacks -> "error:prepare:missing_callbacks");
            check("error:send_unknown:interrupted", reset(1), callbacks -> {
                Thread.currentThread().interrupt(); return "error:no_result";
            });
            if (!Thread.interrupted()) throw new AssertionError("interruption lost");
            Context denied = reset(1); denied.rejectRegistration = true;
            check("error:prepare:SecurityException", denied, callbacks -> { throw new AssertionError("dispatched without receiver"); });
        }
        System.out.println("PrivilegedSmsConfirmationTests passed: API29/33/36 receipts, late success, multipart, unknown, cancellation, cleanup");
    }
}
