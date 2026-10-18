package android.bluetooth;
public class BluetoothManager {
    public final BluetoothAdapter adapter=new BluetoothAdapter();
    public final java.util.List<BluetoothGattServer> servers=new java.util.ArrayList<>();
    public final java.util.List<BluetoothGattServerCallback> callbacks=new java.util.ArrayList<>();
    public BluetoothAdapter getAdapter() { return adapter; }
    public BluetoothGattServer openGattServer(android.content.Context context,BluetoothGattServerCallback cb) {
        var server=new BluetoothGattServer(); servers.add(server);callbacks.add(cb);return server;
    }
}
