package com.airsim.phonecontrol;
public final class SMSInboxCatchUpTests {
    private static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); }
    public static void main(String[] args) {
        long now = 1_800_000_000_000L, recent = now - 60_000L, old = now - 86_400_000L;
        SMSInboxCatchUp first = new SMSInboxCatchUp(false, 0, now);
        SMSInboxCursor cursor = new SMSInboxCursor(10);
        check(!first.shouldForward(old, old), "old hidden rows must not notify");
        cursor.processed(11);
        check(cursor.value() == 11, "suppressed rows still advance cursor");
        check(first.shouldForward(recent, old), "newly received delayed carrier SMS must notify");
        check(first.shouldForward(0, recent), "sent time fallback");
        check(!first.shouldForward(0, 0), "unknown age cannot become a fresh OTP");
        check(first.shouldForward(first.cutoff(), 0), "inclusive cutoff");
        check(!first.shouldForward(first.cutoff() - 1, 0), "before cutoff");
        check(!first.drained(100, 100) && first.drained(99, 100) && first.drained(0, 100), "batch boundary");
        SMSInboxCatchUp resumed = new SMSInboxCatchUp(false, first.cutoff(), now + 86_400_000L);
        check(resumed.shouldForward(recent, recent), "cutoff survives restart and slow catch-up");
        SMSInboxCatchUp steady = new SMSInboxCatchUp(true, first.cutoff(), now + 86_400_000L);
        check(steady.shouldForward(old, old), "normal offline replay is preserved after catch-up");
        check(steady.completed(), "persisted completion");
        System.out.println("SMS inbox catch-up tests passed: window, cursor, restart, batch and steady-state");
    }
}
