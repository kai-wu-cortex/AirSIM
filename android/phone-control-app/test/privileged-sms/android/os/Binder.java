package android.os;

public class Binder implements IBinder {
    public static int callingUid = 10001;
    public static int clears, restores;
    public static long clearCallingIdentity() {
        int previous = callingUid;
        callingUid = Process.myUid();
        clears++;
        return previous;
    }
    public static void restoreCallingIdentity(long token) {
        callingUid = (int) token;
        restores++;
    }
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
            throws RemoteException { return false; }
}
