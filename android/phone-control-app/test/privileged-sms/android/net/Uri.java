package android.net;

public final class Uri {
    private final String value;
    private Uri(String value) { this.value = value; }
    public static Uri parse(String value) { return new Uri(value); }
    public Builder buildUpon() { return new Builder(value); }
    public String getAuthority() {
        String rest = value.substring(value.indexOf("://") + 3);
        int end = rest.length();
        for (char stop : new char[]{'/', '?'}) {
            int index = rest.indexOf(stop);
            if (index >= 0 && index < end) end = index;
        }
        return rest.substring(0, end);
    }
    @Override public String toString() { return value; }

    public static final class Builder {
        private String value;
        private Builder(String value) { this.value = value; }
        public Builder appendQueryParameter(String key, String parameter) {
            value += (value.contains("?") ? "&" : "?") + key + "=" + parameter;
            return this;
        }
        public Uri build() { return new Uri(value); }
    }
}
