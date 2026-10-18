package android.os;

public final class Bundle {
    private final java.util.Map<String, Object> values = new java.util.HashMap<>();

    public void putParcelable(String key, Object value) { values.put(key, value); }
    public Object getParcelable(String key) { return values.get(key); }
    public boolean containsKey(String key) { return values.containsKey(key); }

    public void putInt(String key, int value) { values.put(key, value); }
    public int getInt(String key) { return getInt(key, 0); }
    public int getInt(String key, int defaultValue) {
        Object value = values.get(key);
        return value instanceof Integer ? (Integer) value : defaultValue;
    }

    public void putString(String key, String value) { values.put(key, value); }
    public String getString(String key) { return getString(key, null); }
    public String getString(String key, String defaultValue) {
        Object value = values.get(key);
        return value instanceof String ? (String) value : defaultValue;
    }

    public void putBoolean(String key, boolean value) { values.put(key, value); }
    public boolean getBoolean(String key) { return getBoolean(key, false); }
    public boolean getBoolean(String key, boolean defaultValue) {
        Object value = values.get(key);
        return value instanceof Boolean ? (Boolean) value : defaultValue;
    }
}
