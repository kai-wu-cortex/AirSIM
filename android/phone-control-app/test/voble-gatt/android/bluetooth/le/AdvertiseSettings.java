package android.bluetooth.le;
public class AdvertiseSettings {
    public static final int ADVERTISE_MODE_LOW_LATENCY=2, ADVERTISE_TX_POWER_MEDIUM=2;
    public static class Builder {
        public Builder setAdvertiseMode(int v) { return this; }
        public Builder setConnectable(boolean v) { return this; }
        public Builder setTimeout(int v) { return this; }
        public Builder setTxPowerLevel(int v) { return this; }
        public AdvertiseSettings build() { return new AdvertiseSettings(); }
    }
}
