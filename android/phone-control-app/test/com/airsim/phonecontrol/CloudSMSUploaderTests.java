package com.airsim.phonecontrol;

import java.io.IOException;
import java.net.SocketTimeoutException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class CloudSMSUploaderTests {
    private static void check(boolean ok, String detail) { if (!ok) throw new AssertionError(detail); }
    private static RelayHTTPException http(int status) { return new RelayHTTPException(status, ""); }
    private static CloudSMSUploader uploader() { return new CloudSMSUploader(() -> 0); }

    /** Replies with a scripted failure per delivery ID and records every send, settle and failure. */
    private static final class Fake {
        final Map<String, Exception> replies = new HashMap<>();
        final List<String> sent = new ArrayList<>();
        final List<String> settled = new ArrayList<>();
        final List<String> failures = new ArrayList<>();

        void flush(CloudSMSUploader uploader, long now, String... pending) throws Exception {
            flush(uploader, now, List.of(pending));
        }

        void flush(CloudSMSUploader uploader, long now, List<String> pending) throws Exception {
            clear();
            uploader.flush(pending, id -> {
                sent.add(id);
                Exception reply = replies.get(id);
                if (reply != null) throw reply;
            }, settled::add, (error, verdict, attempt, pause) -> failures.add(verdict + ":" + attempt + ":" + pause), now);
        }

        void clear() { sent.clear(); settled.clear(); failures.clear(); }
    }

    public static void main(String[] args) throws Exception {
        var u = uploader();
        var f = new Fake();
        f.replies.put("a", new RelayHTTPException(400, "{\"error\":\"invalid incoming SMS\"}"));
        f.flush(u, 0, "a", "b");
        check(f.sent.equals(List.of("a", "b")), "an invalid message does not hold the next one: " + f.sent);
        check(f.settled.equals(List.of("a", "b")), "rejected and delivered messages both leave the queue: " + f.settled);
        check(f.failures.equals(List.of("DROP:1:0")), "the rejection is reported as a drop: " + f.failures);

        u = uploader();
        f = new Fake();
        f.replies.put("a", http(502));
        f.flush(u, 0, "a", "b");
        check(f.sent.equals(List.of("a")), "a Relay failure ends the flush instead of trying every message: " + f.sent);
        check(f.failures.equals(List.of("RETRY:1:15000")), "5xx pauses the whole queue for 15 s: " + f.failures);
        f.flush(u, 14_999, "a", "b");
        check(f.sent.isEmpty(), "nothing is sent while the queue is paused");
        f.flush(u, 15_000, "a", "b");
        check(f.sent.equals(List.of("b", "a")), "after a pause a message that never failed goes first: " + f.sent);
        check(f.settled.equals(List.of("b")), "the good message is delivered: " + f.settled);
        check(f.failures.equals(List.of("RETRY:2:15000")), "success resets the pause before the next failure: " + f.failures);

        u = uploader();
        f = new Fake();
        f.replies.put("a", new SocketTimeoutException("connect timed out"));
        f.flush(u, 0, "a", "b");
        check(f.sent.equals(List.of("a")) && f.settled.isEmpty(), "an unreachable Relay is tried once: " + f.sent);
        check(f.failures.equals(List.of("STOP:1:3000")), "a failure without an answer is a 3 s pause: " + f.failures);

        long day = 24L * 60 * 60 * 1000;
        u = uploader();
        f = new Fake();
        f.replies.put("a", new IOException("network unreachable"));
        f.flush(u, 1_000, "a");
        f.flush(u, 1_000 + day + 3_600_000, "a");
        check(f.sent.equals(List.of("a")) && f.settled.isEmpty(), "a long outage never drops a message: " + f.settled);
        check(f.failures.equals(List.of("STOP:2:6000")), "the pause keeps growing: " + f.failures);

        for (int status : new int[]{400, 401, 403, 404, 408, 409, 413, 429, 500, 502, 503}) {
            u = uploader();
            f = new Fake();
            f.replies.put("a", http(status));
            f.flush(u, 0, "a");
            check(f.failures.size() == 1 && f.failures.get(0).startsWith("RETRY:1:") && f.settled.isEmpty(),
                    status + " without a recognized rejection body is retried: " + f.failures);
        }

        u = uploader();
        f = new Fake();
        f.replies.put("a", new RelayHTTPException(429, "", 60_000));
        f.flush(u, 0, "a");
        check(f.failures.equals(List.of("RETRY:1:60000")), "Retry-After sets the pause: " + f.failures);
        f.flush(u, 59_999, "a");
        check(f.sent.isEmpty(), "Retry-After is honoured");
        f.flush(u, 60_000, "a");
        check(f.sent.equals(List.of("a")), "retried once Retry-After has passed");

        u = uploader();
        f = new Fake();
        f.replies.put("a", http(502));
        f.flush(u, 0, "a", "b");
        f.flush(u, 15_000, "a", "b");
        f.flush(u, 30_000, "a", "c");
        check(f.sent.equals(List.of("c", "a")), "a is due again after 10 s of its own backoff: " + f.sent);
        f.flush(u, 45_000, "a", "d");
        check(f.sent.equals(List.of("d")), "while other messages flow, a waits for its own 20 s backoff: " + f.sent);

        u = uploader();
        f = new Fake();
        List<String> queue = new ArrayList<>();
        for (int i = 0; i < 25; i++) queue.add("m" + i);
        f.flush(u, 0, queue);
        check(f.sent.size() == 10 && f.settled.size() == 10, "at most 10 sends per flush: " + f.sent.size());
        queue.removeAll(f.settled);
        f.flush(u, 1, queue);
        queue.removeAll(f.settled);
        f.flush(u, 2, queue);
        check(f.settled.size() == 5 && queue.size() == 5, "the backlog drains over later flushes");

        u = uploader();
        f = new Fake();
        f.replies.put("a", http(502));
        f.flush(u, 0, "a");
        f.replies.remove("a");
        f.flush(u, 15_000, "a");
        check(f.settled.equals(List.of("a")) && f.failures.isEmpty(), "delivered on a later attempt: " + f.settled);
        f.replies.put("a", http(502));
        f.flush(u, 15_001, "a");
        check(f.failures.equals(List.of("RETRY:1:15000")), "success clears the message state and the pause: " + f.failures);

        u = uploader();
        f = new Fake();
        f.replies.put("a", http(502));
        f.flush(u, 0, "a");
        f.flush(u, 15_000, "b");
        f.flush(u, 15_001, "a");
        check(f.sent.equals(List.of("a")) && f.failures.equals(List.of("RETRY:1:15000")),
                "state of a message that left the queue is forgotten: " + f.failures);

        boolean threw = false;
        try {
            uploader().flush(List.of("a"), id -> {}, id -> { throw new IllegalStateException("disk full"); },
                    (error, verdict, attempt, pause) -> {}, 0);
        } catch (IllegalStateException expected) {
            threw = true;
        }
        check(threw, "a failing ledger is not mistaken for a Relay failure");

        long now = Instant.parse("2026-10-29T10:00:00Z").toEpochMilli();
        check(CloudSMSUploader.uploadTimestamp("2026-10-29T09:59:00Z", now).equals("2026-10-29T09:59:00Z"),
                "a past carrier time is kept");
        check(CloudSMSUploader.uploadTimestamp("2026-10-29T10:10:00Z", now).equals("2026-10-29T10:00:00Z"),
                "a carrier clock running fast is clamped to now, so the Relay does not answer 400");
        check(CloudSMSUploader.uploadTimestamp("", now).equals("2026-10-29T10:00:00Z"), "a missing time becomes now");
        check(CloudSMSUploader.uploadTimestamp("yesterday", now).equals("2026-10-29T10:00:00Z"), "an unreadable time becomes now");
        slowRequestsAndCancellation();
        System.out.println("CloudSMSUploaderTests passed");
    }

    private static void slowRequestsAndCancellation() throws Exception {
        long[] clock = {0};
        var u = uploader();
        List<String> sent = new ArrayList<>();
        List<String> settled = new ArrayList<>();
        CloudSMSUploader.Listener quiet = (error, verdict, attempt, pause) -> {};
        u.flush(List.of("a"), id -> {
            clock[0] = 12_000;
            throw new RelayHTTPException(429, "", 60_000);
        }, settled::add, quiet, () -> clock[0], () -> true);
        clock[0] = 60_000;
        u.flush(List.of("a", "b"), sent::add, settled::add, quiet, () -> clock[0], () -> true);
        check(sent.isEmpty(), "slow request must not consume Retry-After");
        clock[0] = 72_000;
        u.flush(List.of("a", "b"), sent::add, settled::add, quiet, () -> clock[0], () -> true);
        check(sent.equals(List.of("b", "a")), "full cooldown starts at failure time");

        var lifetime = new RelayCommandRetryState();
        long epoch = lifetime.configure("first");
        boolean[] cancelled = {false};
        lifetime.attach(epoch, () -> cancelled[0] = true);
        settled.clear();
        sent.clear();
        uploader().flush(List.of("a", "b"), id -> {
            sent.add(id);
            lifetime.configure(null); // Pure local/cloud off.
            lifetime.configure("first"); // Rapidly re-enable: old batch stays stale.
        }, settled::add, quiet, () -> clock[0], () -> lifetime.isCurrent(epoch));
        check(cancelled[0], "turning cloud off cancels the active request");
        check(settled.isEmpty() && sent.equals(List.of("a")), "stale success neither settles nor sends next SMS");
        check(!lifetime.attach(epoch, () -> {}), "stale epoch cannot attach a new connection");
        check(!CloudSMSUploader.rejected(new RelayHTTPException(400, "<html>Bad Request</html>")),
                "proxy 400 must not discard SMS");
        List<String> rejected = new ArrayList<>();
        uploader().flush(List.of("invalid"), id -> {
            throw new RelayHTTPException(400, "{\"error\":\"invalid incoming SMS\"}");
        }, new CloudSMSUploader.Ledger() {
            public void settled(String id) { throw new AssertionError("rejected SMS is not delivered"); }
            public void rejected(String id) { rejected.add(id); }
        }, quiet, () -> clock[0], () -> true);
        check(rejected.equals(List.of("invalid")), "rejection has a distinct durable outcome");
    }
}
