package org.json;

import java.util.Map;
import java.util.TreeMap;

/** Minimal JSONObject for JVM tests; keys render sorted so expectations do not depend on put order. */
public class JSONObject {
    private final Map<String, Object> values = new TreeMap<>();
    public JSONObject put(String key, Object value) { values.put(key, value); return this; }
    public JSONObject put(String key, long value) { values.put(key, value); return this; }
    public JSONObject put(String key, int value) { values.put(key, value); return this; }

    @Override public String toString() {
        StringBuilder text = new StringBuilder("{");
        for (Map.Entry<String, Object> entry : values.entrySet()) {
            if (text.length() > 1) text.append(',');
            text.append(quote(entry.getKey())).append(':').append(render(entry.getValue()));
        }
        return text.append('}').toString();
    }

    static String render(Object value) {
        return value instanceof String text ? quote(text) : String.valueOf(value);
    }

    private static String quote(String text) {
        return '"' + text.replace("\\", "\\\\").replace("\"", "\\\"") + '"';
    }
}
