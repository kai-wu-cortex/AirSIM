package com.airsim.phonecontrol;

import android.app.ActivityManager;
import android.content.AttributionSource;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.ICancellationSignal;
import android.os.Process;
import java.lang.reflect.Proxy;
import java.util.Arrays;

public final class ShellProviderQueryTests {
    private static int cases;
    private static final Uri URI = Uri.parse("content://sms/inbox");
    private static final String[] PROJECTION = {"_id"};

    public static void main(String[] args) throws Exception {
        for (int api : new int[]{36, 31}) {
            ModernProvider provider = new ModernProvider();
            FakeActivityManager manager = install(api, 2000, provider);
            equal("read", query(cursor -> {
                same(provider.cursor, cursor, "reader gets the provider cursor");
                return "read";
            }), "API " + api + " returns the reader result");
            acquired(manager, 0);
            AttributionSource source = (AttributionSource) provider.identity;
            equal(2000, source.getUid(), "API " + api + " attributes the shell uid");
            equal("com.android.shell", source.getPackageName(), "API " + api + " attributes the shell package");
            passedThrough(provider);
            equal(1, provider.closes, "cursor closed once");
            released(manager, 0);
        }
        cases++;

        RProvider r = new RProvider();
        FakeActivityManager manager = install(30, 2000, r);
        equal("read", query(cursor -> "read"), "API 30 returns the reader result");
        equal("com.android.shell", r.identity, "API 30 calling package");
        same(null, r.attributionTag, "API 30 attribution tag");
        passedThrough(r);
        equal(1, r.closes, "API 30 cursor closed");
        released(manager, 0);
        cases++;

        QProvider q = new QProvider();
        manager = install(29, 2000, q);
        equal("read", query(cursor -> "read"), "API 29 returns the reader result");
        equal("com.android.shell", q.identity, "API 29 calling package");
        passedThrough(q);
        equal(1, q.closes, "API 29 cursor closed");
        released(manager, 0);
        cases++;

        ModernProvider root = new ModernProvider();
        manager = install(36, 0, root);
        query(cursor -> "read");
        acquired(manager, 0);
        equal(0, ((AttributionSource) root.identity).getUid(), "root uid attributed");
        equal("root", ((AttributionSource) root.identity).getPackageName(), "root package attributed");
        released(manager, 0);
        cases++;

        ModernProvider secondary = new ModernProvider();
        manager = install(36, 1002000, secondary);
        query(cursor -> "read");
        acquired(manager, 10);
        equal(1002000, ((AttributionSource) secondary.identity).getUid(), "secondary-user shell uid attributed");
        released(manager, 10);
        cases++;

        ModernProvider denied = new ModernProvider();
        denied.failure = new SecurityException("denied");
        manager = install(36, 2000, denied);
        Exception error = failure(cursor -> "read");
        equal(SecurityException.class, error.getClass(), "provider exception is not wrapped");
        equal("denied", error.getMessage(), "provider exception message kept");
        released(manager, 0);
        cases++;

        ModernProvider rejectedRows = new ModernProvider();
        manager = install(36, 2000, rejectedRows);
        error = failure(cursor -> { throw new IllegalStateException("reader"); });
        equal(IllegalStateException.class, error.getClass(), "reader exception propagates");
        equal(1, rejectedRows.closes, "cursor closed after a reader failure");
        released(manager, 0);
        cases++;

        ModernProvider empty = new ModernProvider();
        empty.nullCursor = true;
        manager = install(36, 2000, empty);
        equal("no cursor", query(cursor -> cursor == null ? "no cursor" : "cursor"), "null cursor reaches the reader");
        released(manager, 0);
        cases++;

        manager = install(36, 2000, new ModernProvider());
        manager.holder = null;
        error = failure(cursor -> "read");
        equal(IllegalStateException.class, error.getClass(), "missing provider reported");
        equal(0, manager.releases, "nothing to release without a provider");
        cases++;

        manager = install(36, 2000, new QProvider());
        error = failure(cursor -> "read");
        equal(NoSuchMethodException.class, error.getClass(), "missing query shape reported");
        released(manager, 0);
        cases++;
        for (int api : new int[]{29, 30, 31, 36}) {
            manager = install(api, 2000, new ModernProvider());
            manager.holder = new FakeHolder(android.content.HiddenProviderFixtures.provider(api));
            equal("empty", query(cursor -> cursor == null ? "empty" : "rows"),
                    "non-public provider is callable on API " + api);
            released(manager, 0);
            cases++;
        }
        System.out.println("Shell provider query tests passed: " + cases + " cases");
    }

    private static FakeActivityManager install(int api, int uid, FakeProvider provider) {
        Build.VERSION.SDK_INT = api;
        Process.uid = uid;
        FakeActivityManager manager = new FakeActivityManager();
        manager.holder = new FakeHolder(provider);
        ActivityManager.service = manager;
        return manager;
    }

    private static <T> T query(ShellProviderQuery.Reader<T> reader) throws Exception {
        return ShellProviderQuery.query("sms", URI, PROJECTION, "_id > ?", new String[]{"7386"}, "_id ASC", reader);
    }

    private static Exception failure(ShellProviderQuery.Reader<?> reader) {
        try {
            query(reader);
        } catch (Exception error) {
            return error;
        }
        throw new AssertionError("query should have failed");
    }

    private static void acquired(FakeActivityManager manager, int user) {
        equal("sms", manager.acquiredAuthority, "acquired authority");
        equal(user, manager.acquiredUser, "acquired for user " + user);
        equal("airsim", manager.acquiredTag, "acquire tag");
        if (manager.acquiredToken == null) throw new AssertionError("acquired without a token");
    }

    private static void passedThrough(FakeProvider provider) {
        same(URI, provider.uri, "uri passed through");
        same(PROJECTION, provider.projection, "projection passed through");
        equal("_id > ?", provider.queryArgs.getString("android:query-arg-sql-selection"), "selection");
        equal("[7386]", Arrays.toString(provider.queryArgs.getStringArray("android:query-arg-sql-selection-args")),
                "selection args");
        equal("_id ASC", provider.queryArgs.getString("android:query-arg-sql-sort-order"), "sort order");
        same(null, provider.cancellation, "no cancellation signal");
    }

    private static void released(FakeActivityManager manager, int user) {
        equal(1, manager.releases, "provider released once");
        equal("sms", manager.releasedAuthority, "released authority");
        same(manager.acquiredToken, manager.releasedToken, "released with the acquiring token");
        equal(user, manager.releasedUser, "released for user " + user);
    }

    private static void equal(Object expected, Object actual, String label) {
        if (!expected.equals(actual)) throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
    }

    private static void same(Object expected, Object actual, String label) {
        if (expected != actual) throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
    }

    public static final class FakeActivityManager {
        public FakeHolder holder;
        public String acquiredAuthority, acquiredTag, releasedAuthority;
        public int acquiredUser = -1, releasedUser = -1, releases;
        public IBinder acquiredToken, releasedToken;

        public FakeHolder getContentProviderExternal(String name, int userId, IBinder token, String tag) {
            acquiredAuthority = name;
            acquiredUser = userId;
            acquiredToken = token;
            acquiredTag = tag;
            return holder;
        }

        public void removeContentProviderExternalAsUser(String name, IBinder token, int userId) {
            releases++;
            releasedAuthority = name;
            releasedToken = token;
            releasedUser = userId;
        }
    }

    public static final class FakeHolder {
        public Object provider;
        FakeHolder(Object provider) { this.provider = provider; }
    }

    /** Records one query and answers with its cursor, null, or a configured failure. */
    public abstract static class FakeProvider {
        RuntimeException failure;
        boolean nullCursor;
        int closes;
        Object identity;
        Uri uri;
        String[] projection;
        Bundle queryArgs;
        Object cancellation = "unset";
        final Cursor cursor = (Cursor) Proxy.newProxyInstance(Cursor.class.getClassLoader(),
                new Class<?>[]{Cursor.class}, (proxy, method, arguments) -> switch (method.getName()) {
                    case "close" -> { closes++; yield null; }
                    case "hashCode" -> System.identityHashCode(proxy);
                    case "equals" -> proxy == arguments[0];
                    case "toString" -> "cursor";
                    default -> throw new UnsupportedOperationException(method.getName());
                });

        Cursor answer(Object identity, Uri uri, String[] projection, Bundle queryArgs, ICancellationSignal cancellation) {
            this.identity = identity;
            this.uri = uri;
            this.projection = projection;
            this.queryArgs = queryArgs;
            this.cancellation = cancellation;
            if (failure != null) throw failure;
            return nullCursor ? null : cursor;
        }
    }

    public static final class ModernProvider extends FakeProvider {
        public Cursor query(AttributionSource source, Uri uri, String[] projection, Bundle queryArgs,
                ICancellationSignal cancellation) {
            return answer(source, uri, projection, queryArgs, cancellation);
        }
    }

    public static final class RProvider extends FakeProvider {
        String attributionTag = "unset";
        public Cursor query(String callingPackage, String attributionTag, Uri uri, String[] projection,
                Bundle queryArgs, ICancellationSignal cancellation) {
            this.attributionTag = attributionTag;
            return answer(callingPackage, uri, projection, queryArgs, cancellation);
        }
    }

    public static final class QProvider extends FakeProvider {
        public Cursor query(String callingPackage, Uri uri, String[] projection, Bundle queryArgs,
                ICancellationSignal cancellation) {
            return answer(callingPackage, uri, projection, queryArgs, cancellation);
        }
    }
}
