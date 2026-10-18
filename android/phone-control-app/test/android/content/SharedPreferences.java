package android.content;

public final class SharedPreferences {
    private final java.util.Map<String, String> values = new java.util.HashMap<>();
    public String getString(String key, String fallback) { return values.getOrDefault(key, fallback); }
    public Editor edit() { return new Editor(); }
    public final class Editor {
        private final java.util.Map<String, String> pending = new java.util.HashMap<>();
        public Editor putString(String key, String value) { pending.put(key, value); return this; }
        public void apply() { values.putAll(pending); }
    }
}
