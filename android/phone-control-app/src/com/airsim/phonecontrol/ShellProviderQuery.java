package com.airsim.phonecontrol;

import android.content.AttributionSource;
import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Process;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * Queries a content provider from the Shizuku user service the way AOSP's {@code content}
 * command does. A ContentResolver cannot work in that app_process: ActivityManager rejects a
 * calling package the shell/root uid does not own, and then a caller without an app record.
 * getContentProviderExternal needs neither; the query carries the shell (or root) identity.
 */
final class ShellProviderQuery {
    interface Reader<T> {
        T read(Cursor cursor) throws Exception;
    }

    private static final int PER_USER_RANGE = 100_000;

    private ShellProviderQuery() {}

    /** Runs one query; {@code reader} may receive null, a cursor is closed and the provider released. */
    static <T> T query(String authority, Uri uri, String[] projection, String selection,
            String[] selectionArgs, String sortOrder, Reader<T> reader) throws Exception {
        int uid = Process.myUid();
        int userId = uid / PER_USER_RANGE;
        String callingPackage = uid == 0 ? "root" : "com.android.shell";
        Object activityManager = invoke(
                Class.forName("android.app.ActivityManager").getMethod("getService"), null);
        IBinder token = new Binder();
        Object holder = invoke(activityManager.getClass().getMethod("getContentProviderExternal",
                String.class, int.class, IBinder.class, String.class),
                activityManager, authority, userId, token, "airsim");
        if (holder == null) throw new IllegalStateException("content provider unavailable: " + authority);
        try {
            Object provider = holder.getClass().getField("provider").get(holder);
            Bundle queryArgs = new Bundle();
            queryArgs.putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection);
            queryArgs.putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs);
            queryArgs.putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sortOrder);
            Class<?> cancellation = Class.forName("android.os.ICancellationSignal");
            Cursor cursor;
            if (Build.VERSION.SDK_INT >= 31) {
                AttributionSource source = new AttributionSource.Builder(uid)
                        .setPackageName(callingPackage).build();
                cursor = (Cursor) invoke(provider.getClass().getMethod("query", AttributionSource.class,
                        Uri.class, String[].class, Bundle.class, cancellation),
                        provider, source, uri, projection, queryArgs, null);
            } else if (Build.VERSION.SDK_INT == 30) {
                cursor = (Cursor) invoke(provider.getClass().getMethod("query", String.class, String.class,
                        Uri.class, String[].class, Bundle.class, cancellation),
                        provider, callingPackage, null, uri, projection, queryArgs, null);
            } else {
                cursor = (Cursor) invoke(provider.getClass().getMethod("query", String.class,
                        Uri.class, String[].class, Bundle.class, cancellation),
                        provider, callingPackage, uri, projection, queryArgs, null);
            }
            if (cursor == null) return reader.read(null);
            try (Cursor rows = cursor) {
                return reader.read(rows);
            }
        } finally {
            invoke(activityManager.getClass().getMethod("removeContentProviderExternalAsUser",
                    String.class, IBinder.class, int.class), activityManager, authority, token, userId);
        }
    }

    /** Reflective call that rethrows the target's own exception, so callers log the real cause. */
    private static Object invoke(Method method, Object target, Object... arguments) throws Exception {
        try {
            // Framework Binder proxies may be package-private although their methods are public.
            method.setAccessible(true);
            return method.invoke(target, arguments);
        } catch (InvocationTargetException error) {
            if (error.getCause() instanceof Exception cause) throw cause;
            throw error;
        }
    }
}
