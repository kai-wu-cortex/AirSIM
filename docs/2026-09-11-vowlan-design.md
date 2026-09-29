# AirSIM VoWLAN Design

Date: 2026-09-11

## Goal

When an already paired iPhone is connected to the Samsung phone's hotspot, AirSIM must place and answer cellular calls through a local VoWLAN path. The control plane and bidirectional PCM remain on the hotspot LAN for the lifetime of that call. When VoWLAN is unavailable before a call begins, AirSIM uses the existing cloud Relay path.

The user-visible name is **VoWLAN**. The names `WLANECM` and `LANCalling` are retired from UI strings, logs, diagnostics, and newly introduced wire fields.

## Existing foundation

The current implementation already provides:

- Samsung hotspot operation and a reachable hotspot address;
- one-time Bonjour discovery under `_airsim-pair._tcp`;
- encrypted iPhone-to-Samsung pairing;
- Android-to-Agent authenticated control over the AVF-private network;
- Android Telecom call control;
- the shell-UID Samsung PCM bridge on the AVF-private address;
- working cloud Relay call control and bidirectional PCM.

Pairing discovery is not a VoWLAN transport. No call-control or PCM listener is currently exposed on the hotspot interface, and the iOS local API and PCM endpoints remain fixed to the QDC507 address `192.168.225.1`.

## Non-goals

- VoWLAN does not perform mid-call handover to or from the cloud Relay.
- VoWLAN does not expose the Linux Agent or shell PCM listener directly on Wi-Fi.
- VoWLAN does not replace PushKit/APNs as the background incoming-call wake-up mechanism.
- VoWLAN does not change carrier calling, Android Telecom ownership, or Samsung audio routing.
- VoWLAN does not allow an unpaired hotspot client to control calls or receive PCM.

## Architecture

The Android app owns a foreground `VoWLANGatewayService`. It binds two explicit listeners only to the active Samsung hotspot IPv4 address:

1. a restricted HTTP control gateway;
2. an authenticated PCM gateway.

The gateway never binds a wildcard, infrastructure Wi-Fi, cellular, USB, or AVF address. It stops its listeners when the hotspot interface disappears and republishes them when a valid hotspot interface returns.

The local data paths are:

```text
Control: iPhone -> Samsung hotspot control gateway -> AVF Linux Agent -> Android Telecom
Audio:   iPhone -> Samsung hotspot PCM gateway -> shell PCM bridge -> system call PCM
```

The Android gateway is a protocol-aware proxy, not a general TCP forwarder. It validates authentication, route allowlists, message sizes, timeouts, and the active peer before connecting to internal services.

## Pairing and authentication

The iPhone creates a random 256-bit VoWLAN secret during one-time pairing and stores it in Keychain. The secret is included inside the existing encrypted pairing registration, so it is never advertised through Bonjour, displayed in the confirmation code, or placed in a URL.

Android decrypts the registration in memory, stores only the material required to authenticate the paired iPhone in app-private storage, then zeroizes the plaintext as it does today. The Linux Agent continues receiving the Push/Relay registration and ignores no security decision made by the Android gateway.

Each VoWLAN control request carries:

- a protocol version;
- a Unix timestamp within a bounded clock window;
- a random nonce;
- an HMAC-SHA256 signature over method, path, body digest, timestamp, and nonce.

Android rejects invalid signatures, expired timestamps, repeated nonces, oversized requests, non-private peers, and routes outside the VoWLAN allowlist. The PCM connection uses an authenticated preface containing the version, timestamp, nonce, and HMAC before Android opens the internal `AIRSIMPCM1` connection. Secrets and raw PCM are never written to debug logs.

Re-pairing replaces the old VoWLAN secret. Removing the paired device deletes it from Android private storage and iOS Keychain.

## Discovery and availability

The existing `_airsim-pair._tcp` service remains limited to the two-minute pairing window. The foreground gateway separately advertises `_airsim-vowlan._tcp` while all of these conditions are true:

- Samsung hotspot interface is active;
- Android-to-Agent AVF health check passes;
- shell PCM listener health check passes;
- a VoWLAN pairing secret exists.

The TXT record contains only protocol version, stable non-secret device hint, current private hotspot host, control port, PCM port, and capability names. It contains no bearer token, HMAC secret, phone number, Relay credential, or call identifier.

iOS browses for VoWLAN while the app is active and when PushKit wakes it for an incoming call. It caches the last endpoint only as a hint and must complete a signed health request before declaring VoWLAN available.

## Android control gateway

The control gateway exposes the minimum routes needed by the current iOS call experience:

- health and capability status;
- call status and long-poll events;
- dial, answer, reject, hang up, and DTMF;
- audio-host warm-up, registration, configuration, and mute state.

All other Agent routes return `404`. In particular, VoWLAN cannot access debug clearing, arbitrary AT commands, updates, shutdown, SIM management, SMS content, router administration, or pairing registration.

After authenticating a request, Android forwards it to the Agent through the current AVF endpoint and injects the Android-to-Agent control credential. Client-supplied authorization headers are removed. Response bodies and status codes are bounded and forwarded without exposing internal AVF addresses.

## Android PCM gateway

After validating the VoWLAN PCM preface, Android opens the AVF-private shell PCM endpoint, performs the internal `AIRSIMPCM1` / `AIRSIMREADY` handshake, and returns a VoWLAN-ready acknowledgement to iOS. It then relays full-duplex 8 kHz mono PCM16LE in 320-byte frames.

Only one authenticated PCM client is permitted for the active call. The gateway closes both directions when either peer disconnects, when Android Telecom reports that the call ended, or when the hotspot interface disappears. It logs aggregate bytes, frames, peaks, timing, and closure reason, but never payload bytes.

## iOS transport selection

iOS introduces three explicit transport values:

- `vowlan`;
- `cloud`;
- `moduleLocal` for the existing QDC507 USB ECM path.

Before starting or answering each call, a pure selection policy evaluates a fresh VoWLAN signed health result, existing module-local reachability, the cloud-mode preference, and Relay availability. For the Samsung profile the priority is:

1. VoWLAN when the signed health check is fresh;
2. cloud Relay when enabled and online;
3. unavailable.

The chosen transport is stored in the call lifecycle and cannot change until that call ends. The iOS API client and `NetworkPCMTransport` receive endpoints from the chosen transport rather than using the hard-coded QDC507 host.

For outgoing calls, failure before Android accepts the dial command may fall back to cloud and start a new cloud attempt. Once dial is accepted, VoWLAN is locked and any subsequent hotspot loss ends the cellular call.

For incoming calls, PushKit continues to wake CallKit. On answer, iOS probes the discovered or cached VoWLAN endpoint. If it is authenticated and healthy, answer and PCM use VoWLAN; otherwise the call uses the cloud media URL from the Push payload. Once the answer command is accepted, the transport is locked.

## Disconnect behavior

VoWLAN deliberately has no mid-call migration. If control health, PCM TCP, Bonjour path viability, or the hotspot interface is lost during a VoWLAN call:

1. iOS marks the VoWLAN link failed and requests call termination if control remains reachable;
2. Android gateway closes PCM and asks Telecom to hang up when the authenticated peer disappears during an active VoWLAN call;
3. CallKit ends the local call UI;
4. the next call runs transport selection again and may use cloud Relay.

The disconnect reason is preserved in iOS, Android, and Agent diagnostics with a common trace ID. Neither side silently reconnects the same call over cloud.

## UI and diagnostics

Settings display a VoWLAN row with these states:

- `未配对`;
- `正在发现`;
- `已发现，正在验证`;
- `VoWLAN 就绪`;
- `通话中（VoWLAN）`;
- `热点已断开`;
- `已回退云端（下一通）`.

The in-call diagnostics identify the locked transport as `VoWLAN`, `Cloud`, or `Module Local`. New structured logs use component names beginning with `vowlan` and include discovery, authentication, selection, gateway forwarding, PCM milestones, byte/frame/peak counters, and disconnect reason. Logs redact HMAC values, VoWLAN secrets, phone-number content where not already authorized for call history, and all PCM payloads.

## Failure handling

- A stale Bonjour record never makes VoWLAN ready without a signed health response.
- A control request is never forwarded before authentication and route validation.
- PCM authentication failure never opens the internal shell bridge.
- Agent loss withdraws the VoWLAN advertisement and closes new control attempts.
- PCM bridge loss marks VoWLAN unavailable but leaves cloud calling available.
- Hotspot address changes recreate both listeners and republish Bonjour.
- Multiple hotspot clients cannot race for the active call; the first valid paired session owns it.
- Service restarts preserve the pairing secret but not active nonces, sockets, or calls.

## Testing

Android JVM tests cover hotspot-interface selection, listener binding policy, route allowlisting, request HMAC verification, timestamp windows, nonce replay rejection, PCM preface validation, single-client ownership, and disconnect cleanup.

Agent Go tests cover the restricted Android gateway routes used for Telecom and audio-host control without weakening existing Android control authentication.

iOS tests cover discovery parsing, signed health validation, Keychain-backed secret lifecycle, transport priority, per-call locking, outgoing pre-dial fallback, incoming Push selection, hotspot-loss termination, and the absence of mid-call cloud migration.

Physical-device verification covers:

1. iPhone on Samsung hotspot places and answers calls with both control and PCM on VoWLAN;
2. valid two-way speech and non-zero PCM peaks;
3. no Relay media WebSocket during a VoWLAN call;
4. hotspot disabled during a call ends that call;
5. the next call uses cloud Relay;
6. an unpaired hotspot client cannot call any gateway route or open PCM;
7. Android app, Linux Terminal, Agent, and shell bridge recovery after process and AVF restarts;
8. debug bundles contain lifecycle data but no secrets or PCM payloads.

## Rollout

VoWLAN is capability-gated. Existing cloud and QDC507 module-local behavior remain unchanged for devices that do not advertise the VoWLAN capability. Android gateway and iOS client versions must both support protocol version 1 before VoWLAN becomes selectable. A protocol mismatch withdraws VoWLAN and leaves cloud fallback available for the next call.
