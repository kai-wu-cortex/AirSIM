package com.airsim.phonecontrol;
import android.bluetooth.*;
import com.airsim.phonecontrol.voble.*;

public final class VoBLEGattLifecycleTests {
    public static void main(String[] args) {
        var context=new android.content.Context();
        context.grant(android.Manifest.permission.BLUETOOTH_CONNECT);
        context.grant(android.Manifest.permission.BLUETOOTH_ADVERTISE);
        var manager=new BluetoothManager(); context.setSystemService(BluetoothManager.class,manager);
        var listener=new VoBLEGattServer.Listener() {
            public void onPairingWrite(String d,byte[] v) {} public void onControlWrite(String d,byte[] v) {}
            public void onAudioWrite(String d,byte[] v) {} public void onDisconnected(String d) {}
        };
        var gatt=new VoBLEGattServer(context,listener,new VoBLEControlChannel());
        check(gatt.start(),"service setup must start");
        check(manager.adapter.advertiser.starts==0,"advertising before service registration completed");
        var first=manager.servers.get(0); var old=manager.callbacks.get(0);
        check(first.pending.getCharacteristics().size()==7,"missing service characteristics");
        old.onServiceAdded(0,first.pending);
        check(manager.adapter.advertiser.starts==1,"successful registration did not advertise");
        old.onServiceAdded(0,first.pending);
        check(manager.adapter.advertiser.starts==1,"duplicate callback advertised twice");
        gatt.close(); gatt.start();
        old.onServiceAdded(0,first.pending);
        check(manager.adapter.advertiser.starts==1,"closed server callback revived advertising");
        var second=manager.servers.get(1);
        manager.callbacks.get(1).onServiceAdded(133,second.pending);
        check(second.closed,"failed registration left broken server alive");
        check(manager.adapter.advertiser.starts==1,"failed registration advertised");
        check(gatt.start(),"registration failure cannot retry");
        var third=manager.servers.get(2);
        manager.callbacks.get(2).onServiceAdded(0,third.pending);
        manager.adapter.advertiser.last.onStartFailure(2);
        check(third.closed,"failed advertising left nonfunctional server cached");
        gatt.close();
        System.out.println("VoBLE GATT lifecycle tests passed");
    }
    private static void check(boolean value,String message) { if(!value)throw new AssertionError(message); }
}
