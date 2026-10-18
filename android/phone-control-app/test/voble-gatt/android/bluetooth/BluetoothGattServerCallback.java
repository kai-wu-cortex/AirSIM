package android.bluetooth;
public class BluetoothGattServerCallback {
    public void onServiceAdded(int status,BluetoothGattService service) {}
    public void onConnectionStateChange(BluetoothDevice d,int status,int state) {}
    public void onMtuChanged(BluetoothDevice d,int mtu) {}
    public void onCharacteristicReadRequest(BluetoothDevice d,int id,int offset,BluetoothGattCharacteristic c) {}
    public void onCharacteristicWriteRequest(BluetoothDevice d,int id,BluetoothGattCharacteristic c,boolean prepared,boolean response,int offset,byte[] value) {}
    public void onNotificationSent(BluetoothDevice d,int status) {}
    public void onDescriptorWriteRequest(BluetoothDevice d,int id,BluetoothGattDescriptor desc,boolean prepared,boolean response,int offset,byte[] value) {}
}
