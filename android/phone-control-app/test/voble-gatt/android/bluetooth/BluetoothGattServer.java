package android.bluetooth;
public class BluetoothGattServer {
    public java.util.List<byte[]> notifications = new java.util.ArrayList<>();
    public BluetoothGattService pending; public boolean closed; public boolean rejectService, throwOnClose;
    public boolean addService(BluetoothGattService s) { pending=s; return !rejectService; }
    public void close() { closed=true; if (throwOnClose) throw new IllegalStateException("fixture"); }
    public void cancelConnection(BluetoothDevice d) {}
    public int notifyCharacteristicChanged(BluetoothDevice d,BluetoothGattCharacteristic c,boolean confirm,byte[] value) { notifications.add(value.clone()); return 0; }
    public boolean notifyCharacteristicChanged(BluetoothDevice d,BluetoothGattCharacteristic c,boolean confirm) { notifications.add(c.getValue().clone()); return true; }
    public boolean sendResponse(BluetoothDevice d,int id,int status,int offset,byte[] value) { return true; }
}
