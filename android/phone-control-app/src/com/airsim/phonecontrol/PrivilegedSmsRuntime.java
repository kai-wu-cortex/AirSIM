package com.airsim.phonecontrol;

import android.app.Application;
import android.content.Context;
import android.os.Build;
import android.os.Process;
import android.telephony.SmsManager;

/** Minimal SMS runtime for an authorized app_process, without starting the app's services. */
final class PrivilegedSmsRuntime {
    private PrivilegedSmsRuntime() {}

    static Context prepare(Context supplied) throws Exception {
        if (supplied == null) throw new IllegalStateException("no_context");
        if (Build.VERSION.SDK_INT >= 30) {
            Class<?> initializer = Class.forName("android.telephony.TelephonyFrameworkInitializer");
            synchronized (initializer) {
                if (initializer.getMethod("getTelephonyServiceManager").invoke(null) == null) {
                    Class<?> manager = Class.forName("android.os.TelephonyServiceManager");
                    initializer.getMethod("setTelephonyServiceManager", manager)
                            .invoke(null, manager.getConstructor().newInstance());
                }
            }
        }
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("currentActivityThread").invoke(null);
        if (thread == null) throw new IllegalStateException("no_activity_thread");
        Context context = supplied;
        if (Process.myUid() == 2000) {
            Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
            context = system.createPackageContext("com.android.shell", 0);
        }
        synchronized (thread) {
            if (activityThread.getMethod("getApplication").invoke(thread) == null) {
                // AppOps' default access reporter uses ActivityThread.currentOpPackageName().
                // A bare app_process has no Application, producing an empty package and an
                // OEM system-server NPE even AFTER a send may have been accepted. Supply a
                // real context for this process; do not disable AppOps or impersonate Messages.
                Application application = new Application();
                var attach = Application.class.getDeclaredMethod("attach", Context.class);
                attach.setAccessible(true);
                attach.invoke(application, context);
                var initial = activityThread.getDeclaredField("mInitialApplication");
                initial.setAccessible(true);
                initial.set(thread, application);
            }
        }
        Object attribution = activityThread.getMethod("currentOpPackageName").invoke(null);
        if (!(attribution instanceof String name) || name.isEmpty())
            throw new IllegalStateException("missing_appops_attribution");
        return context;
    }

    static SmsManager manager(Context supplied, int subscriptionId) throws Exception {
        Context context = prepare(supplied);
        if (Build.VERSION.SDK_INT >= 31) {
            SmsManager base = context.getSystemService(SmsManager.class);
            return base == null || subscriptionId < 0 ? base : base.createForSubscriptionId(subscriptionId);
        }
        return subscriptionId < 0 ? SmsManager.getDefault()
                : SmsManager.getSmsManagerForSubscriptionId(subscriptionId);
    }
}
