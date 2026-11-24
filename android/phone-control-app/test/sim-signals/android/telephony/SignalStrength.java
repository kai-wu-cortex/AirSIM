package android.telephony;
public final class SignalStrength {
    public int level; public long timestamp = 999_000; public boolean empty; public Integer componentLevel; public boolean multiple;
    public SignalStrength(int level) { this.level = level; }
    public int getLevel() { return level; }
    public java.util.List<CellSignalStrength> getCellSignalStrengths() {
        if (empty) return java.util.List.of();
        var cell = new CellSignalStrength(componentLevel == null ? level : componentLevel);
        return multiple ? java.util.List.of(cell, new CellSignalStrength(4)) : java.util.List.of(cell);
    }
    public long getTimestampMillis() {
        if (android.os.Build.VERSION.SDK_INT < 30) throw new AssertionError("API 30 method called on API 29");
        return timestamp;
    }
}
