package com.airsim.phonecontrol;

import android.app.ActivityManager;
import android.content.AttributionSource;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.ICancellationSignal;
import android.os.Process;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.Arrays;
import java.util.List;

public final class PrivilegedInboxTests {
    private static int cases;
    private static final Method RECENT;
    private static final Field CONTEXT;
    static {
        try {
            RECENT = ShizukuBridgeUserService.class.getDeclaredMethod("recentSms", long.class, long.class, int.class);
            RECENT.setAccessible(true);
            CONTEXT = ShizukuBridgeUserService.class.getDeclaredField("serviceContext");
            CONTEXT.setAccessible(true);
        } catch (Exception error) { throw new ExceptionInInitializerError(error); }
    }

    public static void main(String[] args) throws Exception {
        RowsProvider provider = new RowsProvider(List.<Object[]>of(new Object[]{7387L, "10010", "test-body", 1000L, 900L, 2}));
        ShellProviderQueryTests.FakeActivityManager manager = install(provider);
        equal("[{\"address\":\"10010\",\"body\":\"test-body\",\"date\":1000,\"date_sent\":900,\"id\":7387,\"sub_id\":2}]",
                recent(7386, 0, 100), "rows read through the shell provider path");
        equal("sms", manager.acquiredAuthority, "inbox authority");
        equal("content://sms/inbox?limit=100", provider.uri.toString(), "inbox uri keeps the limit");
        equal("[_id, address, body, date, date_sent, sub_id]", Arrays.toString(provider.projection), "projection");
        equal("_id > ?", provider.queryArgs.getString("android:query-arg-sql-selection"), "selection after the cursor");
        equal("[7386]", Arrays.toString(provider.queryArgs.getStringArray("android:query-arg-sql-selection-args")),
                "selection args after the cursor");
        equal("_id ASC", provider.queryArgs.getString("android:query-arg-sql-sort-order"), "oldest first");
        equal(1, provider.closes, "cursor closed");
        equal(1, manager.releases, "provider released");
        cases++;

        provider = new RowsProvider(List.of());
        install(provider);
        equal("[]", recent(-1, 5000, 100), "first scan returns an empty batch");
        equal("date >= ?", provider.queryArgs.getString("android:query-arg-sql-selection"), "first scan uses the cutoff");
        equal("[5000]", Arrays.toString(provider.queryArgs.getStringArray("android:query-arg-sql-selection-args")),
                "cutoff argument");
        cases++;

        provider = new RowsProvider(List.of(
                new Object[]{1L, null, "one", 10L, 9L, 1},
                new Object[]{2L, "10086", null, 20L, 19L, 1},
                new Object[]{3L, "10010", "three", 30L, 29L, 1}));
        install(provider);
        equal("[{\"address\":\"\",\"body\":\"one\",\"date\":10,\"date_sent\":9,\"id\":1,\"sub_id\":1},"
                + "{\"address\":\"10086\",\"body\":\"\",\"date\":20,\"date_sent\":19,\"id\":2,\"sub_id\":1}]",
                recent(0, 0, 2), "row cap and empty strings for missing fields");
        equal("content://sms/inbox?limit=2", provider.uri.toString(), "limit follows the cap");
        cases++;

        provider = new RowsProvider(List.of());
        provider.failure = new SecurityException("denied");
        manager = install(provider);
        equal("error:SecurityException", recent(7386, 0, 100), "provider denial reported by its own type");
        equal(1, manager.releases, "provider released after a denial");
        cases++;

        provider = new RowsProvider(List.of());
        provider.nullCursor = true;
        manager = install(provider);
        equal("error:provider", recent(7386, 0, 100), "missing cursor reported");
        equal(1, manager.releases, "provider released without a cursor");
        cases++;
        System.out.println("Privileged inbox tests passed: " + cases + " cases");
    }

    private static ShellProviderQueryTests.FakeActivityManager install(RowsProvider provider) {
        Build.VERSION.SDK_INT = 36;
        Process.uid = 2000;
        ShellProviderQueryTests.FakeActivityManager manager = new ShellProviderQueryTests.FakeActivityManager();
        manager.holder = new ShellProviderQueryTests.FakeHolder(provider);
        ActivityManager.service = manager;
        return manager;
    }

    private static String recent(long afterId, long cutoff, int limit) throws Exception {
        ShizukuBridgeUserService service = new ShizukuBridgeUserService();
        CONTEXT.set(service, new Context("com.airsim.test"));
        return (String) RECENT.invoke(service, afterId, cutoff, limit);
    }

    private static void equal(Object expected, Object actual, String label) {
        if (!expected.equals(actual)) throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
    }

    /** Inbox provider in the API 31+ shape, answering with the given rows (_id, address, body, date, date_sent, sub_id). */
    public static final class RowsProvider {
        private final List<Object[]> rows;
        RuntimeException failure;
        boolean nullCursor;
        int closes;
        Uri uri;
        String[] projection;
        Bundle queryArgs;

        RowsProvider(List<Object[]> rows) { this.rows = rows; }

        public Cursor query(AttributionSource source, Uri uri, String[] projection, Bundle queryArgs,
                ICancellationSignal cancellation) {
            this.uri = uri;
            this.projection = projection;
            this.queryArgs = queryArgs;
            if (failure != null) throw failure;
            if (nullCursor) return null;
            int[] position = {-1};
            return (Cursor) Proxy.newProxyInstance(Cursor.class.getClassLoader(), new Class<?>[]{Cursor.class},
                    (proxy, method, arguments) -> switch (method.getName()) {
                        case "moveToNext" -> ++position[0] < rows.size();
                        case "getLong" -> (Long) rows.get(position[0])[(Integer) arguments[0]];
                        case "getString" -> (String) rows.get(position[0])[(Integer) arguments[0]];
                        case "getInt" -> (Integer) rows.get(position[0])[(Integer) arguments[0]];
                        case "close" -> { closes++; yield null; }
                        case "hashCode" -> System.identityHashCode(proxy);
                        case "equals" -> proxy == arguments[0];
                        case "toString" -> "rows";
                        default -> throw new UnsupportedOperationException(method.getName());
                    });
        }
    }
}
