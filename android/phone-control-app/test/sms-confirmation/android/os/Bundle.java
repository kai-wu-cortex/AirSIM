package android.os;
import java.util.ArrayList;
public class Bundle {
    public ArrayList<?> callbacks;
    public <T> void putParcelableArrayList(String key, ArrayList<T> values) { callbacks = values; }
}
