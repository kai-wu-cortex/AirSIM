package android.os;
public class Handler {
    public Handler(Looper looper) { }
    public boolean post(Runnable task) { task.run(); return true; }
}
