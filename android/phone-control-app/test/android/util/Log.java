package android.util;

/** Host diagnostics tests exercise disk I/O, not the Android logging service. */
public final class Log {
    public static int v(String tag, String message) { return 0; }
    public static int d(String tag, String value) { return 0; }
    public static int i(String tag, String value) { return 0; }
    public static int e(String tag, String value) { return 0; }
    public static int w(String tag, String value) { return 0; }
}
