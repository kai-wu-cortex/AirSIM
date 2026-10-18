package android.bluetooth.le;
public class BluetoothLeAdvertiser {
    public int starts; public AdvertiseCallback last;
    public void startAdvertising(AdvertiseSettings s,AdvertiseData d,AdvertiseCallback cb) { starts++; last=cb; }
    public void stopAdvertising(AdvertiseCallback cb) {}
}
