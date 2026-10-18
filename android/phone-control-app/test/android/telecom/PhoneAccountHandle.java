package android.telecom;
import android.content.ComponentName;
public record PhoneAccountHandle(ComponentName component, String id) {
    public ComponentName getComponentName() { return component; }
    public String getId() { return id; }
    public String getUserHandle() { return "UserHandle{0}"; }
}
