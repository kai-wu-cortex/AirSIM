package android.provider;
public final class Settings {
    public static final class Secure {
        public static final String ANDROID_ID = "android_id";
        public static String getString(Object resolver, String key) { return "test-device"; }
    }
}
