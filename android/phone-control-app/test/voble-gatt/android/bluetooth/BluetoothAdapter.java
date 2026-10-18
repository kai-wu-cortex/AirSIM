package android.bluetooth;
public class BluetoothAdapter {
    public final android.bluetooth.le.BluetoothLeAdvertiser advertiser=new android.bluetooth.le.BluetoothLeAdvertiser();
    public boolean isEnabled() { return true; }
    public android.bluetooth.le.BluetoothLeAdvertiser getBluetoothLeAdvertiser() { return advertiser; }
}
