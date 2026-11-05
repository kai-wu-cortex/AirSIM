package android.bluetooth;
public class BluetoothManager {
    public boolean returnNull, throwOnOpen, rejectService;
    public final BluetoothAdapter adapter=new BluetoothAdapter();
    public final java.util.List<BluetoothGattServer> servers=new java.util.ArrayList<>();
    public final java.util.List<BluetoothGattServerCallback> callbacks=new java.util.ArrayList<>();
    public BluetoothAdapter getAdapter() { return adapter; }
    public BluetoothGattServer openGattServer(android.content.Context context,BluetoothGattServerCallback cb) {
        if (throwOnOpen) throw new IllegalStateException("fixture");
        if (returnNull) return null;
        var server=new BluetoothGattServer(); server.rejectService=rejectService; servers.add(server);callbacks.add(cb);return server;
    }
}
