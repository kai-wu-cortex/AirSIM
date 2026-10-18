package android.telephony;
public final class PhoneNumberUtils {
    public static boolean compare(String first, String second) {
        return first.replaceAll("[^0-9]", "").equals(second.replaceAll("[^0-9]", ""));
    }
}
