package android.content;
public record ComponentName(String packageName, String className) {
    public String flattenToString() { return packageName + "/" + className; }
}
