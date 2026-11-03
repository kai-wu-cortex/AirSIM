package android.app;

import android.content.Context;

public final class ActivityThread {
    private static final ActivityThread THREAD = new ActivityThread();
    public static ActivityThread currentActivityThread() { return THREAD; }
    public Context getSystemContext() { return new Context("android"); }
}
