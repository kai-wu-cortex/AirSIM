package android.os;
public class Binder {
    public static int callerUid;
    public static int getCallingUid() { return callerUid; }
}
