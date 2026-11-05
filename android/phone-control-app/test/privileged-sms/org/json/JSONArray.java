package org.json;

import java.util.ArrayList;
import java.util.List;

/** Minimal JSONArray for JVM tests. */
public class JSONArray {
    private final List<Object> values = new ArrayList<>();
    public JSONArray put(Object value) { values.add(value); return this; }
    public int length() { return values.size(); }

    @Override public String toString() {
        StringBuilder text = new StringBuilder("[");
        for (Object value : values) {
            if (text.length() > 1) text.append(',');
            text.append(JSONObject.render(value));
        }
        return text.append(']').toString();
    }
}
