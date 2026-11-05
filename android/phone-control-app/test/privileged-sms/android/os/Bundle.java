package android.os;

import java.util.HashMap;
import java.util.Map;

public final class Bundle {
    private final Map<String, Object> values = new HashMap<>();
    public void putString(String key, String value) { values.put(key, value); }
    public void putStringArray(String key, String[] value) { values.put(key, value); }
    public String getString(String key) { return (String) values.get(key); }
    public String[] getStringArray(String key) { return (String[]) values.get(key); }
}
