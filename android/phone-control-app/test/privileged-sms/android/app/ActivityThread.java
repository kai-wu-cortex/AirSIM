package android.app;

import android.content.Context;

public final class ActivityThread {
    private static final ActivityThread THREAD = new ActivityThread();
    public Application mInitialApplication;
    public Application getApplication() { return mInitialApplication; }
    public static String currentOpPackageName() {
        return THREAD.mInitialApplication == null ? null : THREAD.mInitialApplication.getOpPackageName();
    }
    public static ActivityThread currentActivityThread() { return THREAD; }
    public Context getSystemContext() { return new Context("android"); }
}
