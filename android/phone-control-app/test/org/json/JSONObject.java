package org.json;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * JVM 测试环境的 org.json 迷你实现。
 * 覆盖 App 源码在测试编译里用到的全部 API：get 系列、opt 系列、put、has、remove 与 Map 构造。
 * 语义与 Android 平台实现一致：get 系列缺键抛 JSONException，opt 系列返回回退值。
 */
public class JSONObject {
    private final Map<String, Object> map = new LinkedHashMap<>();

    public JSONObject() {}

    public JSONObject(String json) {}

    public JSONObject(Map<?, ?> source) {
        for (Map.Entry<?, ?> entry : source.entrySet()) {
            map.put(String.valueOf(entry.getKey()), entry.getValue());
        }
    }

    public JSONObject put(String key, Object value) throws JSONException {
        map.put(key, value);
        return this;
    }

    public JSONObject put(String key, boolean value) throws JSONException {
        map.put(key, value);
        return this;
    }

    public JSONObject put(String key, int value) throws JSONException {
        map.put(key, value);
        return this;
    }

    public JSONObject put(String key, long value) throws JSONException {
        map.put(key, value);
        return this;
    }

    public JSONObject put(String key, double value) throws JSONException {
        map.put(key, value);
        return this;
    }

    public boolean has(String key) {
        return map.containsKey(key);
    }

    public Object remove(String key) {
        return map.remove(key);
    }

    public Object get(String key) throws JSONException {
        Object value = map.get(key);
        if (value == null && !map.containsKey(key)) throw new JSONException("no value for " + key);
        return value;
    }

    public String getString(String key) throws JSONException {
        Object value = get(key);
        return value == null ? "null" : value.toString();
    }

    public long getLong(String key) throws JSONException {
        Object value = get(key);
        if (value instanceof Number n) return n.longValue();
        if (value instanceof String s) return Long.parseLong(s);
        throw new JSONException("not a long: " + key);
    }

    public int getInt(String key) throws JSONException {
        Object value = get(key);
        if (value instanceof Number n) return n.intValue();
        if (value instanceof String s) return Integer.parseInt(s);
        throw new JSONException("not an int: " + key);
    }

    public boolean getBoolean(String key) throws JSONException {
        Object value = get(key);
        if (value instanceof Boolean b) return b;
        if (value instanceof String s) return Boolean.parseBoolean(s);
        throw new JSONException("not a boolean: " + key);
    }

    public JSONObject getJSONObject(String key) throws JSONException {
        Object value = get(key);
        if (value instanceof JSONObject object) return object;
        throw new JSONException("not a JSONObject: " + key);
    }

    public JSONArray getJSONArray(String key) throws JSONException {
        Object value = get(key);
        if (value instanceof JSONArray array) return array;
        throw new JSONException("not a JSONArray: " + key);
    }

    public Object opt(String key) {
        return map.get(key);
    }

    public String optString(String key) {
        return optString(key, "");
    }

    public String optString(String key, String fallback) {
        Object value = map.get(key);
        return value != null ? value.toString() : fallback;
    }

    public int optInt(String key) {
        return optInt(key, 0);
    }

    public int optInt(String key, int fallback) {
        Object value = map.get(key);
        if (value instanceof Number n) return n.intValue();
        if (value instanceof String s) {
            try { return Integer.parseInt(s); } catch (NumberFormatException ignored) { }
        }
        return fallback;
    }

    public long optLong(String key) {
        return optLong(key, 0L);
    }

    public long optLong(String key, long fallback) {
        Object value = map.get(key);
        if (value instanceof Number n) return n.longValue();
        if (value instanceof String s) {
            try { return Long.parseLong(s); } catch (NumberFormatException ignored) { }
        }
        return fallback;
    }

    public boolean optBoolean(String key) {
        return optBoolean(key, false);
    }

    public boolean optBoolean(String key, boolean fallback) {
        Object value = map.get(key);
        if (value instanceof Boolean b) return b;
        if (value instanceof String s) return Boolean.parseBoolean(s);
        return fallback;
    }

    public JSONObject optJSONObject(String key) {
        Object value = map.get(key);
        return value instanceof JSONObject object ? object : null;
    }

    public JSONArray optJSONArray(String key) {
        Object value = map.get(key);
        return value instanceof JSONArray array ? array : null;
    }

    public boolean isNull(String key) {
        return map.get(key) == null;
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            if (!first) sb.append(",");
            sb.append("\"").append(entry.getKey()).append("\":");
            Object v = entry.getValue();
            if (v instanceof String s) {
                sb.append("\"").append(s).append("\"");
            } else if (v == null) {
                sb.append("null");
            } else {
                sb.append(v);
            }
            first = false;
        }
        sb.append("}");
        return sb.toString();
    }
}
