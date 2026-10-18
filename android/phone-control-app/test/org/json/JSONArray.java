package org.json;

import java.util.ArrayList;
import java.util.List;

public class JSONArray {
    private final List<Object> list = new ArrayList<>();

    public JSONArray() {}

    public JSONArray(String json) {}

    public JSONArray put(Object value) {
        list.add(value);
        return this;
    }

    public int length() {
        return list.size();
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append(list.get(i));
        }
        sb.append("]");
        return sb.toString();
    }
}
