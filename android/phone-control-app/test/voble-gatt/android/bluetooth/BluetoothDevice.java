package android.bluetooth;
public class BluetoothDevice {
    private final String address;
    public BluetoothDevice() { this("fixture-device"); }
    public BluetoothDevice(String address) { this.address = address; }
    public String getAddress() { return address; }
}
