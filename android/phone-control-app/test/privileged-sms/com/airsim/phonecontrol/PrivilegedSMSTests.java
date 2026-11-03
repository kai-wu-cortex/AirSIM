package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Binder;
import android.os.Build;
import android.os.Process;
import android.os.TelephonyServiceManager;
import android.telephony.SmsManager;
import android.telephony.TelephonyFrameworkInitializer;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

public final class PrivilegedSMSTests {
    private static int cases;
    private static final Method SEND;
    private static final Field CONTEXT;
    static {
        try {
            SEND = ShizukuBridgeUserService.class.getDeclaredMethod("sendSms", String.class, String.class, int.class);
            SEND.setAccessible(true);
            CONTEXT = ShizukuBridgeUserService.class.getDeclaredField("serviceContext");
            CONTEXT.setAccessible(true);
        } catch (Exception error) { throw new ExceptionInInitializerError(error); }
    }
    public static void main(String[] args) throws Exception {
        for (int api : new int[]{29, 30, 31, 36}) {
            reset(api);
            equal("ok:1", send("test", 7), "API " + api + " accepts selected SIM");
            equal(7, SmsManager.sentSubscription, "selected SIM preserved");
            equal(false, SmsManager.multipart, "single segment API");
            if (api >= 31) equal("com.android.shell", SmsManager.sentPackage, "shell package attribution");
            equal(api >= 30, TelephonyFrameworkInitializer.manager != null, "telephony initialized when needed");
            cases++;
            reset(api);
            equal("ok:1", send("test", -1), "API " + api + " accepts default SIM");
            equal(api >= 31 ? -1 : Integer.MAX_VALUE, SmsManager.sentSubscription, "default manager retained");
            cases++;
        }
        reset(36);
        TelephonyServiceManager existing = new TelephonyServiceManager();
        TelephonyFrameworkInitializer.manager = existing;
        SmsManager.parts = 2;
        equal("ok:2", send("test", -1), "multipart accepted");
        equal(true, SmsManager.multipart, "multipart API");
        equal(-1, SmsManager.sentSubscription, "default subscription retained");
        equal(existing, TelephonyFrameworkInitializer.manager, "existing registry retained");
        cases++;

        for (int api : new int[]{29, 30, 31, 36}) {
            reset(api);
            SmsManager.failSubscription = true;
            equal("error:IllegalArgumentException", send("test", 7), "subscription failure returned");
            equal(0, SmsManager.sends, "must not fall back to another SIM");
            cases++;
        }

        reset(36);
        SmsManager.failSend = true;
        equal("error:permission", send("test", 7), "permission failure returned");
        equal(0, SmsManager.sends, "permission failure sends nothing");
        cases++;

        reset(36);
        Context.serviceMissing = true;
        equal("error:no_service", send("test", 7), "missing service returned");
        equal(0, SmsManager.sends, "missing service sends nothing");
        cases++;

        reset(36);
        SmsManager.parts = 0;
        equal("error:divide", send("test", 7), "empty segmentation returned");
        equal(0, SmsManager.sends, "empty segmentation sends nothing");
        cases++;

        reset(36);
        Process.uid = 0;
        equal("ok:1", send("test", 7), "root process still accepted");
        equal("com.airsim.test", SmsManager.sentPackage, "root retains supplied context");
        cases++;

        reset(36);
        equal("error:invalid", send(" ", 7), "invalid input rejected");
        equal(0, Binder.clears, "invalid input does not change identity");
        equal(0, SmsManager.sends, "invalid input sends nothing");
        cases++;
        System.out.println("Privileged SMS tests passed: " + cases + " cases");
    }
    private static String send(String text, int subscription) throws Exception {
        ShizukuBridgeUserService service = new ShizukuBridgeUserService();
        CONTEXT.set(service, new Context("com.airsim.test"));
        String result = (String) SEND.invoke(service, "test-destination", text, subscription);
        equal(10001, Binder.callingUid, "caller identity restored");
        equal(Binder.clears, Binder.restores, "identity tokens balanced");
        return result;
    }
    private static void reset(int api) {
        Build.VERSION.SDK_INT = api;
        Process.uid = 2000;
        Binder.callingUid = 10001;
        Binder.clears = Binder.restores = 0;
        TelephonyFrameworkInitializer.manager = null;
        SmsManager.sends = 0;
        SmsManager.parts = 1;
        SmsManager.failSubscription = SmsManager.failSend = false;
        SmsManager.multipart = false;
        SmsManager.sentPackage = null;
        Context.serviceMissing = false;
    }
    private static void equal(Object expected, Object actual, String label) {
        if (!expected.equals(actual)) throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
    }
}
