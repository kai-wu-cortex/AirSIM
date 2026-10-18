package android.os;

/** Deterministic main-loop boundary for stale posted-callback lifecycle coverage. */
public final class Handler {
    public static boolean deferForTest;
    private static final java.util.Queue<Runnable> pending = new java.util.ArrayDeque<>();
    public Handler(Looper looper) {}
    public boolean post(Runnable action) {
        if (deferForTest) pending.add(action);
        else action.run();
        return true;
    }
    public static void runPendingForTest() {
        while (!pending.isEmpty()) pending.remove().run();
    }
}
