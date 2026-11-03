package com.airsim.phonecontrol;

public final class RelayRegistrationRecoveryTests {
    private static void check(boolean ok, String detail) { if (!ok) throw new AssertionError(detail); }

    public static void main(String[] args) {
        var r = new RelayRegistrationRecovery();
        check(!r.takeResync(0), "nothing pending initially");
        r.onFailure(new RelayHTTPException(500, ""), 0);
        r.onFailure(new RelayHTTPException(429, ""), 0);
        r.onFailure(new RelayHTTPException(403, ""), 0);
        r.onFailure(new RelayHTTPException(404, ""), 0);
        r.onFailure(new java.io.IOException("offline"), 0);
        r.onFailure(null, 0);
        check(!r.takeResync(0), "only 401 schedules a resync");
        r.onFailure(new RelayHTTPException(401, "{\"error\":\"unauthorized\"}"), 0);
        check(r.takeResync(0), "first 401 resyncs immediately");
        check(!r.takeResync(0), "resync is one-shot");
        long t = 0;
        for (long w : new long[]{60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000, 3_600_000, 3_600_000}) {
            r.onFailure(new RelayHTTPException(401, ""), t + w - 1);
            check(!r.takeResync(t + w - 1), "401 inside window is dropped: " + w);
            check(!r.takeResync(t + w), "401 inside window is not queued: " + w);
            t += w;
            r.onFailure(new RelayHTTPException(401, ""), t);
            check(r.takeResync(t), "401 after window resyncs: " + w);
        }
        r.onAuthenticated();
        r.onFailure(new RelayHTTPException(401, ""), t + 1);
        check(r.takeResync(t + 1), "authentication resets backoff");
        check(r.describe(t + 1).contains("resyncs=10"), "describe reports the resync count");
        r.onFailure(new RelayHTTPException(401, ""), t + 1 + 59_999);
        check(!r.takeResync(t + 1 + 59_999), "reset restores the 60 s first window, not the capped one");
        r.onFailure(new RelayHTTPException(401, ""), t + 1 + 60_000);
        check(r.takeResync(t + 1 + 60_000), "first window after reset opens at 60 s");

        // Relay authenticates heartbeats and other endpoints along different paths: heartbeats can
        // succeed while command polls, completions, SMS posts or the command socket stay 401.
        var d = new RelayRegistrationRecovery();
        d.onFailure(new RelayHTTPException(401, ""), 0);
        check(d.takeResync(0), "first 401 resyncs");
        d.onFailure(new RelayHTTPException(401, ""), 1_000);
        d.onAuthenticated();
        d.onFailure(new RelayHTTPException(401, ""), 2_000);
        check(!d.takeResync(2_000), "heartbeat success does not reset back-off while other channels stay 401");
        d.onFailure(new RelayHTTPException(401, ""), 60_000);
        check(d.takeResync(60_000), "back-off window still opens on schedule");
        d.onFailure(new RelayHTTPException(401, ""), 61_000);
        d.onAuthenticated();
        d.onFailure(new RelayHTTPException(401, ""), 179_999);
        check(!d.takeResync(179_999), "window keeps growing to 120 s despite heartbeat success");
        d.onFailure(new RelayHTTPException(401, ""), 180_000);
        check(d.takeResync(180_000), "second window opens after 120 s");
        System.out.println("RelayRegistrationRecoveryTests passed");
    }
}
