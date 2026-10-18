package android.bluetooth.le;
public class AdvertiseData {
    public static class Builder {
        public Builder setIncludeDeviceName(boolean v) { return this; }
        public Builder addServiceUuid(android.os.ParcelUuid v) { return this; }
        public AdvertiseData build() { return new AdvertiseData(); }
    }
}
