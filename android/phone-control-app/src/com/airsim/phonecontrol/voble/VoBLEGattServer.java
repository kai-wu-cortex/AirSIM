package com.airsim.phonecontrol.voble;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.ParcelUuid;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.ConcurrentHashMap;

public final class VoBLEGattServer implements AutoCloseable {
    public interface Listener {
        void onPairingWrite(String deviceId, byte[] value);
        void onControlWrite(String deviceId, byte[] value);
        void onAudioWrite(String deviceId, byte[] value);
        void onDisconnected(String deviceId);
    }

    public static final UUID SERVICE_UUID = UUID.fromString("7e57a000-7a17-4d9f-9a3c-41a17b1e0001");
    public static final UUID CAPABILITY_UUID = UUID.fromString("7e57a001-7a17-4d9f-9a3c-41a17b1e0001");
    public static final UUID PAIRING_UUID = UUID.fromString("7e57a002-7a17-4d9f-9a3c-41a17b1e0001");
    public static final UUID CONTROL_RX_UUID = UUID.fromString("7e57a003-7a17-4d9f-9a3c-41a17b1e0001");
    public static final UUID CONTROL_TX_UUID = UUID.fromString("7e57a004-7a17-4d9f-9a3c-41a17b1e0001");
    public static final UUID AUDIO_UPLINK_UUID = UUID.fromString("7e57a005-7a17-4d9f-9a3c-41a17b1e0001");
    public static final UUID AUDIO_DOWNLINK_UUID = UUID.fromString("7e57a006-7a17-4d9f-9a3c-41a17b1e0001");
    public static final UUID DIAGNOSTICS_UUID = UUID.fromString("7e57a007-7a17-4d9f-9a3c-41a17b1e0001");
    private static final UUID CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    private final Context context;
    private final Listener listener;
    private final VoBLEControlChannel channel;
    private final Map<String, BluetoothDevice> devices = new ConcurrentHashMap<>();
    private final Map<String, Integer> negotiatedMtus = new ConcurrentHashMap<>();
    private final Map<String, ArrayDeque<Outbound>> outbound = new ConcurrentHashMap<>();
    private final Set<String> sending = new HashSet<>();
    private final Set<String> notificationFailures = new HashSet<>();
    private final Map<String, VoBLEProtocol.MessageReassembler> inbound = new ConcurrentHashMap<>();
    private final AtomicInteger messageIds = new AtomicInteger();
    private BluetoothAdapter adapter;
    private BluetoothGattServer server;
    private BluetoothGattCharacteristic pairing;
    private BluetoothGattCharacteristic controlTx;
    private BluetoothGattCharacteristic audioDownlink;
    private BluetoothGattCharacteristic diagnostics;
    private AdvertiseCallback advertiseCallback;
    private long generation;

    private record Outbound(BluetoothGattCharacteristic characteristic, byte[] value, boolean confirm) {}

    public VoBLEGattServer(Context context, Listener listener, VoBLEControlChannel channel) {
        this.context = context.getApplicationContext();
        this.listener = listener;
        this.channel = channel;
    }

    @SuppressLint("MissingPermission")
    public synchronized boolean start() {
        if (!hasBluetoothPermissions()) return false;
        if (server != null) return true;
        BluetoothManager manager = context.getSystemService(BluetoothManager.class);
        adapter = manager == null ? null : manager.getAdapter();
        if (adapter == null || !adapter.isEnabled() || adapter.getBluetoothLeAdvertiser() == null) return false;
        long token = ++generation;
        server = manager.openGattServer(context, callback(token));
        if (server == null) return false;
        BluetoothGattService service = createService();
        if (!server.addService(service)) {
            close();
            return false;
        }
        return true;
    }

    @SuppressLint("MissingPermission")
    private synchronized void advertise(long token) {
        if (server == null || generation != token || advertiseCallback != null) return;
        AdvertiseSettings settings = new AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true).setTimeout(0).setTxPowerLevel(
                        AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).build();
        AdvertiseData data = new AdvertiseData.Builder()
                .setIncludeDeviceName(false).addServiceUuid(new ParcelUuid(SERVICE_UUID)).build();
        advertiseCallback = new AdvertiseCallback() {
            @Override public void onStartSuccess(AdvertiseSettings ignored) {
                if (isCurrent(token)) com.airsim.phonecontrol.BridgeLog.info("voble_gatt_advertising_ready");
            }
            @Override public void onStartFailure(int code) {
                synchronized (VoBLEGattServer.this) {
                    if (!isCurrent(token)) return;
                    com.airsim.phonecontrol.BridgeLog.info("voble_gatt_advertising_failed code=" + code);
                    close();
                }
            }
        };
        try {
            adapter.getBluetoothLeAdvertiser().startAdvertising(settings, data, advertiseCallback);
        } catch (RuntimeException error) {
            close();
            com.airsim.phonecontrol.BridgeLog.info("voble_gatt_advertising_exception type=" + error.getClass().getSimpleName());
        }
    }

    private synchronized boolean isCurrent(long token) { return server != null && generation == token; }

    public boolean hasBluetoothPermissions() {
        return Build.VERSION.SDK_INT < 31
                || (context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
                    == PackageManager.PERMISSION_GRANTED
                && context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
                    == PackageManager.PERMISSION_GRANTED);
    }

    @SuppressLint("MissingPermission")
    public boolean indicatePairing(String deviceId, byte[] value) {
        return enqueueMessage(deviceId, pairing, value, VoBLEProtocol.MESSAGE_PAIRING, true);
    }

    @SuppressLint("MissingPermission")
    public synchronized void disconnectPeer(String deviceId) {
        BluetoothDevice device = devices.get(deviceId);
        if (server != null && device != null && hasBluetoothPermissions()) {
            server.cancelConnection(device);
        }
    }

    @SuppressLint("MissingPermission")
    public boolean indicateControl(String deviceId, byte[] value) {
        return channel.isControlSubscribed(deviceId)
                && enqueueMessage(deviceId, controlTx, value, VoBLEProtocol.MESSAGE_CONTROL, true);
    }

    @SuppressLint("MissingPermission")
    public boolean notifyAudio(String deviceId, byte[] value) {
        return channel.isAudioSubscribed(deviceId) && enqueue(deviceId, audioDownlink, List.of(value), false);
    }

    @SuppressLint("MissingPermission")
    public synchronized boolean notifyAudioPacket(
            String deviceId, VoBLEProtocol.AudioPacket packet) {
        if (!channel.isAudioSubscribed(deviceId) || !devices.containsKey(deviceId)) return false;
        if (notificationFailures.remove(deviceId)) return false;
        ArrayDeque<Outbound> queue = outbound.get(deviceId);
        if (queue != null && queue.stream().anyMatch(
                value -> value.characteristic == audioDownlink)) return false;
        int packetLength = Math.max(23, negotiatedMtus.getOrDefault(deviceId, 23) - 3);
        List<byte[]> fragments = VoBLEProtocol.encodeAudioFragments(packet, packetLength);
        return enqueue(deviceId, audioDownlink, fragments, false);
    }

    @SuppressLint("MissingPermission")
    public void updateDiagnostics(byte[] value) {
        diagnostics.setValue(value);
        for (String deviceId : devices.keySet()) {
            enqueue(deviceId, diagnostics, List.of(value), false);
        }
    }

    private boolean enqueueMessage(String deviceId, BluetoothGattCharacteristic characteristic,
                                   byte[] value, int type, boolean confirm) {
        int packetLength = Math.max(20, negotiatedMtus.getOrDefault(deviceId, 23) - 3);
        int id = messageIds.updateAndGet(previous -> (previous + 1) & 0xffff);
        List<byte[]> fragments = VoBLEProtocol.encodeMessageFragments(value, packetLength, type, id);
        return enqueue(deviceId, characteristic, fragments, confirm);
    }

    private synchronized boolean enqueue(String deviceId, BluetoothGattCharacteristic characteristic,
                                         List<byte[]> values, boolean confirm) {
        if (!devices.containsKey(deviceId) || characteristic == null) return false;
        ArrayDeque<Outbound> queue = outbound.computeIfAbsent(deviceId, ignored -> new ArrayDeque<>());
        for (byte[] value : values) queue.add(new Outbound(characteristic, value.clone(), confirm));
        if (!sending.add(deviceId)) return true;
        return sendNext(deviceId);
    }

    private synchronized boolean sendNext(String deviceId) {
        ArrayDeque<Outbound> queue = outbound.get(deviceId);
        Outbound next = queue == null ? null : queue.peek();
        if (next == null) {
            sending.remove(deviceId);
            return true;
        }
        if (send(deviceId, next.characteristic, next.value, next.confirm)) return true;
        queue.poll();
        sending.remove(deviceId);
        return false;
    }

    @SuppressLint("MissingPermission")
    private boolean send(String deviceId, BluetoothGattCharacteristic characteristic,
                         byte[] value, boolean confirm) {
        BluetoothGattServer active = server;
        BluetoothDevice device = devices.get(deviceId);
        if (active == null || device == null || characteristic == null) return false;
        if (Build.VERSION.SDK_INT >= 33) {
            return active.notifyCharacteristicChanged(device, characteristic, confirm, value)
                    == BluetoothStatusCodes.SUCCESS;
        }
        characteristic.setValue(value);
        return active.notifyCharacteristicChanged(device, characteristic, confirm);
    }

    private BluetoothGattService createService() {
        BluetoothGattService service = new BluetoothGattService(
                SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY);
        BluetoothGattCharacteristic capability = characteristic(
                CAPABILITY_UUID, BluetoothGattCharacteristic.PROPERTY_READ
                        | BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ, true);
        capability.setValue("VoBLE/1;g711;control-auth-required".getBytes(StandardCharsets.UTF_8));
        pairing = characteristic(PAIRING_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE
                        | BluetoothGattCharacteristic.PROPERTY_INDICATE,
                BluetoothGattCharacteristic.PERMISSION_WRITE, true);
        BluetoothGattCharacteristic controlRx = characteristic(
                CONTROL_RX_UUID, BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE, false);
        controlTx = characteristic(CONTROL_TX_UUID,
                BluetoothGattCharacteristic.PROPERTY_INDICATE,
                BluetoothGattCharacteristic.PERMISSION_READ, true);
        BluetoothGattCharacteristic audioUplink = characteristic(
                AUDIO_UPLINK_UUID, BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE, false);
        audioDownlink = characteristic(AUDIO_DOWNLINK_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ, true);
        diagnostics = characteristic(DIAGNOSTICS_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ
                        | BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ, true);
        diagnostics.setValue("idle".getBytes(StandardCharsets.UTF_8));
        service.addCharacteristic(capability);
        service.addCharacteristic(pairing);
        service.addCharacteristic(controlRx);
        service.addCharacteristic(controlTx);
        service.addCharacteristic(audioUplink);
        service.addCharacteristic(audioDownlink);
        service.addCharacteristic(diagnostics);
        return service;
    }

    private static BluetoothGattCharacteristic characteristic(
            UUID uuid, int properties, int permissions, boolean cccd) {
        BluetoothGattCharacteristic value = new BluetoothGattCharacteristic(uuid, properties, permissions);
        if (cccd) value.addDescriptor(new BluetoothGattDescriptor(
                CCCD_UUID, BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
        return value;
    }

    private BluetoothGattServerCallback callback(long token) { return new BluetoothGattServerCallback() {
        @Override public void onServiceAdded(int status, BluetoothGattService service) {
            synchronized (VoBLEGattServer.this) {
                if (!isCurrent(token) || !SERVICE_UUID.equals(service.getUuid())) return;
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    com.airsim.phonecontrol.BridgeLog.info("voble_gatt_service_failed code=" + status);
                    close();
                    return;
                }
                com.airsim.phonecontrol.BridgeLog.info("voble_gatt_service_ready characteristics=" + service.getCharacteristics().size());
                advertise(token);
            }
        }
        @Override @SuppressLint("MissingPermission") public void onConnectionStateChange(
                BluetoothDevice device, int status, int newState) {
            if (!isCurrent(token)) return;
            String id = device.getAddress();
            if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                devices.put(id, device);
                negotiatedMtus.put(id, 23);
            } else {
                devices.remove(id);
                negotiatedMtus.remove(id);
                outbound.remove(id);
                inbound.keySet().removeIf(key -> key.startsWith(id + ":"));
                synchronized (VoBLEGattServer.this) { sending.remove(id); }
                channel.disconnect(id);
                listener.onDisconnected(id);
            }
        }

        @Override public void onMtuChanged(BluetoothDevice device, int mtu) {
            if (!isCurrent(token)) return;
            negotiatedMtus.put(device.getAddress(), Math.max(23, mtu));
        }

        @Override @SuppressLint("MissingPermission") public void onCharacteristicReadRequest(
                BluetoothDevice device, int requestId, int offset,
                BluetoothGattCharacteristic characteristic) {
            if (!isCurrent(token)) return;
            byte[] value = characteristic.getValue();
            if (value == null) value = new byte[0];
            if (offset < 0 || offset > value.length) {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null);
                return;
            }
            server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                    Arrays.copyOfRange(value, offset, value.length));
        }

        @Override @SuppressLint("MissingPermission") public void onCharacteristicWriteRequest(
                BluetoothDevice device, int requestId, BluetoothGattCharacteristic characteristic,
                boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            if (!isCurrent(token)) return;
            int status = preparedWrite || offset != 0 || value == null
                    ? BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED : BluetoothGatt.GATT_SUCCESS;
            if (status == BluetoothGatt.GATT_SUCCESS) {
                String id = device.getAddress();
                if (PAIRING_UUID.equals(characteristic.getUuid())) acceptMessage(
                        id, value, VoBLEProtocol.MESSAGE_PAIRING);
                else if (CONTROL_RX_UUID.equals(characteristic.getUuid())) acceptMessage(
                        id, value, VoBLEProtocol.MESSAGE_CONTROL);
                else if (AUDIO_UPLINK_UUID.equals(characteristic.getUuid())) listener.onAudioWrite(id, value.clone());
                else status = BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED;
            }
            if (responseNeeded) server.sendResponse(device, requestId, status, offset, null);
        }

        @Override public void onNotificationSent(BluetoothDevice device, int status) {
            if (!isCurrent(token)) return;
            String id = device.getAddress();
            synchronized (VoBLEGattServer.this) {
                ArrayDeque<Outbound> queue = outbound.get(id);
                Outbound completed = queue == null ? null : queue.poll();
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    if (queue != null && completed != null) {
                        BluetoothGattCharacteristic characteristic = completed.characteristic;
                        if (characteristic == audioDownlink) notificationFailures.add(id);
                        queue.removeIf(value -> value.characteristic == characteristic);
                    }
                    sending.remove(id);
                    return;
                }
                sendNext(id);
            }
        }

        @Override @SuppressLint("MissingPermission") public void onDescriptorWriteRequest(
                BluetoothDevice device, int requestId, BluetoothGattDescriptor descriptor,
                boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            if (!isCurrent(token)) return;
            int status = preparedWrite || offset != 0 || !CCCD_UUID.equals(descriptor.getUuid())
                    ? BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED : BluetoothGatt.GATT_SUCCESS;
            if (status == BluetoothGatt.GATT_SUCCESS) {
                boolean enabled = Arrays.equals(value, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                        || Arrays.equals(value, BluetoothGattDescriptor.ENABLE_INDICATION_VALUE);
                UUID owner = descriptor.getCharacteristic().getUuid();
                String id = device.getAddress();
                if (CONTROL_TX_UUID.equals(owner)) {
                    if (enabled) channel.subscribeControl(id); else channel.unsubscribeControl(id);
                } else if (AUDIO_DOWNLINK_UUID.equals(owner)) {
                    if (enabled) channel.subscribeAudio(id); else channel.unsubscribeAudio(id);
                }
                descriptor.setValue(value);
            }
            if (responseNeeded) server.sendResponse(device, requestId, status, offset, null);
        }
    }; }

    private void acceptMessage(String deviceId, byte[] fragment, int expectedType) {
        try {
            String key = deviceId + ":" + expectedType;
            VoBLEProtocol.Message message = inbound.computeIfAbsent(
                    key, ignored -> new VoBLEProtocol.MessageReassembler())
                    .append(fragment, System.currentTimeMillis());
            if (message == null || message.type() != expectedType) return;
            if (expectedType == VoBLEProtocol.MESSAGE_PAIRING) {
                listener.onPairingWrite(deviceId, message.payload());
            } else {
                listener.onControlWrite(deviceId, message.payload());
            }
        } catch (IllegalArgumentException ignored) {
            // Invalid or stale fragments never reach pairing/control dispatch.
        }
    }

    @Override @SuppressLint("MissingPermission") public synchronized void close() {
        ++generation;
        if (adapter != null && advertiseCallback != null && adapter.getBluetoothLeAdvertiser() != null) {
            adapter.getBluetoothLeAdvertiser().stopAdvertising(advertiseCallback);
        }
        advertiseCallback = null;
        if (server != null) server.close();
        server = null;
        devices.clear();
        negotiatedMtus.clear();
        outbound.clear();
        inbound.clear();
        sending.clear();
        notificationFailures.clear();
    }
}
