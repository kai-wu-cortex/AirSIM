# VoBLE Bluetooth Call Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-selected Bluetooth mode that performs authenticated Android call control and bidirectional G.711 call audio over BLE without depending on Wi-Fi, Relay, or VoWLAN.

**Architecture:** Keep VoWLAN, Bluetooth, Cloud, and Automatic as isolated top-level modes. Add an Android BLE foreground gateway backed by the existing Standalone/AVF PCM interface, plus an iOS Core Bluetooth control/media stack and CallKit coordinator. Version 1 ships reliable GATT audio; L2CAP and Opus remain negotiated protocol extensions outside this plan.

**Tech Stack:** Swift 5, SwiftUI, CoreBluetooth, CryptoKit, CallKit, AVFAudio/AudioToolbox, Java 17, Android BluetoothGattServer, Android Keystore/JCA, existing AirSIM PCM protocol, XCTest, JVM tests, real iPhone/Samsung/Xiaomi validation.

**Spec:** `docs/superpowers/specs/2026-10-12-voble-bluetooth-call-design.md`

## Global Constraints

- Explicit Bluetooth mode must not browse VoWLAN, query Relay, register PushKit for Bluetooth readiness, or silently fall back across modes.
- Automatic is the only mode that may select another transport, and selection is locked for the call lifetime.
- Bluetooth link connection is not AirSIM authentication; readiness requires the application challenge to pass.
- Version 1 media is G.711 mu-law, 8-kHz mono, 20-ms frames, over BLE GATT.
- Standalone PCM is `127.0.0.1:7580`; AVF PCM is the discovered AVF-private address on port `7580`.
- PCM starts on authenticated `start_media`, never on receipt of the first microphone frame.
- Audio/control queues are bounded; stale generations and late audio cannot mutate the current call.
- Existing unstaged files predate VoBLE. Preserve their edits, inspect overlapping hunks, and stage only task-owned paths in each commit.
- Deployment floors remain iOS 16.3, watchOS 10, Android API 29, and Java 17.

## Review Focus

- A BLE link with a wrong or missing application key must remain connected-but-unpaired and reject control/media.
- Explicit Bluetooth failure must never trigger VoWLAN discovery or a cloud command.
- MTU 23 fragmentation, queue saturation, and dropped notification callbacks must bound latency instead of growing memory.
- Android terminal `ended` for the matching generation must close CallKit, Live Activity, Watch ringing, PCM, and BLE media exactly once.
- AVF address changes and a three-second BLE reconnect must never attach media to a different call generation.

---

### Task 1: Persisted Mode Selection and Lifecycle Isolation

**Files:**
- Create: `iOS/AirSIM/ConnectionModePreference.swift`
- Modify: `iOS/AirSIM/VoIPPushController.swift`
- Modify: `iOS/AirSIM/AirSIMSetupView.swift`
- Modify: `iOS/AirSIM/AppModel.swift`
- Modify: `iOS/AirSIM/BackgroundStandbyController.swift`
- Modify: `iOS/AirSIM.xcodeproj/project.pbxproj`
- Test: `iOS/AirSIMTests/AirSIMTests.swift`

**Interfaces:**
- Produces: `AirSIMConnectionMode`, `ConnectionModePreference.selected(defaults:)`, `ConnectionModeRuntimePolicy`.
- Consumes: existing `LocalModePreference`, `CloudModePreference`, VoWLAN browsing, PushKit registration, and background standby entry points.

- [x] **Step 1: Add failing mode-policy tests**

```swift
func testExplicitBluetoothModeDisablesUnrelatedLifecycles() {
    let policy = ConnectionModeRuntimePolicy(mode: .bluetooth)
    XCTAssertTrue(policy.startsBluetooth)
    XCTAssertFalse(policy.startsVoWLAN)
    XCTAssertFalse(policy.startsCloud)
    XCTAssertFalse(policy.allowsCrossModeFallback)
}

func testOnlyAutomaticAllowsCrossModeSelection() {
    XCTAssertTrue(ConnectionModeRuntimePolicy(mode: .automatic).allowsCrossModeFallback)
    for mode in [AirSIMConnectionMode.vowlan, .bluetooth, .cloud] {
        XCTAssertFalse(ConnectionModeRuntimePolicy(mode: mode).allowsCrossModeFallback)
    }
}
```

- [x] **Step 2: Run the focused XCTest target and verify the new symbols fail to compile**

Run:

```bash
xcodebuild test -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air,OS=27.0' \
  -only-testing:AirSIMTests
```

Expected: failure because `ConnectionModeRuntimePolicy` is undefined.

- [x] **Step 3: Implement the mode preference and pure runtime policy**

```swift
enum AirSIMConnectionMode: String, Codable, CaseIterable, Sendable {
    case vowlan, bluetooth, cloud, automatic
}

struct ConnectionModeRuntimePolicy: Equatable, Sendable {
    let mode: AirSIMConnectionMode
    var startsVoWLAN: Bool { mode == .vowlan || mode == .automatic }
    var startsBluetooth: Bool { mode == .bluetooth || mode == .automatic }
    var startsCloud: Bool { mode == .cloud || mode == .automatic }
    var allowsCrossModeFallback: Bool { mode == .automatic }
}
```

Rename the current online presentation enum so it cannot be confused with the persisted selection. Convert the existing local/cloud toggles into compatibility accessors backed by the selected mode. Add a four-option settings picker and route lifecycle start/stop through the pure policy.

- [x] **Step 4: Run XCTest and verify all existing local/cloud compatibility tests pass**

Run the command from Step 2. Expected: PASS.

- [x] **Step 5: Commit only mode-owned paths**

```bash
git add iOS/AirSIM/ConnectionModePreference.swift iOS/AirSIM/VoIPPushController.swift \
  iOS/AirSIM/AirSIMSetupView.swift iOS/AirSIM/AppModel.swift \
  iOS/AirSIM/BackgroundStandbyController.swift iOS/AirSIM.xcodeproj/project.pbxproj \
  iOS/AirSIMTests/AirSIMTests.swift
git commit -m "feat: add isolated AirSIM connection modes"
```

### Task 2: Versioned Wire Protocol and Bounded Media Primitives

**Files:**
- Create: `iOS/AirSIM/VoBLEProtocol.swift`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEProtocol.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEAudioQueue.java`
- Modify: `iOS/AirSIM.xcodeproj/project.pbxproj`
- Modify: `android/phone-control-app/test/com/airsim/phonecontrol/CoreTests.java`
- Modify: `android/phone-control-app/test.sh`
- Test: `iOS/AirSIMTests/AirSIMTests.swift`

**Interfaces:**
- Produces: `VoBLEControlEnvelope`, `VoBLEAudioPacket`, `VoBLEAudioReassembler`, Java `VoBLEProtocol.ControlEnvelope`, `AudioHeader`, and bounded queue behavior.
- Consumes: call ID, generation, session ID, and HMAC/AEAD byte arrays supplied by pairing tasks.

- [x] **Step 1: Add cross-language protocol-vector tests**

Use this fixed audio vector in Swift and Java tests:

```text
stream=7 sequence=0x01020304 timestamp=0x05060708
fragment=0/1 codec=g711 payload=00 7f 80 ff
```

Assert encoded header fields, payload length, and round-trip equality. Add MTU 23, 185, and 247 fragmentation tests and an eight-frame bounded queue test that drops sequence 1 when sequence 9 arrives.

- [x] **Step 2: Run XCTest and JVM tests and verify missing protocol types fail**

```bash
./android/phone-control-app/test.sh
xcodebuild test -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air,OS=27.0' \
  -only-testing:AirSIMTests
```

- [x] **Step 3: Implement exact big-endian framing, validation, fragmentation, reassembly, and queue bounds**

Reject bad magic/version, payload length beyond the packet, fragment index at or above count, more than 64 fragments, and completed payloads above 512 bytes. Expire incomplete frames after 200 ms. Mark discontinuity after overflow or expiration.

- [x] **Step 4: Run both suites and verify vectors match**

Expected: PASS with identical serialized bytes in Swift and Java.

- [x] **Step 5: Commit protocol paths**

```bash
git add iOS/AirSIM/VoBLEProtocol.swift iOS/AirSIM.xcodeproj/project.pbxproj \
  iOS/AirSIMTests/AirSIMTests.swift android/phone-control-app/src/com/airsim/phonecontrol/voble \
  android/phone-control-app/test/com/airsim/phonecontrol/CoreTests.java \
  android/phone-control-app/test.sh
git commit -m "feat: define VoBLE control and audio protocol"
```

### Task 3: Application Pairing, Session Authentication, and Replay Protection

**Files:**
- Create: `iOS/AirSIM/VoBLEPairing.swift`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEPairingManager.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLECredentialStore.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEReplayWindow.java`
- Modify: `iOS/AirSIM.xcodeproj/project.pbxproj`
- Modify: `android/phone-control-app/test.sh`
- Modify: `android/phone-control-app/test/com/airsim/phonecontrol/CoreTests.java`
- Test: `iOS/AirSIMTests/AirSIMTests.swift`

**Interfaces:**
- Produces: `VoBLEPairingStore`, `VoBLESessionAuthenticator`, `VoBLEPairingManager.begin/confirm/authenticate`, derived control/media keys.
- Consumes: peer identity, ephemeral Curve25519 public keys, transcript nonces, Android protected preferences, iOS Keychain.

- [x] **Step 1: Add deterministic cryptographic transcript tests**

Use fixed private keys and nonces to assert both languages derive the same 32-byte pairing key and six-digit SAS. Add wrong-key, modified-transcript, duplicate-nonce, expired timestamp, revoked-peer, and reconnect-session key-separation tests.

- [x] **Step 2: Run tests and verify pairing APIs are absent**

Use both commands from Task 2 Step 2. Expected: FAIL.

- [x] **Step 3: Implement X25519, HKDF-SHA256, transcript confirmation, secure persistence, and replay window**

The transcript is length-prefixed protocol version, Android identity, both public keys, and both 32-byte nonces. Derive labeled keys `pairing`, `control`, `media`, and `reconnect`. Store no ephemeral private key after confirmation. Redact all key material from descriptions and logs.

- [x] **Step 4: Run both suites and verify all negative authentication cases pass**

- [x] **Step 5: Commit pairing paths**

```bash
git add iOS/AirSIM/VoBLEPairing.swift iOS/AirSIM.xcodeproj/project.pbxproj \
  iOS/AirSIMTests/AirSIMTests.swift android/phone-control-app/src/com/airsim/phonecontrol/voble \
  android/phone-control-app/test.sh android/phone-control-app/test/com/airsim/phonecontrol/CoreTests.java
git commit -m "feat: add authenticated VoBLE pairing"
```

### Task 4: Android BLE Foreground Gateway and Call Control

**Files:**
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEGatewayService.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEGattServer.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEControlChannel.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLECallController.java`
- Modify: `android/phone-control-app/AndroidManifest.xml`
- Modify: `android/phone-control-app/src/com/airsim/phonecontrol/BridgeApplication.java`
- Modify: `android/phone-control-app/src/com/airsim/phonecontrol/AirSIMInCallService.java`
- Modify: `android/phone-control-app/test.sh`
- Modify: `android/phone-control-app/test/com/airsim/phonecontrol/CoreTests.java`

**Interfaces:**
- Produces: the AirSIM BLE service, independent CCCD state, authenticated command dispatch, and call-state indications.
- Consumes: Task 2 framing, Task 3 authentication, existing `AgentClient`, `StandaloneAgentGateway`, and call repository events.

- [x] **Step 1: Add pure call-controller and subscription tests**

Assert unauthenticated health cannot become ready, wrong-key dial returns authentication failure, duplicate request ID invokes the fake call gateway once, stale generation is rejected, audio CCCD removal preserves control, and matching `ended` emits once.

- [x] **Step 2: Run JVM tests and verify failures**

```bash
./android/phone-control-app/test.sh
```

- [x] **Step 3: Implement foreground service, GATT database, serialized control queue, and call-controller adapter**

Use `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, and foreground connected-device permissions appropriate to API 31+. Control RX uses writes with response; Control TX uses indications. Bind one active authenticated central and reject media/control ownership from another central.

- [x] **Step 4: Run JVM tests and build both Android variants**

```bash
./android/phone-control-app/test.sh
./android/phone-control-app/build.sh
AIRSIM_ANDROID_MANIFEST=android/phone-control-app/AndroidManifest-standalone.xml \
  AIRSIM_ANDROID_OUTPUT_BASENAME=AirSIM-Standalone \
  ./android/phone-control-app/build.sh
```

Expected: tests PASS and both APKs sign successfully.

- [x] **Step 5: Commit Android gateway paths**

```bash
git add android/phone-control-app
git commit -m "feat: add authenticated Android VoBLE gateway"
```

### Task 5: Android PCM Resolution and BLE Media Session

**Files:**
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEPCMBackendResolver.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEPCMBridgeSession.java`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEMediaSession.java`
- Modify: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEGatewayService.java`
- Modify: `android/phone-control-app/test.sh`
- Modify: `android/phone-control-app/test/com/airsim/phonecontrol/CoreTests.java`

**Interfaces:**
- Produces: `resolve(RuntimeMode, avfAddress)`, `startMedia(callIdentity)`, `onUplinkPacket`, serialized downlink notifications, media statistics.
- Consumes: existing runtime/AVF detection, port 7580 PCM handshake, Task 2 packets, Task 3 media key, Task 4 call ownership.

- [x] **Step 1: Add resolver, startup-order, queue, and notification-flow tests**

Assert Standalone resolves loopback, AVF resolves the supplied private address, missing AVF address fails closed, `start_media` opens PCM before any uplink, `AIRSIMREADY` is required, eight-frame overflow drops oldest, notification failure retries only within deadline, and stop closes both pumps.

- [x] **Step 2: Run JVM tests and verify media types fail**

- [x] **Step 3: Implement backend resolver, PCM handshake, G.711 pumps, AEAD packets, and one-at-a-time notifications**

Use fixed-capacity queues and interruptible pump threads. Never block a Bluetooth callback on socket I/O. Reject media unless the authenticated central owns the active call and the call identity matches.

- [x] **Step 4: Run JVM tests and both Android builds**

Use Task 4 Step 4 commands. Expected: PASS.

- [x] **Step 5: Commit media paths**

```bash
git add android/phone-control-app
git commit -m "feat: bridge Android PCM over VoBLE"
```

### Task 6: iOS Core Bluetooth Central, Pairing UI, and Control Channel

**Files:**
- Create: `iOS/AirSIM/VoBLECentralController.swift`
- Create: `iOS/AirSIM/VoBLEControlChannel.swift`
- Create: `iOS/AirSIM/VoBLEModeController.swift`
- Create: `iOS/AirSIM/VoBLEPairingView.swift`
- Modify: `iOS/AirSIM/Info.plist`
- Modify: `iOS/AirSIM/AirSIMSetupView.swift`
- Modify: `iOS/AirSIM/AppModel.swift`
- Modify: `iOS/AirSIM.xcodeproj/project.pbxproj`
- Test: `iOS/AirSIMTests/AirSIMTests.swift`

**Interfaces:**
- Produces: observable Bluetooth discovery/auth/readiness state, pairing confirmation UI, `send(command:) async throws`, and typed Android events.
- Consumes: Tasks 1-3 mode/protocol/pairing APIs and Core Bluetooth delegate callbacks.

- [x] **Step 1: Add reducer tests for connect, wrong-key authentication, restoration, command timeout, stale response, and explicit-mode failure**

Use a fake central adapter so XCTest does not require simulator Bluetooth. Assert connected-but-unauthenticated never becomes ready and failure does not start VoWLAN or Cloud.

- [x] **Step 2: Run XCTest and verify controller symbols fail**

- [x] **Step 3: Implement central lifecycle, state restoration, independent subscriptions, pairing UI, and control serialization**

Add `NSBluetoothAlwaysUsageDescription` and `bluetooth-central` background mode. Store peripheral identity only after authenticated pairing. Authenticate again on every reconnect before publishing ready.

- [x] **Step 4: Run XCTest and an unsigned simulator build**

```bash
xcodebuild test -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air,OS=27.0' -only-testing:AirSIMTests
xcodebuild build -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

- [x] **Step 5: Commit iOS BLE control paths**

```bash
git add iOS/AirSIM iOS/AirSIMTests iOS/AirSIM.xcodeproj/project.pbxproj
git commit -m "feat: add iOS VoBLE pairing and control"
```

### Task 7: iOS GATT Media and Voice-Processing Audio Engine

**Files:**
- Create: `iOS/AirSIM/VoBLEMediaTransport.swift`
- Create: `iOS/AirSIM/VoBLEAudioEngine.swift`
- Modify: `iOS/AirSIM/AudioSessionController.swift`
- Modify: `iOS/AirSIM/VoBLECentralController.swift`
- Modify: `iOS/AirSIM.xcodeproj/project.pbxproj`
- Test: `iOS/AirSIMTests/AirSIMTests.swift`

**Interfaces:**
- Produces: `CallMediaTransport`, `VoBLEGATTMediaTransport`, bounded uplink scheduling, downlink reassembly/jitter, and Voice Processing I/O lifecycle.
- Consumes: Task 2 audio frames, Task 3 media key, Task 6 subscribed characteristics, CallKit audio activation.

- [x] **Step 1: Add tests for backpressure, eight-frame overflow, incomplete fragments, replayed packets, jitter progression, stale call identity, and audio-engine start gating**

Inject fake writer/player/capture adapters. Assert `canSendWriteWithoutResponse == false` stops dequeuing until the ready callback and no audio starts before both `media_ready` and CallKit activation.

- [x] **Step 2: Run XCTest and verify media/audio symbols fail**

- [x] **Step 3: Implement GATT transport, adaptive jitter, G.711 conversion, sample-rate conversion, and voice-processing audio lifecycle**

Keep real-time callbacks allocation-light. Move crypto/fragmentation off the render callback through preallocated bounded rings. Late packets and packets for another media session are discarded.

- [x] **Step 4: Run XCTest and simulator build**

Use Task 6 Step 4 commands. Expected: PASS.

- [x] **Step 5: Commit iOS media paths**

```bash
git add iOS/AirSIM iOS/AirSIMTests iOS/AirSIM.xcodeproj/project.pbxproj
git commit -m "feat: add iOS VoBLE call audio"
```

### Task 8: CallKit, Live Activity, and Apple Watch Integration

**Files:**
- Create: `iOS/AirSIM/VoBLECallCoordinator.swift`
- Modify: `iOS/AirSIM/AppModel.swift`
- Modify: `iOS/AirSIM/CallKitController.swift`
- Modify: `iOS/AirSIM/WatchCallCoordinator.swift`
- Modify: `iOS/AirSIM/LiveActivityController.swift`
- Modify: `iOS/Shared/WatchCallPayload.swift`
- Modify: `iOS/Shared/AirSIMLiveActivityShared.swift`
- Modify: `iOS/AirSIM.xcodeproj/project.pbxproj`
- Test: `iOS/AirSIMTests/AirSIMTests.swift`

**Interfaces:**
- Produces: outgoing/incoming Bluetooth call flows, generation-locked media, and exact-once terminal cleanup.
- Consumes: Tasks 1, 6, and 7 plus existing CallKit/Watch/Live Activity APIs.

- [x] **Step 1: Add lifecycle tests**

Cover Bluetooth outgoing without Relay/VoWLAN calls, incoming report, answer-media ordering, reject, hangup idempotency, stale ended ignored, matching ended exact-once cleanup, Watch ringing termination, and disconnect recovery refusing a different generation.

- [x] **Step 2: Run XCTest and verify coordinator tests fail**

- [x] **Step 3: Implement coordinator and route Bluetooth mode through it**

Remove BLE decisions from VoWLAN route helpers. Start media only after Android `media_ready` and CallKit activation. On matching `ended`, stop audio/PCM state, end CallKit, clear Live Activity, publish Watch terminal state, and resume background behavior exactly once.

- [x] **Step 4: Run XCTest and simulator build**

- [x] **Step 5: Commit lifecycle paths**

```bash
git add iOS/AirSIM iOS/AirSIMTests iOS/Shared iOS/AirSIM.xcodeproj/project.pbxproj
git commit -m "feat: integrate VoBLE with CallKit and Watch"
```

### Task 9: Diagnostics, AVF Recovery, and Settings Presentation

**Files:**
- Create: `iOS/AirSIM/VoBLEDiagnostics.swift`
- Create: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEDiagnostics.java`
- Modify: `iOS/AirSIM/AirSIMSetupView.swift`
- Modify: `iOS/AirSIM/PhoneViews.swift`
- Modify: `iOS/AirSIM/AppModel.swift`
- Modify: `android/phone-control-app/src/com/airsim/phonecontrol/MainActivity.java`
- Modify: `android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEPCMBackendResolver.java`
- Modify: `iOS/AirSIM.xcodeproj/project.pbxproj`
- Test: `iOS/AirSIMTests/AirSIMTests.swift`
- Test: `android/phone-control-app/test/com/airsim/phonecontrol/CoreTests.java`

**Interfaces:**
- Produces: sanitized Bluetooth status on both devices and three-second same-call recovery.
- Consumes: all prior transport, backend, queue, and call-state metrics.

- [x] **Step 1: Add tests for redaction, AVF address replacement, reconnect deadline, same-generation validation, and UI presentation**

Assert diagnostics contain no number, secret, nonce, tag, or audio payload. Assert an AVF address change is used on the next media session and never mutates an active socket.

- [x] **Step 2: Run XCTest and JVM suites and verify failures**

- [x] **Step 3: Implement diagnostics snapshots, settings/status cards, and bounded recovery policy**

Display selected mode, peer, authentication, control/audio subscription, Agent type/version, PCM readiness, codec, transport, queue/drop/jitter metrics, and categorized last error. Do not expose keys or phone numbers.

- [x] **Step 4: Run all unit suites and both platform builds**

```bash
./android/phone-control-app/test.sh
./android/phone-control-app/build.sh
xcodebuild test -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air,OS=27.0' -only-testing:AirSIMTests
xcodebuild build -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

- [x] **Step 5: Commit diagnostics paths**

```bash
git add iOS/AirSIM iOS/AirSIMTests iOS/AirSIM.xcodeproj/project.pbxproj \
  android/phone-control-app
git commit -m "feat: add VoBLE diagnostics and recovery"
```

### Task 10: Real-Device Validation and Release Documentation

**Files:**
- Create: `docs/voble-real-device-test-matrix.md`
- Modify: `README.md`
- Modify: `android-standalone/README.md`
- Modify: `docs/superpowers/plans/2026-10-13-voble-bluetooth-call.md`

**Interfaces:**
- Produces: reproducible device test evidence and documented Bluetooth-mode limitations.
- Consumes: signed development iOS build, Standalone APK, AVF APK, iPhone Air, Samsung, Xiaomi, and Apple Watch.

- [ ] **Step 1: Run the full automated verification suite and capture exact pass counts/build products in the matrix**

Use Task 9 Step 4 commands plus repository Go/Relay suites affected by overlapping pre-existing changes. Record command, commit, device OS/build, result, and failure logs without phone numbers.

- [ ] **Step 2: Install the Standalone build on Samsung and validate Wi-Fi-off outgoing and incoming calls**

Record pairing, dial response, answer-to-first-audio, both directions, speaker/mute/DTMF, Android hangup, iPhone hangup, Watch stop-ringing, and 30-minute queue/memory behavior.

- [ ] **Step 3: Install the AVF build and repeat with AVF PCM**

Restart AVF, change its private address, open a new call, and verify the resolver uses the new endpoint. Confirm an active call never changes endpoint in place.

- [ ] **Step 4: Validate Xiaomi HyperOS and failure cases**

Cover background restrictions, screen lock, Bluetooth loss under three seconds, loss beyond three seconds, wrong key, revoked pairing, Relay unavailable, VPN on/off, Wi-Fi off, and user-force-quit limitation messaging.

- [x] **Step 5: Update documentation with verified behavior and commit**

```bash
git add README.md android-standalone/README.md docs/voble-real-device-test-matrix.md \
  docs/superpowers/plans/2026-10-13-voble-bluetooth-call.md
git commit -m "docs: document VoBLE setup and device validation"
```

- [x] **Step 6: Review branch scope before push or release**

```bash
git status --short
git log --oneline main..VoBLE
git diff --stat main...VoBLE
```

Expected: only approved VoBLE commits plus the preserved pre-existing work that the user explicitly chooses to include; no credentials, DerivedData, APK build directories, or captured audio.
