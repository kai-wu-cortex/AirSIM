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

import com.airsim.phonecontrol.AndroidAgentIdentity;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.HashMap;
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
        default void onAdvertisingReady() {}
        default void onAdvertisingFailed(int code) {}
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
    private final Set<String> audioBatchPeers = new HashSet<>();
    private final Map<String, Integer> sentFragmentCounts = new HashMap<>();
    private final Map<String, AudioSendStats> audioSendStats = new HashMap<>();
    private static final class AudioSendStats {
        long attempts, accepted, queueFull, notSubscribed, previousFailure, sendRejected;
        long callbacks, callbackErrors, callbackNanos, maxCallbackNanos, callbacksOver40ms;
        long sentAtNanos, lastLogNanos;
        boolean audioInFlight;
        int lastStatus;
    }

    private AudioSendStats audioStats(String deviceId) {
        return audioSendStats.computeIfAbsent(deviceId, ignored -> new AudioSendStats());
    }

    public synchronized String audioSendSummary(String deviceId) {
        AudioSendStats s = audioSendStats.get(deviceId);
        if (s == null) return "available=false";
        return "attempts=" + s.attempts + " accepted=" + s.accepted + " queue_full=" + s.queueFull
                + " not_subscribed=" + s.notSubscribed + " previous_failure=" + s.previousFailure
                + " send_rejected=" + s.sendRejected + " callbacks=" + s.callbacks
                + " callback_errors=" + s.callbackErrors + " last_status=" + s.lastStatus
                + " callback_avg_ms=" + (s.callbacks == 0 ? 0 : s.callbackNanos / s.callbacks / 1_000_000)
                + " callback_max_ms=" + s.maxCallbackNanos / 1_000_000
                + " callbacks_over_40ms=" + s.callbacksOver40ms
                + " queued_fragments=" + (outbound.containsKey(deviceId) ? outbound.get(deviceId).size() : 0)
                + " in_flight=" + sending.contains(deviceId);
    }

    private void logAudioSendStats(String deviceId, AudioSendStats s) {
        long now = System.nanoTime();
        if (now - s.lastLogNanos < 2_000_000_000L) return;
        s.lastLogNanos = now;
        com.airsim.phonecontrol.BridgeLog.info("voble_send_stats " + audioSendSummary(deviceId));
    }
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
    private String previousAdapterName;
    private boolean adapterNameChanged;
    private boolean includeAdvertisedName = true;
    private long generation;

    // Up to 80 ms of audio, including the in-flight packet. Keep the next
    // frame queued so onNotificationSent can feed the stack immediately rather
    // than waiting for the PCM producer's 5 ms retry (which can miss a BLE event).
    private static final int MAX_QUEUED_AUDIO_FRAMES = 4;
    private record Outbound(BluetoothGattCharacteristic characteristic, byte[] value,
                            boolean confirm, boolean packetEnd) {}

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
        try {
            server = manager.openGattServer(context, callback(token));
            if (server == null) { failStart(-1); return false; }
            BluetoothGattService service = createService();
            if (!server.addService(service)) { failStart(-2); return false; }
            return true;
        } catch (RuntimeException error) {
            com.airsim.phonecontrol.BridgeLog.info("voble_gatt_start_exception type=" + error.getClass().getSimpleName());
            failStart(-3);
            return false;
        }
    }

    @SuppressLint("MissingPermission")
    private synchronized void advertise(long token) {
        if (server == null || generation != token || advertiseCallback != null) return;
        applyAdvertisingName();
        AdvertiseSettings settings = new AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true).setTimeout(0).setTxPowerLevel(
                        AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).build();
        AdvertiseData data = new AdvertiseData.Builder()
                .setIncludeDeviceName(includeAdvertisedName)
                .addServiceUuid(new ParcelUuid(SERVICE_UUID)).build();
        advertiseCallback = new AdvertiseCallback() {
            @Override public void onStartSuccess(AdvertiseSettings ignored) {
                if (isCurrent(token)) {
                    com.airsim.phonecontrol.BridgeLog.info("voble_gatt_advertising_ready");
                    listener.onAdvertisingReady();
                }
            }
            @Override public void onStartFailure(int code) {
                synchronized (VoBLEGattServer.this) {
                    if (!isCurrent(token)) return;
                    // Long model names plus the 128-bit service UUID can exceed
                    // the legacy 31-byte advertising limit. Keep VoBLE working
                    // by retrying without the name; the iOS scan then falls back
                    // to its cached name instead of losing the peripheral.
                    if (includeAdvertisedName && code == AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE) {
                        includeAdvertisedName = false;
                        advertiseCallback = null;
                        com.airsim.phonecontrol.BridgeLog.info("voble_gatt_advertising_name_too_large");
                        advertise(token);
                        return;
                    }
                    com.airsim.phonecontrol.BridgeLog.info("voble_gatt_advertising_failed code=" + code);
                    close();
                }
                listener.onAdvertisingFailed(code);
            }
        };
        try {
            adapter.getBluetoothLeAdvertiser().startAdvertising(settings, data, advertiseCallback);
        } catch (RuntimeException error) {
            com.airsim.phonecontrol.BridgeLog.info("voble_gatt_advertising_exception type=" + error.getClass().getSimpleName());
            failStart(-4);
        }
    }

    @SuppressLint("MissingPermission")
    private synchronized void applyAdvertisingName() {
        if (adapter == null || adapterNameChanged) return;
        String model = advertisingName();
        if (model.isEmpty()) return;
        try {
            String current = adapter.getName();
            if (model.equals(current)) return;
            previousAdapterName = current;
            if (adapter.setName(model)) {
                adapterNameChanged = true;
                com.airsim.phonecontrol.BridgeLog.info("voble_adapter_name_set name=" + model);
            }
        } catch (SecurityException error) {
            com.airsim.phonecontrol.BridgeLog.info("voble_adapter_name_rejected");
        }
    }

    /**
     * A 128-bit service UUID (18 bytes) and flags leave only eight bytes for the
     * GAP name in a legacy advertising packet. Prefer Build.MODEL and compact it
     * rather than falling back to a nameless advertisement and the iPhone's
     * cached "AirSIM Android" label.
     */
    private static String advertisingName() {
        String model = Build.MODEL == null ? "" : Build.MODEL.trim();
        if (model.isEmpty()) model = AndroidAgentIdentity.deviceName();
        model = model.replaceAll("[\\s\\u00A0]+", " ").trim();
        if (model.length() > 8) model = model.substring(0, 8).trim();
        return model;
    }

    @SuppressLint("MissingPermission")
    private synchronized void restoreAdvertisingName() {
        if (!adapterNameChanged || adapter == null) return;
        String previous = previousAdapterName;
        previousAdapterName = null;
        adapterNameChanged = false;
        if (previous == null || previous.isEmpty()) return;
        try {
            if (adapter.isEnabled() && adapter.setName(previous)) {
                com.airsim.phonecontrol.BridgeLog.info("voble_adapter_name_restored");
            }
        } catch (RuntimeException ignored) {
            com.airsim.phonecontrol.BridgeLog.info("voble_adapter_name_restore_rejected");
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
        AudioSendStats stats = audioStats(deviceId);
        logAudioSendStats(deviceId, stats);
        stats.attempts++;
        if (!channel.isAudioSubscribed(deviceId) || !devices.containsKey(deviceId)) {
            stats.notSubscribed++; return false;
        }
        if (notificationFailures.remove(deviceId)) { stats.previousFailure++; return false; }
        ArrayDeque<Outbound> queue = outbound.get(deviceId);
        if (queue != null && queue.stream().filter(
                value -> value.characteristic == audioDownlink && value.packetEnd).count()
                >= MAX_QUEUED_AUDIO_FRAMES) { stats.queueFull++; return false; }
        int packetLength = Math.max(23, negotiatedMtus.getOrDefault(deviceId, 23) - 3);
        List<byte[]> fragments = VoBLEProtocol.encodeAudioFragments(packet, packetLength);
        boolean accepted = enqueue(deviceId, audioDownlink, fragments, false);
        if (accepted) stats.accepted++;
        return accepted;
    }

    // Called only after authenticated media-start admission. Old clients never
    // opt in and continue receiving one protocol fragment per ATT notification.
    public synchronized void setAudioBatching(String deviceId, boolean enabled) {
        audioSendStats.put(deviceId, new AudioSendStats());
        if (enabled && devices.containsKey(deviceId)) audioBatchPeers.add(deviceId);
        else audioBatchPeers.remove(deviceId);
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
        // Android's notification attribute is capped at 512 bytes even when the
        // negotiated MTU is larger. 514 failed with "notification should not be
        // longer..."; 512 fits and keeps a 4 KB response to a few fragments instead
        // of hundreds of 20-byte indications that exceed the iPhone command timeout.
        int packetLength = Math.min(512,
                Math.max(VoBLEProtocol.MESSAGE_HEADER_LENGTH + 4,
                        negotiatedMtus.getOrDefault(deviceId, 23) - 3));
        int id = messageIds.updateAndGet(previous -> (previous + 1) & 0xffff);
        List<byte[]> fragments = VoBLEProtocol.encodeMessageFragments(value, packetLength, type, id);
        return enqueue(deviceId, characteristic, fragments, confirm);
    }

    private synchronized boolean enqueue(String deviceId, BluetoothGattCharacteristic characteristic,
                                         List<byte[]> values, boolean confirm) {
        if (!devices.containsKey(deviceId) || characteristic == null) return false;
        ArrayDeque<Outbound> queue = outbound.computeIfAbsent(deviceId, ignored -> new ArrayDeque<>());
        for (int index = 0; index < values.size(); index++) {
            queue.add(new Outbound(characteristic, values.get(index).clone(), confirm,
                    index == values.size() - 1));
        }
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
        byte[] value = next.value;
        int count = 1;
        if (next.characteristic == audioDownlink && !next.confirm && audioBatchPeers.contains(deviceId)) {
            int limit = Math.min(512, negotiatedMtus.getOrDefault(deviceId, 23) - 3);
            var batch = new java.io.ByteArrayOutputStream();
            count = 0;
            for (Outbound part : queue) {
                if (part.characteristic != audioDownlink || part.confirm
                        || batch.size() + part.value.length > limit) break;
                batch.write(part.value, 0, part.value.length);
                count++;
            }
            if (count > 0) value = batch.toByteArray();
            else count = 1;
        }
        sentFragmentCounts.put(deviceId, count);
        AudioSendStats stats = audioStats(deviceId);
        stats.audioInFlight = next.characteristic == audioDownlink;
        stats.sentAtNanos = System.nanoTime();
        if (send(deviceId, next.characteristic, value, next.confirm)) return true;
        if (stats.audioInFlight) stats.sendRejected++;
        stats.audioInFlight = false;
        sentFragmentCounts.remove(deviceId);
        for (int i = 0; i < count; i++) queue.poll();
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
                    failStart(status);
                    return;
                }
                com.airsim.phonecontrol.BridgeLog.info("voble_gatt_service_ready characteristics=" + service.getCharacteristics().size());
                advertise(token);
            }
        }
        @Override @SuppressLint("MissingPermission") public void onConnectionStateChange(
                BluetoothDevice device, int status, int newState) {
            synchronized (VoBLEGattServer.this) {
                if (!isCurrent(token)) return;
                com.airsim.phonecontrol.BridgeLog.info("voble_gatt_connection status=" + status
                        + " state=" + newState);
                String id = device.getAddress();
                if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                    // One iPhone must own at most one GATT connection. A rotated BLE
                    // address or a stale session otherwise leaves control subscribed on
                    // one link while responses are queued on another.
                    for (Map.Entry<String, BluetoothDevice> entry :
                            new java.util.ArrayList<>(devices.entrySet())) {
                        if (entry.getKey().equals(id)) continue;
                        com.airsim.phonecontrol.BridgeLog.info("voble_gatt_stale_connection_closed");
                        devices.remove(entry.getKey());
                        negotiatedMtus.remove(entry.getKey());
                        outbound.remove(entry.getKey());
                        sending.remove(entry.getKey());
                        sentFragmentCounts.remove(entry.getKey());
                        audioBatchPeers.remove(entry.getKey());
                        audioSendStats.remove(entry.getKey());
                        inbound.keySet().removeIf(key -> key.startsWith(entry.getKey() + ":"));
                        channel.disconnect(entry.getKey());
                        server.cancelConnection(entry.getValue());
                    }
                    devices.put(id, device);
                    negotiatedMtus.put(id, 23);
                } else {
                    devices.remove(id);
                    negotiatedMtus.remove(id);
                    outbound.remove(id);
                    sentFragmentCounts.remove(id);
                    audioBatchPeers.remove(id);
                    audioSendStats.remove(id);
                    inbound.keySet().removeIf(key -> key.startsWith(id + ":"));
                    synchronized (VoBLEGattServer.this) { sending.remove(id); }
                    channel.disconnect(id);
                    listener.onDisconnected(id);
                }
            }
        }

        @Override public void onMtuChanged(BluetoothDevice device, int mtu) {
            if (!isCurrent(token)) return;
            com.airsim.phonecontrol.BridgeLog.info("voble_gatt_mtu mtu=" + mtu);
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
            synchronized (VoBLEGattServer.this) {
                if (!isCurrent(token)) return;
                int status = preparedWrite || offset != 0 || value == null
                        ? BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED : BluetoothGatt.GATT_SUCCESS;
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    String id = device.getAddress();
                    com.airsim.phonecontrol.BridgeLog.info("voble_gatt_write bytes="
                            + (value == null ? 0 : value.length));
                    if (PAIRING_UUID.equals(characteristic.getUuid())) acceptMessage(
                            id, value, VoBLEProtocol.MESSAGE_PAIRING);
                    else if (CONTROL_RX_UUID.equals(characteristic.getUuid())) acceptMessage(
                            id, value, VoBLEProtocol.MESSAGE_CONTROL);
                    else if (AUDIO_UPLINK_UUID.equals(characteristic.getUuid())) listener.onAudioWrite(id, value.clone());
                    else status = BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED;
                }
                if (responseNeeded) server.sendResponse(device, requestId, status, offset, null);
            }
        }

        @Override public void onNotificationSent(BluetoothDevice device, int status) {
            if (!isCurrent(token)) return;
            String id = device.getAddress();
            synchronized (VoBLEGattServer.this) {
                ArrayDeque<Outbound> queue = outbound.get(id);
                Outbound completed = queue == null ? null : queue.peek();
                AudioSendStats stats = audioStats(id);
                if (stats.audioInFlight) {
                    long elapsed = Math.max(0, System.nanoTime() - stats.sentAtNanos);
                    stats.callbacks++; stats.callbackNanos += elapsed;
                    stats.maxCallbackNanos = Math.max(stats.maxCallbackNanos, elapsed);
                    if (elapsed > 40_000_000L) stats.callbacksOver40ms++;
                    if (status != BluetoothGatt.GATT_SUCCESS) stats.callbackErrors++;
                    stats.lastStatus = status;
                    stats.audioInFlight = false;
                }
                int count = sentFragmentCounts.getOrDefault(id, 0);
                sentFragmentCounts.remove(id);
                if (queue != null) for (int i = 0; i < count; i++) queue.poll();
                if (completed != null && completed.characteristic == controlTx) {
                    com.airsim.phonecontrol.BridgeLog.info(
                            "voble_control_indication status=" + status);
                }
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
            synchronized (VoBLEGattServer.this) {
                if (!isCurrent(token)) return;
                int status = preparedWrite || offset != 0 || !CCCD_UUID.equals(descriptor.getUuid())
                        ? BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED : BluetoothGatt.GATT_SUCCESS;
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    boolean enabled = Arrays.equals(value, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                            || Arrays.equals(value, BluetoothGattDescriptor.ENABLE_INDICATION_VALUE);
                    UUID owner = descriptor.getCharacteristic().getUuid();
                    String id = device.getAddress();
                    com.airsim.phonecontrol.BridgeLog.info("voble_gatt_subscription channel="
                            + (CONTROL_TX_UUID.equals(owner) ? "control" : "audio")
                            + " enabled=" + enabled);
                    if (CONTROL_TX_UUID.equals(owner)) {
                        if (enabled) channel.subscribeControl(id); else channel.unsubscribeControl(id);
                    } else if (AUDIO_DOWNLINK_UUID.equals(owner)) {
                        if (enabled) channel.subscribeAudio(id); else channel.unsubscribeAudio(id);
                    }
                    descriptor.setValue(value);
                }
                if (responseNeeded) server.sendResponse(device, requestId, status, offset, null);
            }
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

    private void failStart(int code) {
        close();
        listener.onAdvertisingFailed(code);
    }

    @Override @SuppressLint("MissingPermission") public synchronized void close() {
        ++generation;
        // Fence callbacks before closing, then retire all ownership ourselves:
        // callbacks from the old server are intentionally ignored after this point.
        var peers = new java.util.HashSet<>(devices.keySet());
        peers.addAll(channel.disconnectAll());
        BluetoothGattServer previousServer = server;
        AdvertiseCallback previousAdvertise = advertiseCallback;
        server = null;
        advertiseCallback = null;
        devices.clear();
        negotiatedMtus.clear();
        outbound.clear();
        inbound.clear();
        sending.clear();
        sentFragmentCounts.clear();
        audioBatchPeers.clear();
        audioSendStats.clear();
        notificationFailures.clear();
        includeAdvertisedName = true;
        try {
            if (adapter != null && previousAdvertise != null && adapter.getBluetoothLeAdvertiser() != null) {
                adapter.getBluetoothLeAdvertiser().stopAdvertising(previousAdvertise);
            }
        } catch (RuntimeException error) {
            com.airsim.phonecontrol.BridgeLog.info("voble_gatt_stop_advertising_exception type=" + error.getClass().getSimpleName());
        }
        restoreAdvertisingName();
        try {
            if (previousServer != null) previousServer.close();
        } catch (RuntimeException error) {
            com.airsim.phonecontrol.BridgeLog.info("voble_gatt_close_exception type=" + error.getClass().getSimpleName());
        }
        for (String peer : peers) listener.onDisconnected(peer);
    }
}
