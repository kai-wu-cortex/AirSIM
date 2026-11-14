package com.airsim.phonecontrol;
import android.bluetooth.*;
import com.airsim.phonecontrol.voble.*;

public final class VoBLEGattLifecycleTests {
    public static void main(String[] args) {
        notificationBatching();
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
        channel.subscribeAudio(peer.getAddress());
        old.onMtuChanged(peer, 517);
        // A receive-only stream has no uplink writes to drive the radio. Queue
        // successive PCM frames while the first notification is outstanding.
        for (int i = 0; i < 4; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "audio queue must accept bounded burst");
        check(first.notifications.size() == 1, "only one stack notification may be in flight");
        check(!gatt.notifyAudioPacket(peer.getAddress(), audio(4)), "audio backlog must stay bounded");
        check(gatt.audioSendSummary(peer.getAddress()).contains("queue_full=1 "), "queue pressure must be distinguished from platform errors");
        old.onNotificationSent(peer, 0);
        check(first.notifications.size() == 2, "callback must immediately send next frame without producer polling");
        check(gatt.audioSendSummary(peer.getAddress()).contains("callbacks=1 "), "audio callback not counted");
        check(gatt.notifyAudioPacket(peer.getAddress(), audio(4)), "completed frame must free one slot");
        for (int i = 0; i < 4; i++) old.onNotificationSent(peer, 0);
        check(first.notifications.size() == 5, "all five queued frames must drain exactly once");
        var decoder = new VoBLEProtocol.AudioReassembler();
        for (int i = 0; i < 5; i++) check(decoder.append(first.notifications.get(i), i).sequence() == i, "audio order changed");
        // Fragmented frames count once; accepting a partial extra packet would
        // corrupt reassembly and turn overload into audible gaps.
        old.onMtuChanged(peer, 80);
        int before = first.notifications.size();
        var fragments = VoBLEProtocol.encodeAudioFragments(audio(10), 77);
        for (int i = 10; i < 14; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "fragmented frame refused");
        check(!gatt.notifyAudioPacket(peer.getAddress(), audio(14)), "fragmented queue unbounded");
        old.onNotificationSent(peer, 0);
        check(!gatt.notifyAudioPacket(peer.getAddress(), audio(14)), "partial frame must retain its slot");
        for (int i = 1; i < 4 * fragments.size(); i++) old.onNotificationSent(peer, 0);
        check(first.notifications.size() == before + 4 * fragments.size(), "fragment loss or duplication");
        check(gatt.notifyAudioPacket(peer.getAddress(), audio(20)), "queue failed to recover");
        old.onNotificationSent(peer, 133);
        check(!gatt.notifyAudioPacket(peer.getAddress(), audio(21)), "notification failure must propagate");
        check(gatt.audioSendSummary(peer.getAddress()).contains("callback_errors=1 last_status=133"), "platform callback error lost");
        check(gatt.audioSendSummary(peer.getAddress()).contains("previous_failure=1 "), "retry cause not counted");
        check(gatt.notifyAudioPacket(peer.getAddress(), audio(21)), "failure must permit fresh packet retry");
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
    private static void notificationBatching() {
        var context = new android.content.Context();
        context.grant(android.Manifest.permission.BLUETOOTH_CONNECT);
        context.grant(android.Manifest.permission.BLUETOOTH_ADVERTISE);
        var manager = new BluetoothManager(); context.setSystemService(BluetoothManager.class, manager);
        var channel = new VoBLEControlChannel();
        var gatt = new VoBLEGattServer(context, new VoBLEGattServer.Listener() {
            public void onPairingWrite(String d, byte[] v) {} public void onControlWrite(String d, byte[] v) {}
            public void onAudioWrite(String d, byte[] v) {} public void onDisconnected(String d) {}
        }, channel);
        check(gatt.start(), "batch test server");
        var callback = manager.callbacks.get(0); var server = manager.servers.get(0);
        var peer = new BluetoothDevice("batch-peer");
        callback.onConnectionStateChange(peer, 0, 2);
        channel.authenticate(peer.getAddress()); channel.subscribeAudio(peer.getAddress());
        callback.onMtuChanged(peer, 517);
        gatt.setAudioBatching(peer.getAddress(), true);
        for (int i = 0; i < 4; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "batch enqueue");
        callback.onNotificationSent(peer, 0);
        check(server.notifications.size() == 2 && server.notifications.get(1).length == 388,
                "two encrypted 20ms frames must share one notification at MTU 517");
        callback.onNotificationSent(peer, 0);
        callback.onNotificationSent(peer, 0);
        check(server.notifications.size() == 3, "batch completion must remove exactly its fragments");
        var decoder = new VoBLEProtocol.AudioReassembler();
        int sequence = 0;
        for (byte[] notification : server.notifications) {
            check(notification.length <= 512, "Android attribute limit");
            for (int offset = 0; offset < notification.length;) {
                int end = offset + 18 + (notification[offset + 17] & 255);
                check(decoder.append(java.util.Arrays.copyOfRange(notification, offset, end), 0).sequence()
                        == sequence++, "batch order/integrity");
                offset = end;
            }
        }
        check(sequence == 4, "missing audio frame");
        // Client opt-out (including an old client starting a new session) restores v1.
        gatt.setAudioBatching(peer.getAddress(), false);
        int before = server.notifications.size();
        for (int i = 4; i < 8; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "legacy enqueue");
        for (int i = 0; i < 4; i++) callback.onNotificationSent(peer, 0);
        check(server.notifications.size() == before + 4, "legacy client received a batch");
        gatt.setAudioBatching(peer.getAddress(), true);
        callback.onMtuChanged(peer, 247);
        before = server.notifications.size();
        for (int i = 8; i < 12; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "small MTU enqueue");
        for (int i = 0; i < 4; i++) callback.onNotificationSent(peer, 0);
        check(server.notifications.size() == before + 4, "batch must fit negotiated MTU");
        // Failure of a batched notification removes all its fragments; no stale tail.
        callback.onMtuChanged(peer, 517);
        for (int i = 12; i < 16; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "failure enqueue");
        callback.onNotificationSent(peer, 0);
        callback.onNotificationSent(peer, 133);
        check(!gatt.notifyAudioPacket(peer.getAddress(), audio(16)), "batch error propagation");
        check(gatt.notifyAudioPacket(peer.getAddress(), audio(16)), "fresh frame after batch error");
        callback.onNotificationSent(peer, 0);
        callback.onConnectionStateChange(peer, 0, 0);
        callback.onConnectionStateChange(peer, 0, 2);
        channel.authenticate(peer.getAddress()); channel.subscribeAudio(peer.getAddress());
        callback.onMtuChanged(peer, 517);
        before = server.notifications.size();
        for (int i = 20; i < 24; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "reconnect enqueue");
        for (int i = 0; i < 4; i++) callback.onNotificationSent(peer, 0);
        check(server.notifications.size() == before + 4, "batch opt-in leaked across reconnect");
        gatt.setAudioBatching(peer.getAddress(), true);
        before = server.notifications.size();
        // Deterministic 20 ms source / 40 ms notification completion simulation.
        // No real radio timing claim: verify the software can sustain the cadence
        // that a single-frame notification queue cannot sustain.
        for (int i = 0; i < 100; i++) {
            check(gatt.notifyAudioPacket(peer.getAddress(), audio(30 + i)), "40ms callback cadence dropped a 20ms source frame");
            if (i % 2 == 1) callback.onNotificationSent(peer, 0);
        }
        for (int i = 0; i < 4; i++) callback.onNotificationSent(peer, 0);
        check(server.notifications.size() - before <= 52, "batching did not reduce radio notifications");
        int decoded = 0;
        for (byte[] notification : server.notifications.subList(before, server.notifications.size())) {
            for (int offset = 0; offset < notification.length;) {
                int end = offset + 18 + (notification[offset + 17] & 255);
                check(decoder.append(java.util.Arrays.copyOfRange(notification, offset, end), 0).sequence()
                        == 30 + decoded++, "cadence lost or reordered audio");
                offset = end;
            }
        }
        check(decoded == 100, "cadence incomplete");
        channel.subscribeControl(peer.getAddress());
        before = server.notifications.size();
        for (int i = 130; i < 134; i++) check(gatt.notifyAudioPacket(peer.getAddress(), audio(i)), "control boundary setup");
        check(gatt.indicateControl(peer.getAddress(), new byte[]{1, 2, 3}), "control enqueue");
        for (int i = 0; i < 4; i++) callback.onNotificationSent(peer, 0);
        check(server.notifications.size() == before + 4, "control merged into audio or lost");
        check((server.notifications.get(server.notifications.size() - 1)[0] & 255) == 0xd4,
                "control indication must retain independent framing");
        gatt.close();
    }

    private static VoBLEProtocol.AudioPacket audio(long sequence) {
        return new VoBLEProtocol.AudioPacket(0, VoBLEProtocol.CODEC_G711_MULAW, 1,
                sequence, sequence * 160, new byte[160], new byte[16]);
    }
    private static void check(boolean value,String message) { if(!value)throw new AssertionError(message); }
}
