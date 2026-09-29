# AirSIM Samsung Phone Audio Bridge

This shell-UID Android service exposes the Samsung cellular call audio path through the legacy DJOneHub module PCM contract:

- cellular remote party to Relay: `AudioRecord.VOICE_DOWNLINK`
- Relay/iOS microphone to cellular remote party: `USAGE_VOICE_COMMUNICATION` plus Samsung tag `VOICE_TX`
- transport: `DJ1PCM1\n` / `DJ1READY`, then full-duplex 8 kHz mono PCM16LE
- Relay frame: 320 bytes / 20 ms

The bridge never stores PCM. JSONL logs contain lifecycle, route, aggregate byte/frame/peak counts, and errors only.

## Build

```sh
./android/phone-audio-bridge/build.sh
```

## Development-phone lifecycle

The listener must use Android's AVF-private interface, not Wi-Fi, hotspot, cellular, or a wildcard address. Resolve it on every VM boot:

```sh
adb -s DEVICE shell 'ip -o -4 addr show avf_tap_fixed'
ssh -p 2222 droid@127.0.0.1 'ip route'
```

Start and inspect the bridge:

```sh
ADB=/path/to/adb ADB_SERIAL=DEVICE LISTEN_HOST=AVF_ANDROID_IP \
  ./android/phone-audio-bridge/run-device-bridge.sh start
ADB=/path/to/adb ADB_SERIAL=DEVICE \
  ./android/phone-audio-bridge/run-device-bridge.sh status
ADB=/path/to/adb ADB_SERIAL=DEVICE \
  ./android/phone-audio-bridge/run-device-bridge.sh logs
```

The runner rejects unrecognized and externally reachable interfaces. It starts with `nohup`, but Android may still reclaim a shell process. Samsung Terminal may also release the AVF VM when its process loses the VM reference. Until the thin Android control app/watchdog exists, a paired development host must detect and restart both layers.

## Linux Agent

Install the systemd drop-in after replacing `AVF_ANDROID_IP` with the current private address:

```ini
[Service]
Environment=DJONEHUB_VOICE_BACKEND=samsung_android
Environment=DJONEHUB_SAMSUNG_PCM_ADDRESS=AVF_ANDROID_IP:7580
```

Run the backend handshake probe before restarting the service:

```sh
DJONEHUB_RUNTIME_PROFILE=android-avf \
DJONEHUB_VOICE_BACKEND=samsung_android \
DJONEHUB_SAMSUNG_PCM_ADDRESS=AVF_ANDROID_IP:7580 \
/usr/local/bin/djonehub-agent --startup-probe voice-backend
```

The Agent health response reports `voice_backend=samsung_android` and `call_audio=true` but does not expose the configured private endpoint.

## Verified boundary

The Android audio capability and Agent-to-bridge handshake are verified. A real Relay/iOS speech call still requires the Android Telecom control plane to publish call state and execute answer/reject/hangup. Do not claim automatic silent incoming calls or 10-second local failover from this media component alone.
