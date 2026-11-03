package android.content;

public class Intent {
    public static final String ACTION_BATTERY_CHANGED = "android.intent.action.BATTERY_CHANGED";
    private String action;
    private final java.util.Map<String, Object> extras = new java.util.HashMap<>();
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;
    public static final int FLAG_ACTIVITY_CLEAR_TOP = 0x04000000;
    public static final int FLAG_ACTIVITY_SINGLE_TOP = 0x20000000;

    public Intent(Context context, Class<?> type) {}
    public Intent(String action) { this.action = action; }
    public String getAction() { return action; }
    public Intent putExtra(String name, int value) { extras.put(name, value); return this; }
    public int getIntExtra(String name, int fallback) {
        Object value = extras.get(name); return value instanceof Integer ? (Integer)value : fallback;
    }
    public Intent addFlags(int flags) { return this; }
    public Intent putExtra(String name, String value) { return this; }
}
