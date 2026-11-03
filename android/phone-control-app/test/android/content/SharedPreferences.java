package android.content;

public final class SharedPreferences {
    private final java.util.Map<String, Object> values = new java.util.HashMap<>();
    public String getString(String key, String fallback) { return (String) values.getOrDefault(key, fallback); }
    public long getLong(String key, long fallback) { return (Long) values.getOrDefault(key, fallback); }
    public boolean getBoolean(String key, boolean fallback) { return (Boolean) values.getOrDefault(key, fallback); }
    public Editor edit() { return new Editor(); }
    public final class Editor {
        private final java.util.Map<String, Object> pending = new java.util.HashMap<>();
        private final java.util.Set<String> removed = new java.util.HashSet<>();
        public Editor putString(String key, String value) { pending.put(key, value); return this; }
        public Editor putLong(String key, long value) { pending.put(key, value); return this; }
        public Editor putBoolean(String key, boolean value) { pending.put(key, value); return this; }
        public Editor remove(String key) { removed.add(key); return this; }
        public void apply() { for (String key : removed) values.remove(key); values.putAll(pending); }
        public boolean commit() { apply(); return true; }
    }
}
