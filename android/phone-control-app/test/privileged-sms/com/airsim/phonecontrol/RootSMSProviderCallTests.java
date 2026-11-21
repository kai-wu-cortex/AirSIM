package com.airsim.phonecontrol;

import android.app.ActivityManager;
import android.content.AttributionSource;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;

public final class RootSMSProviderCallTests {
    static final Bundle RESULT = new Bundle();
    static final String AUTHORITY = "com.airsim.test.root-sms-callbacks";
    static int calls;
    static boolean fail;
    static Bundle answer(Object identity, String authority, String method, String token) {
        if (identity instanceof AttributionSource source) {
            if (source.getUid() != 0 || !"root".equals(source.getPackageName())) throw new AssertionError("identity");
        } else if (!"root".equals(identity)) throw new AssertionError("identity");
        if (!AUTHORITY.equals(authority) || !"claim_sent_callbacks".equals(method) || !"fixture".equals(token))
            throw new AssertionError("claim changed");
        calls++;
        if (fail) throw new SecurityException("fixture denied");
        return RESULT;
    }
    private static final class Q {
        public Bundle call(String pkg, String authority, String method, String arg, Bundle extras) {
            return answer(pkg, authority, method, arg);
        }
    }
    private static final class R {
        public Bundle call(String pkg, String tag, String authority, String method, String arg, Bundle extras) {
            if (tag != null) throw new AssertionError("tag");
            return answer(pkg, authority, method, arg);
        }
    }
    private static final class S {
        public Bundle call(AttributionSource source, String authority, String method, String arg, Bundle extras) {
            return answer(source, authority, method, arg);
        }
    }
    public static void main(String[] args) throws Exception {
        for (int api : new int[]{29, 30, 31, 36}) {
            for (boolean failure : new boolean[]{false, true}) {
                Build.VERSION.SDK_INT = api; Process.uid = 0; fail = failure;
                var manager = new ShellProviderQueryTests.FakeActivityManager();
                manager.holder = new ShellProviderQueryTests.FakeHolder(api < 30 ? new Q() : api == 30 ? new R() : new S());
                ActivityManager.service = manager;
                try {
                    if (ShellProviderQuery.call(AUTHORITY, 10, "claim_sent_callbacks", "fixture") != RESULT || failure)
                        throw new AssertionError("result");
                } catch (SecurityException error) { if (!failure) throw error; }
                if (manager.acquiredUser != 10 || manager.releasedUser != 10 || manager.releases != 1
                        || manager.acquiredToken != manager.releasedToken) throw new AssertionError("provider lease");
            }
        }
        Process.uid = 2000;
        try { ShellProviderQuery.call(AUTHORITY, 0, "claim_sent_callbacks", "fixture"); throw new AssertionError("shell allowed"); }
        catch (SecurityException expected) { }
        if (calls != 8) throw new AssertionError("unexpected call");
        System.out.println("RootSMSProviderCallTests passed: API29/30/31/36, profile10, release on failure, root only");
    }
}
