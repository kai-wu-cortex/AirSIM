package org.json;
public class JSONObject {
    public JSONObject put(String key, Object value) { return this; }
    public JSONObject(String value) {}
    public JSONObject() {}
    public JSONObject optJSONObject(String key) { return null; }
    public String optString(String key) { return ""; }
    public String toString() { return "{}"; }
}
