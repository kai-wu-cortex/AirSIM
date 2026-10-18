package android.bluetooth;
import java.util.*;
public class BluetoothGattService {
    public static final int SERVICE_TYPE_PRIMARY=0;
    private final UUID uuid;
    public final List<BluetoothGattCharacteristic> characteristics=new ArrayList<>();
    public BluetoothGattService(UUID uuid,int type) { this.uuid=uuid; }
    public UUID getUuid() { return uuid; }
    public boolean addCharacteristic(BluetoothGattCharacteristic c) { return characteristics.add(c); }
    public List<BluetoothGattCharacteristic> getCharacteristics() { return characteristics; }
}
