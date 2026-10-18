package android.net;

public final class Uri {
    private final String value;
    private Uri(String value) { this.value = value; }

    public static Uri parse(String value) { return new Uri(value); }
    public String getSchemeSpecificPart() { return value.substring(value.indexOf(':') + 1); }
}
