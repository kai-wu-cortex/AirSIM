package android.app;
import android.content.Context;
public class Application {
    private Context context;
    private void attach(Context context) { this.context = context; }
    public String getOpPackageName() { return context.getPackageName(); }
}
