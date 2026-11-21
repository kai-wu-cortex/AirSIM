package com.airsim.phonecontrol;

public final class RootSMSCallbackStoreTests {
    static void expectFailure(Runnable task, Class<?> type) {
        try { task.run(); } catch (RuntimeException error) {
            if (type.isInstance(error)) return;
            throw error;
        }
        throw new AssertionError("expected " + type.getSimpleName());
    }
    public static void main(String[] args) {
        var store = new RootSMSCallbackStore<String>();
        String first = store.register("first", 100);
        String second = store.register("second", 100);
        for (int uid : new int[]{10001, 2000, 1000})
            expectFailure(() -> store.claim(uid, first, 101), SecurityException.class);
        if (!"first".equals(store.claim(0, first, 101))) throw new AssertionError("lost authorized callback");
        expectFailure(() -> store.claim(0, first, 102), IllegalStateException.class);
        expectFailure(() -> store.claim(0, "unknown", 102), IllegalStateException.class);
        if (!"second".equals(store.claim(0, second, 102))) throw new AssertionError("crossed attempts");
        String revoked = store.register("revoked", 100);
        store.revoke(revoked);
        expectFailure(() -> store.claim(0, revoked, 101), IllegalStateException.class);
        String expired = store.register("expired", 100);
        expectFailure(() -> store.claim(0, expired, 60_100), IllegalStateException.class);
        for (int i = 0; i < 16; i++) store.register("bounded", 100);
        expectFailure(() -> store.register("overflow", 101), IllegalStateException.class);
        store.register("expired reclaimed", 60_100);
        System.out.println("RootSMSCallbackStoreTests passed: root-only, one-use, isolated, revoked, expired, bounded");
    }
}
