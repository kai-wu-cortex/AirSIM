package android.bluetooth;
import java.util.UUID;
public class BluetoothGattDescriptor {
    public static final int PERMISSION_READ=1, PERMISSION_WRITE=16;
    public static final byte[] ENABLE_NOTIFICATION_VALUE={1,0}, ENABLE_INDICATION_VALUE={2,0};
    final UUID uuid; BluetoothGattCharacteristic owner;
    public BluetoothGattDescriptor(UUID uuid,int permissions) { this.uuid=uuid; }
    public UUID getUuid() { return uuid; }
    public BluetoothGattCharacteristic getCharacteristic() { return owner; }
    public boolean setValue(byte[] value) { return true; }
}
