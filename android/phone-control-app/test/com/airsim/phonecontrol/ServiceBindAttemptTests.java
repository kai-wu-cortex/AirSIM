package com.airsim.phonecontrol;

public final class ServiceBindAttemptTests {
    public static void main(String[] args) {
        var bind = new ServiceBindAttempt();
        long first = bind.begin(1000);
        check(bind.begin(2000) == -1, "duplicate start");
        check(!bind.expire(first, 35999), "premature expiry");
        check(bind.expire(first, 36000), "missing callback must expire");
        check(!bind.connected(first), "late callback accepted after timeout");
        check(bind.begin(37000) == -1, "automatic retry storm after timeout");
        bind.cancel(); // Explicit retry or channel change.
        long second = bind.begin(40000);
        check(second != first && second > 0, "retry identity not renewed");
        check(!bind.expire(first, 100000), "old timer expired a new bind");
        check(!bind.connected(first), "old callback stole new connection");
        check(bind.connected(second), "current callback rejected");
        check(!bind.expire(second, 100000), "connected service marked timed out");
        long third = bind.begin(120000);
        bind.cancel();
        check(!bind.connected(third), "callback after Root handover accepted");
        check(!bind.expire(third, 160000), "cancelled timer overwrote Root status");
        System.out.println("ServiceBindAttemptTests passed: 12 assertions");
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
