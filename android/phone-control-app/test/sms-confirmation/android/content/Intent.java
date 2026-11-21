package android.content;
public class Intent {
    public final String action;
    public int segment;
    public Intent(String action) { this.action = action; }
    public String getAction() { return action; }
    public Intent setPackage(String pkg) { return this; }
    public Intent putExtra(String key, int value) { segment = value; return this; }
    public int getIntExtra(String key, int fallback) { return segment; }
}
