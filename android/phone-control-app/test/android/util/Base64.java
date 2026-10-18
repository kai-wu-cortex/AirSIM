package android.util;
public final class Base64 {
    public static final int NO_WRAP=2;
    public static String encodeToString(byte[] value,int flags) {return java.util.Base64.getEncoder().encodeToString(value);}
}
