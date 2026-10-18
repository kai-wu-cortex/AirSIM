package android.bluetooth;
import java.util.*;
public class BluetoothGattCharacteristic {
    public static final int PROPERTY_READ=2, PROPERTY_WRITE=8, PROPERTY_WRITE_NO_RESPONSE=4,
        PROPERTY_INDICATE=32, PROPERTY_NOTIFY=16, PERMISSION_READ=1, PERMISSION_WRITE=16;
    private final UUID uuid; private byte[] value;
    public BluetoothGattCharacteristic(UUID uuid,int properties,int permissions) { this.uuid=uuid; }
    public UUID getUuid() { return uuid; }
    public boolean addDescriptor(BluetoothGattDescriptor d) { d.owner=this; return true; }
    public boolean setValue(byte[] value) { this.value=value;return true; }
    public byte[] getValue() { return value; }
}
