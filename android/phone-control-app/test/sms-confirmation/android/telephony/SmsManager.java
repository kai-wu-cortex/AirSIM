package android.telephony;
import java.util.ArrayList;
public class SmsManager {
    public static int segments = 1;
    public ArrayList<String> divideMessage(String body) {
        ArrayList<String> parts = new ArrayList<>();
        for (int i = 0; i < segments; i++) parts.add("fixture");
        return parts;
    }
}
