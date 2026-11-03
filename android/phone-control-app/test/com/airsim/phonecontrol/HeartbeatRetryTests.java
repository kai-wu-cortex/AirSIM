package com.airsim.phonecontrol;

public final class HeartbeatRetryTests {
    public static void main(String[] args) {
        assert RelayHTTPException.heartbeatRetryDelay(new Exception()) == 30_000;
        assert RelayHTTPException.heartbeatRetryDelay(new RelayHTTPException(503, "", 300_000)) == 300_000;
        assert RelayHTTPException.heartbeatRetryDelay(new RelayHTTPException(500, "", 0)) == 30_000;
        assert RelayHTTPException.heartbeatRetryDelay(new RelayHTTPException(503, "", Long.MAX_VALUE)) == 3_600_000;
        assert RelayHTTPException.parseRetryAfter("300", 0) == 300_000;
        System.out.println("HeartbeatRetryTests passed");
    }
}
