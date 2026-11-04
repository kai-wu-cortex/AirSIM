package android.net;

/** In-memory namespace binding fixture; no OS socket or phone audio. */
public final class LocalServerSocket {
    private static final java.util.Set<String> OWNERS = new java.util.HashSet<>();
    private final String name;
    public LocalServerSocket(String name) throws java.io.IOException {
        this.name = name;
        synchronized (OWNERS) {
            if (!OWNERS.add(name)) throw new java.io.IOException("ownership already held");
        }
    }
    public void close() { synchronized (OWNERS) { OWNERS.remove(name); } }
}
