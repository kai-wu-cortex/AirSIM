# VoBLE Bluetooth Call Design

## Purpose

VoBLE adds Bluetooth as an explicit AirSIM connection mode. In Bluetooth mode,
an iPhone controls calls on a paired Android phone and carries bidirectional call
audio over Bluetooth without requiring Wi-Fi, Relay, PushKit registration, an
internet connection, or VoWLAN configuration.

Bluetooth is not a dependency of VoWLAN and is not injected into the existing
Wi-Fi route. VoWLAN, Bluetooth, Cloud, and Automatic are separate user-selected
modes with independent lifecycles, pairing state, health, and errors.

## Success Criteria

- A paired iPhone can dial, answer, reject, hang up, mute, and send DTMF through
  Android while Wi-Fi and Relay are unavailable.
- Android downlink audio reaches iPhone and iPhone microphone audio reaches the
  Android call, with target one-way latency below 250 ms.
- Standalone PCM at `127.0.0.1:7580` and AVF PCM at the discovered AVF-private
  address on port `7580` use one Bluetooth media interface.
- An authenticated AirSIM pairing is distinct from a Bluetooth link connection;
  an unauthenticated device is never shown as ready.
- Explicit Bluetooth mode never silently falls back to VoWLAN or Cloud.
- Only Automatic mode selects among VoWLAN, Bluetooth, and Cloud before a call.
  The chosen transport remains locked for the call lifetime.
- Android call termination ends iPhone CallKit state, Live Activity, and Apple
  Watch ringing for the matching call generation.
- A 30-minute real-device call has no unbounded queues, increasing latency,
  thread leaks, or persistent audio loss.

## Non-Goals

- No Bluetooth PAN, Android internet sharing, DHCP, NAT, or system-wide iPhone
  network interface.
- No HFP Audio Gateway emulation, A2DP media path, Bluetooth Classic External
  Accessory protocol, or MFi dependency.
- Version 1 does not migrate an active call across Bluetooth, VoWLAN, and Cloud.
- Version 1 uses G.711 mu-law. Opus is a later negotiated codec.

## Top-Level Mode Model

```swift
enum AirSIMConnectionMode: String, Codable, CaseIterable {
    case vowlan
    case bluetooth
    case cloud
    case automatic
}
```

VoWLAN starts local-network discovery and uses signed HTTP plus TCP PCM without
starting Bluetooth. Bluetooth starts the iOS central and Android peripheral,
does not browse Bonjour, probe Wi-Fi, query Relay, or register PushKit solely to
be usable. Cloud uses Relay and PushKit without requiring BLE or VoWLAN.

Automatic is the only mode allowed to select another transport. Its initial
priority is VoWLAN, Bluetooth, Cloud. It selects before dial or answer and locks
that mode for the call. Explicit mode failure reports an error in that mode.

The dialer and call UI display Android device, phone number, selected mode, and
media readiness. GATT versus L2CAP remains an internal Bluetooth detail.

## Architecture

```text
Android Telecom / Agent call control
                |
  Standalone PCM or AVF PCM :7580
                |
     BluetoothGatewayService
       |                 |
  BLE control        BLE media
       |                 |
       +------ iPhone ---+
                  |
      BluetoothCallCoordinator
                  |
       CallKit + voice-processing audio
```

### Android Units

- `BluetoothGatewayService`: foreground-service lifecycle, BLE advertising,
  GATT server, and selected-mode activation.
- `BluetoothPairingManager`: application pairing, credentials, reconnect
  authentication, revocation, and one-active-central ownership.
- `BLEControlChannel`: framed reliable commands and indications.
- `BLEMediaSession`: media negotiation, framing, encryption, queues, and stats.
- `PCMBackendResolver`: Standalone loopback or current AVF-private endpoint.
- `PCMBridgeSession`: `AIRSIMPCM1\n` / `AIRSIMREADY` and bounded PCM pumps.
- `BluetoothCallController`: maps BLE commands to existing Agent/Telecom calls.
- `BluetoothDiagnostics`: non-sensitive readiness and media metrics.

### iOS Units

- `BluetoothModeController`: starts or stops Bluetooth for the selected mode.
- `BLECentralController`: discovery, connection, restoration, and subscription.
- `BluetoothPairingStore`: Keychain credentials and peer identity.
- `BLEControlChannel`: reliable command/response and Android events.
- `BluetoothGATTMediaTransport`: GATT audio framing and flow control.
- `BluetoothL2CAPMediaTransport`: optional negotiated Bluetooth media stream.
- `BluetoothCallCoordinator`: CallKit actions, call state, and media lifecycle.
- `BluetoothCallAudioEngine`: Voice Processing I/O, conversion, codec, and jitter.
- `BluetoothDiagnosticsStore`: UI-safe peer and media status.

`AppModel` remains UI orchestration but does not own BLE framing or audio queues.

## Pairing and Authentication

Bluetooth connection and OS bonding do not constitute AirSIM pairing:

1. Android advertises protocol version and peer identity without a secret.
2. Both peers generate ephemeral Curve25519 keys and random nonces.
3. Public keys are exchanged through the pairing characteristic.
4. ECDH plus HKDF derives a provisional confirmation key.
5. Both devices show the same six-digit short authentication string.
6. Confirmation derives independent pairing, control, media, and reconnect keys.
7. Android stores protected credentials and iOS stores them in Keychain.
8. Reconnect uses a fresh challenge and authenticated transcript.

No health response promotes a peer to authenticated. All readiness responses
after pairing are authenticated. Pair removal deletes and revokes credentials.
Version 1 permits one authenticated central to own call control at a time.

## BLE Service

| Characteristic | Direction | Property | Purpose |
| --- | --- | --- | --- |
| Capability | Android to iOS | Read, Notify | Version, peer, backend and codecs |
| Pairing | Bidirectional | Write, Indicate | Pairing and reconnect challenge |
| Control RX | iOS to Android | Write With Response | Call/media commands |
| Control TX | Android to iOS | Indicate | Responses and call events |
| Audio Uplink | iOS to Android | Write Without Response | Microphone frames |
| Audio Downlink | Android to iOS | Notify | Phone downlink frames |
| Diagnostics | Android to iOS | Read, Notify | Sanitized counters and readiness |

Each CCCD is tracked independently. Disabling audio notifications cannot disable
control indications and vice versa.

## Control Protocol and State

Control envelopes contain protocol version, request ID, session ID, call ID,
generation, sequence, operation, timestamp, nonce, body, and authentication tag.
Commands are `dial`, `answer`, `reject`, `hangup`, `dtmf`, `set_mute`,
`get_call_state`, `start_media`, `stop_media`, and `ping`. Events are `incoming`,
`dialing`, `ringing`, `connecting`, `active`, `held`, `ended`, `failed`,
`media_ready`, and `media_failed`.

Android caches recent request IDs. Repeated commands return the prior result
without repeating Telecom actions. Older generations cannot mutate a newer call.

```text
idle -> dialing | incoming -> ringing -> connecting
     -> mediaNegotiating -> active -> ending -> ended
```

`recovering` and `failed` are exceptional states. Every call owns a call ID,
generation, and media-session ID. Android is authoritative for terminal `ended`;
a matching event stops Bluetooth media and ends CallKit, Live Activity, and Watch
ringing immediately.

## PCM Backend and Startup

`PCMBackendResolver` maps Standalone to `127.0.0.1:7580` and AVF to the currently
discovered AVF-private address on port `7580`. Bluetooth does not hard-code
loopback for AVF or use the VoWLAN external PCM port as its internal destination.

Startup order:

1. Dial or answer reaches Android and the cellular call enters connecting/active.
2. iOS sends authenticated `start_media` with current call identity.
3. Android immediately resolves and connects the PCM backend.
4. Android sends `AIRSIMPCM1\n` and waits for `AIRSIMREADY`.
5. Android starts bounded uplink and downlink pumps.
6. Android publishes `media_ready` after both pumps can run.
7. iOS starts capture and playback after `media_ready` and CallKit activation.

PCM startup never waits for the first iPhone audio frame. Backend failure emits a
precise `media_failed` and does not invoke another top-level mode.

## Audio and Packet Format

The PCM boundary is 8-kHz mono signed-16-bit little-endian in 20-ms frames: 160
samples and 320 bytes. Bluetooth v1 encodes each frame as 160 bytes of G.711
mu-law, approximately 64 kbit/s before transport overhead.

Packet fields are magic, version, type, flags, codec, stream ID, 32-bit sequence,
32-bit sample timestamp, fragment index/count, payload length, payload, and a
16-byte authentication tag. Flags include start, end, silence, discontinuity,
and future FEC. Fragment metadata is mandatory when ATT cannot hold a full frame.

Each call derives a unique AEAD media key from pairing key, call ID, generation,
and media-session ID. A key/nonce pair cannot repeat across streams or reconnects.

## Flow Control and Jitter

iOS checks `canSendWriteWithoutResponse` and stops dequeuing until
`peripheralIsReady(toSendWriteWithoutResponse:)`. Android sends one downlink
notification at a time, checks the immediate result, and advances only from
`onNotificationSent`.

Control and media have separate bounded queues. Media queues hold no more than
eight 20-ms frames; overflow drops the oldest frame and marks discontinuity.
Control is never dropped and has explicit deadlines. Fragmentation supports the
actual Core Bluetooth write length, including MTU 23, 185, and 247 behavior.

The jitter buffer starts at four frames and adapts from three to eight frames.
Missing audio is not retransmitted; simple packet-loss concealment replays and
fades the preceding frame until the next complete frame.

## iOS Audio

`BluetoothCallAudioEngine` uses Voice Processing I/O for acoustic echo control,
noise suppression, and duplex operation. Capture converts the hardware rate to
8 kHz, frames 20 ms, encodes G.711, and sends uplink. Downlink passes through
authentication, reassembly, jitter, G.711 decode, and conversion to the hardware
rate. CallKit audio activation gates capture and playback. Receiver, speaker, or
iPhone-connected headset changes do not change the Android Bluetooth transport.

## Call Flows

Outgoing: CallKit start, authenticated Bluetooth readiness check, `dial`, Android
state events, `start_media`, PCM handshake, `media_ready`, CallKit audio
activation, full-duplex audio. No Relay query, Bonjour discovery, or Wi-Fi probe.

Incoming: Android allocates call identity and sends authenticated `incoming`;
iOS reports to CallKit; answer or reject travels over Bluetooth; answer performs
media startup. A matching Android terminal event ends all Apple presentation.

Hangup from either side stops media, closes PCM, clears jitter, ends CallKit, and
resumes normal background behavior. Repeated hangup is safe, and late media is
discarded.

## Background, Disconnect, and Recovery

iOS enables Bluetooth-central and audio background capabilities and implements
Core Bluetooth state restoration. It persists peripheral identity, restores
subscriptions, and reauthenticates before readiness. A suspended app may wake
for BLE events subject to iOS limits; a user-force-quit app cannot promise local
BLE incoming-call wake. Cloud is not silently enabled to hide this limitation.

Active-call disconnect silences capture/playback and keeps the Android call for
a three-second Bluetooth reconnection window. Recovery requires the same peer,
reauthentication, and a matching call ID/generation. Otherwise iOS ends CallKit
and applies the configured Android action, defaulting to hang up. Explicit
Bluetooth mode never changes to VoWLAN or Cloud during recovery.

## Observability and Privacy

Diagnostics include selected mode, authenticated peer, Agent type/version, PCM
backend readiness, codec, media transport, queue depth, sent/received frames,
incomplete fragments, dropped frames, estimated jitter, and categorized error.
Logs redact phone numbers, credentials, nonces, tags, and audio. PCM and encoded
audio are never stored.

## Verification

Unit tests cover mode isolation, Automatic-only selection, pairing/replay/revoke,
duplicate commands, stale generations, MTU fragmentation, bounded queues,
Standalone/AVF resolution, startup on `start_media`, Android-ended cleanup, and
same-generation disconnect restoration.

Real-device tests use iPhone Air, Samsung Standalone, Samsung AVF, and Xiaomi
HyperOS in foreground, background, lock screen, Wi-Fi off, Relay unavailable,
VPN transitions, power management, Apple Watch answer/reject, short Bluetooth
loss, interference/range, and a 30-minute full-duplex call.

Acceptance targets: reconnect under three seconds, dial response under 500 ms,
answer-to-first-audio under 1.5 seconds, target one-way latency under 250 ms,
normal continuous loss below one percent, and no unbounded resource growth.

## Delivery Sequence

1. Add explicit mode model and lifecycle isolation.
2. Define versioned Bluetooth protocol types and tests.
3. Implement authenticated pairing and readiness.
4. Implement Android BLE control and iOS coordination.
5. Resolve/open Standalone PCM on `start_media`.
6. Deliver downlink, then uplink, then full-duplex GATT audio.
7. Add flow control, fragmentation, encryption, and jitter handling.
8. Integrate outgoing/incoming CallKit and Apple Watch ending.
9. Add AVF backend resolution and recovery.
10. Complete background restoration and real-device verification.
11. Add optional L2CAP and later Opus after GATT v1 is stable.
