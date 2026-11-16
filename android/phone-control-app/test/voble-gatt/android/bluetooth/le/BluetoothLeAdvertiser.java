package android.bluetooth.le;
public class BluetoothLeAdvertiser {
    public boolean throwOnStart, throwOnStop;
    public int starts; public AdvertiseCallback last;
    public void startAdvertising(AdvertiseSettings s,AdvertiseData d,AdvertiseCallback cb) { starts++; last=cb; if (throwOnStart) throw new IllegalStateException("fixture"); }
    public void stopAdvertising(AdvertiseCallback cb) { if (throwOnStop) throw new IllegalStateException("fixture"); }
}
