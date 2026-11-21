package android.telephony;
public final class SignalStrength {
    public int level; public long timestamp = 999_000; public boolean empty;
    public SignalStrength(int level) { this.level = level; }
    public int getLevel() { return level; }
    public java.util.List<Object> getCellSignalStrengths() { return empty ? java.util.List.of() : java.util.List.of(new Object()); }
    public long getTimestampMillis() {
        if (android.os.Build.VERSION.SDK_INT < 30) throw new AssertionError("API 30 method called on API 29");
        return timestamp;
    }
}
