package android.telecom;

public final class DisconnectCause {
    public static final int ERROR = 1;
    public static final int LOCAL = 2;
    public static final int REMOTE = 3;
    public static final int CANCELED = 4;
    public static final int MISSED = 5;
    public static final int REJECTED = 6;
    public static final int BUSY = 7;
    public static final int RESTRICTED = 8;

    private final int code;
    public DisconnectCause(int code) { this.code = code; }
    public int getCode() { return code; }
}
