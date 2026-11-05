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
            int ready, failed, disconnected;
            java.util.Set<String> retired = new java.util.HashSet<>();
            public void onPairingWrite(String d,byte[] v) {} public void onControlWrite(String d,byte[] v) {}
            public void onAudioWrite(String d,byte[] v) {} public void onDisconnected(String d) { disconnected++; retired.add(d); }
            public void onAdvertisingReady() { ready++; }
            public void onAdvertisingFailed(int code) { failed++; }
        };
        var channel = new VoBLEControlChannel();
        var gatt=new VoBLEGattServer(context,listener,channel);
        check(gatt.start(),"service setup must start");
        check(manager.adapter.advertiser.starts==0,"advertising before service registration completed");
        var first=manager.servers.get(0); var old=manager.callbacks.get(0);
        check(first.pending.getCharacteristics().size()==7,"missing service characteristics");
        old.onServiceAdded(0,first.pending);
        check(manager.adapter.advertiser.starts==1,"successful registration did not advertise");
        manager.adapter.advertiser.last.onStartSuccess(null);
        check(listener.ready==1,"successful advertising did not notify the service");
        old.onServiceAdded(0,first.pending);
        check(manager.adapter.advertiser.starts==1,"duplicate callback advertised twice");
        var peer = new BluetoothDevice("old-address");
        old.onConnectionStateChange(peer, 0, 2);
        channel.authenticate(peer.getAddress()); channel.subscribeControl(peer.getAddress());
        long oldEpoch = channel.epoch();
        first.throwOnClose = true; manager.adapter.advertiser.throwOnStop = true;
        gatt.close();
        check(listener.disconnected == 1, "close must retire peer even when stack teardown throws");
        check(!channel.isControlSubscribed(peer.getAddress()), "close leaked old subscription");
        check(!channel.authenticate("old-address", oldEpoch), "queued authentication revived a closed GATT generation");
        check(channel.canAuthenticate("new-address"), "close leaked authenticated owner");
        gatt.close();
        check(listener.disconnected == 1, "duplicate close must not notify twice");
        manager.adapter.advertiser.throwOnStop = false;
        gatt.start();
        channel.authenticate("new-address");
        old.onConnectionStateChange(peer, 0, 0);
        check(channel.owns("new-address"), "old disconnect must not clear new owner");
        check(listener.disconnected == 1, "old callback escaped generation fence");
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
        check(listener.failed==2,"failed advertising did not notify the service");
        gatt.close();
        check(listener.retired.contains("new-address"), "close must retire channel-only owner too");
        manager.returnNull = true;
        check(!gatt.start(), "null server must fail");
        check(listener.failed == 3, "null server did not schedule retry");
        manager.returnNull = false; manager.rejectService = true;
        check(!gatt.start(), "rejected addService must fail");
        check(listener.failed == 4, "addService false did not schedule retry");
        manager.rejectService = false; manager.throwOnOpen = true;
        check(!gatt.start(), "open exception must fail");
        check(listener.failed == 5, "open exception did not schedule retry");
        manager.throwOnOpen = false;
        check(gatt.start(), "exception must permit subsequent recovery");
        int last = manager.servers.size() - 1;
        manager.adapter.advertiser.throwOnStart = true;
        manager.callbacks.get(last).onServiceAdded(0, manager.servers.get(last).pending);
        check(listener.failed == 6, "advertise exception did not schedule retry");
        check(manager.servers.get(last).closed, "advertise exception leaked server");
        manager.adapter.advertiser.throwOnStart = false;
        check(gatt.start(), "advertise exception cannot retry");
        last = manager.servers.size() - 1;
        manager.callbacks.get(last).onServiceAdded(0, manager.servers.get(last).pending);
        manager.adapter.advertiser.last.onStartSuccess(null);
        check(listener.ready == 2, "recovery did not become ready");
        gatt.close();
        System.out.println("VoBLE GATT lifecycle tests passed");
    }
    private static void check(boolean value,String message) { if(!value)throw new AssertionError(message); }
}
