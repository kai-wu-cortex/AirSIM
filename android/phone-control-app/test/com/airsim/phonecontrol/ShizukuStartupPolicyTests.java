package com.airsim.phonecontrol;

public final class ShizukuStartupPolicyTests {
    public static void main(String[] args) {
        expect(ShizukuStartupPolicy.Prompt.INSTALL,
                new ShizukuStartupPolicy(false).inspect(false, false, false, true));
        expect(ShizukuStartupPolicy.Prompt.START,
                new ShizukuStartupPolicy(false).inspect(true, false, false, true));
        expect(ShizukuStartupPolicy.Prompt.AUTHORIZE,
                new ShizukuStartupPolicy(false).inspect(true, true, false, true));
        expect(ShizukuStartupPolicy.Prompt.NONE,
                new ShizukuStartupPolicy(false).inspect(true, true, true, true));
        // A live binder takes precedence over a hidden/missing package lookup.
        expect(ShizukuStartupPolicy.Prompt.NONE,
                new ShizukuStartupPolicy(false).inspect(false, true, true, true));
        ShizukuStartupPolicy deferred = new ShizukuStartupPolicy(false);
        expect(ShizukuStartupPolicy.Prompt.NONE, deferred.inspect(false, false, false, false));
        if (deferred.checked()) throw new AssertionError("background/permission dialog consumed startup check");
        expect(ShizukuStartupPolicy.Prompt.INSTALL, deferred.inspect(false, false, false, true));
        expect(ShizukuStartupPolicy.Prompt.NONE, deferred.inspect(false, false, false, true));
        expect(ShizukuStartupPolicy.Prompt.NONE, deferred.inspect(true, true, false, true));
        expect(ShizukuStartupPolicy.Prompt.NONE,
                new ShizukuStartupPolicy(deferred.checked()).inspect(false, false, false, true));
        ShizukuStartupPolicy ready = new ShizukuStartupPolicy(false);
        ready.inspect(true, true, true, true);
        expect(ShizukuStartupPolicy.Prompt.NONE, ready.inspect(true, false, false, true));
        System.out.println("Shizuku startup prompt tests passed");
    }

    private static void expect(ShizukuStartupPolicy.Prompt expected, ShizukuStartupPolicy.Prompt actual) {
        if (expected != actual) throw new AssertionError("expected " + expected + " but got " + actual);
    }
}
