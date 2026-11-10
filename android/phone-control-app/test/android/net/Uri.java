package android.net;

public final class Uri {
    private final String value;
    private Uri(String value) { this.value = value; }

    public static Uri parse(String value) { return new Uri(value); }
    public String getQueryParameter(String key) {
        int question = value.indexOf('?');
        if (question < 0) return null;
        for (String pair : value.substring(question + 1).split("&")) {
            String[] pieces = pair.split("=", 2);
            if (java.net.URLDecoder.decode(pieces[0], java.nio.charset.StandardCharsets.UTF_8).equals(key))
                return pieces.length == 2 ? java.net.URLDecoder.decode(pieces[1], java.nio.charset.StandardCharsets.UTF_8) : "";
        }
        return null;
    }
    public String getSchemeSpecificPart() { return value.substring(value.indexOf(':') + 1); }
}
