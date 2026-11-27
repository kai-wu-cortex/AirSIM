package com.airsim.phonecontrol;

/** Only a live owner may renew. Read-only status requests never extend this deadline. */
final class IsolationLease {
    static final long DURATION_MILLIS = 20_000;
    private long expiresAt;
    void renew(long now) { expiresAt = now + DURATION_MILLIS; }
    void revoke() { expiresAt = 0; }
    boolean expired(long now) { return expiresAt == 0 || now >= expiresAt; }
}
