package android.content;

public final class AttributionSource {
    private final int uid;
    private final String packageName;
    private AttributionSource(int uid, String packageName) {
        this.uid = uid;
        this.packageName = packageName;
    }
    public int getUid() { return uid; }
    public String getPackageName() { return packageName; }

    public static final class Builder {
        private final int uid;
        private String packageName;
        public Builder(int uid) { this.uid = uid; }
        public Builder setPackageName(String packageName) {
            this.packageName = packageName;
            return this;
        }
        public AttributionSource build() { return new AttributionSource(uid, packageName); }
    }
}
