package com.airsim.phonecontrol;
import android.app.PendingIntent;
import android.os.Binder;
import android.os.SystemClock;
import java.util.ArrayList;

public class RootSMSCallbackProviderTests {
    public static void main(String[] args) {
        SystemClock.now = 0;
        var provider = new RootSMSCallbackProvider();
        var callbacks = new ArrayList<PendingIntent>(); callbacks.add(new PendingIntent());
        String token = RootSMSCallbackProvider.register(callbacks);
        for (int uid : new int[]{10001, 2000, 1000}) {
            Binder.callerUid = uid;
            try { provider.call(RootSMSCallbackProvider.CLAIM, token, null); throw new AssertionError("non-root allowed"); }
            catch (SecurityException expected) { }
        }
        Binder.callerUid = 0;
        try { provider.call("send_sms", token, null); throw new AssertionError("provider accepts commands"); }
        catch (IllegalArgumentException expected) { }
        var result = provider.call(RootSMSCallbackProvider.CLAIM, token, null);
        if (result.callbacks == callbacks || result.callbacks.get(0) != callbacks.get(0))
            throw new AssertionError("callback capability changed");
        try { provider.call(RootSMSCallbackProvider.CLAIM, token, null); throw new AssertionError("claimed twice"); }
        catch (IllegalStateException expected) { }
        token = RootSMSCallbackProvider.register(callbacks);
        RootSMSCallbackProvider.revoke(token);
        try { provider.call(RootSMSCallbackProvider.CLAIM, token, null); throw new AssertionError("revoked claim"); }
        catch (IllegalStateException expected) { }
        System.out.println("RootSMSCallbackProviderTests passed: actual provider rejects app/shell/system, preserves one-use callbacks");
    }
}
