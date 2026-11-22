package android.content.pm;
public final class PackageManager {
    public static final int PERMISSION_GRANTED = 0;
    public final java.util.Set<String> features = new java.util.HashSet<>();
    public boolean hasSystemFeature(String feature) { return features.contains(feature); }
    public PackageInfo info;
    public PackageInfo getPackageInfo(String name, int flags) throws Exception {
        if (info == null) throw new Exception("not found");
        return info;
    }
}
