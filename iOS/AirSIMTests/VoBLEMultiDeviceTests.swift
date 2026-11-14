import XCTest
import Combine
import CoreBluetooth
import CryptoKit
@testable import AirSIM

@MainActor
final class VoBLEMultiDeviceTests: XCTestCase {
    func testAddressRotationProbesBoundedCandidatesAndSelectsOnlyAuthenticatedTarget() async throws {
        let binding = AndroidAgentBindingPreference.selected()
        AndroidAgentBindingPreference.set("recovery-A")
        defer { AndroidAgentBindingPreference.set(binding) }
        let old = UUID(), replacement = UUID()
        let radio = VoBLERadioController(io: RadioIOProbe())
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(),
            knownPeripheral: { $0 == old }, knownRecoveryAgent: { $0 == "recovery-A" })
        defer { hub.stop() }
        _ = hub.prepare(peripheralID: old)
        hub.select(peripheralID: old)
        hub.start()
        radio.onDiscovered?(.init(id: replacement, name: "untrusted-name", signal: -40))
        let candidate = try XCTUnwrap(hub.sessions[replacement])
        let queued = UUID()
        radio.onDiscovered?(.init(id: queued, name: "another-untrusted-name", signal: -35))
        XCTAssertNil(hub.sessions[queued])
        XCTAssertEqual(hub.selectedPeripheralID, old, "advertisement must not replace a trusted mapping")
        // Crypto rejection is exercised by the production worker smoke tests.
        // This test drives the real Hub's post-authenticated routing boundary.
        authenticate(candidate.central, as: "recovery-A")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(hub.selectedPeripheralID, replacement)
        XCTAssertNil(hub.sessions[queued], "queued recovery probe must not displace a newly authenticated peer")
        XCTAssertEqual(hub.sessions[old]?.central.state, .stopped)
        let unrelated = UUID()
        radio.onDiscovered?(.init(id: unrelated, name: "same-name", signal: -30))
        XCTAssertNil(hub.sessions[unrelated], "a ready target must not probe arbitrary nearby devices")
    }

    func testIncomingBluetoothBadgeUsesPushedDeviceInsteadOfSelectedDevice() {
        let mode = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.bluetooth); AndroidAgentBindingPreference.set("badge-A")
        defer { ConnectionModePreference.set(mode); AndroidAgentBindingPreference.set(binding) }
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            bluetoothHub: hub, callKitController: CallKitController(observesSystemCallbacks: false))
        defer { model.stop() }
        authenticate(a.central, as: "badge-A")
        XCTAssertTrue(model.callConnectionIsReady)
        let push = IncomingVoIPCall(bluetoothCallID: "badge-call", uuid: UUID(), generation: 1,
                                   number: nil, agentID: "badge-B")
        model.callKitDidReceiveIncoming(push)
        XCTAssertFalse(model.callConnectionIsReady, "A being online cannot mark incoming B online")
        authenticate(b.central, as: "badge-B")
        XCTAssertTrue(model.callConnectionIsReady, "Authenticated BLE must count without WLAN or Relay heartbeat")
        b.central.stop()
        XCTAssertFalse(model.callConnectionIsReady)
    }

    func testColdSelectedPeerIsRetriedWhenRadioBecomesPoweredOn() {
        let id = UUID(), other = UUID(), io = RadioIOProbe()
        io.poweredOn = false
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(), knownPeripheral: { $0 == id })
        defer { hub.stop() }
        _ = hub.prepare(peripheralID: id)
        hub.select(peripheralID: id)
        hub.start()
        XCTAssertTrue(io.retrieved.isEmpty, "Do not attach a phantom connecting session while radio is unknown")
        io.poweredOn = true
        radio.onPoweredOn?()
        XCTAssertTrue(io.retrieved.contains(id), "Retry cached target immediately, without waiting for an advertisement or 10s timer")
        XCTAssertFalse(io.retrieved.contains(other))
        hub.stop()
        io.retrieved.removeAll()
        radio.onPoweredOn?()
        XCTAssertTrue(io.retrieved.isEmpty, "A late radio callback must not resurrect a stopped hub")
    }

    func testIssue20CleanDisconnectMustReleaseHandshakeQueue() async throws {
        try await verifyHandshakeDisconnect(error: nil)
    }
    func testIssue20FailedThenScanningMustReleaseHandshakeQueue() async throws {
        try await verifyHandshakeDisconnect(error: "temporary disconnect")
    }
    private func verifyHandshakeDisconnect(error: String?) async throws {
        let a = UUID(), b = UUID()
        let radio = VoBLERadioController(io: RadioIOProbe())
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(), knownPeripheral: { $0 == a || $0 == b })
        defer { hub.stop() }
        hub.start()
        radio.onDiscovered?(.init(id: a, name: "A", signal: -40))
        let first = try XCTUnwrap(hub.sessions[a])
        first.central.apply(.discovered(a))
        first.central.apply(.connected)
        first.central.apply(.characteristicsReady)
        try await Task.sleep(for: .milliseconds(50))
        // Queue B while A owns the handshake. No CBPeripheral hardware is required.
        radio.onDiscovered?(.init(id: b, name: "B", signal: -40))
        XCTAssertNil(hub.sessions[b])
        // Same reducer sequence used by handleDisconnect + restoreOrScan.
        first.central.apply(.disconnected(error))
        if error != nil { first.central.apply(.bluetoothPoweredOn) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(first.central.state, .scanning)
        // A's delayed UI state must not re-acquire or release B's handshake.
        radio.onDiscovered?(.init(id: a, name: "A", signal: -40))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(hub.sessions[b], "A disconnected during authentication: shared handshake must release so B can recover")
    }

    func testHandshakeDoesNotReleaseOnInitialScanningOrOldUIEvent() async throws {
        let ids = [UUID(), UUID(), UUID()]
        let radio = VoBLERadioController(io: RadioIOProbe())
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(), knownPeripheral: { ids.contains($0) })
        defer { hub.stop() }
        hub.start()
        for id in ids { radio.onDiscovered?(.init(id: id, name: "fixture", signal: -40)) }
        XCTAssertNil(hub.sessions[ids[1]], "initial scanning must not release A's pending attempt")
        let a = try XCTUnwrap(hub.sessions[ids[0]])
        a.central.apply(.authenticationFailed("failed"))
        a.central.apply(.bluetoothPoweredOn)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(hub.sessions[ids[1]])
        a.central.apply(.disconnected(nil))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(hub.sessions[ids[2]], "an event from A cannot release B's ownership")
    }

    func testHandshakeDeadlinesCoverDiscoveryAndAuthenticationButNotUserConfirmation() {
        for state in [VoBLEConnectionState.connected, .authenticating] {
            XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(state: state, enabled: true, elapsed: 19))
            XCTAssertTrue(VoBLEConnectionTimeoutPolicy.shouldExpire(state: state, enabled: true, elapsed: 20))
            XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(state: state, enabled: true,
                elapsed: 120, awaitingConfirmation: true))
            XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(state: state, enabled: true,
                elapsed: 120, isBackground: true))
        }
        XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(state: .connecting, enabled: true,
            elapsed: 29, systemReconnecting: true))
        XCTAssertTrue(VoBLEConnectionTimeoutPolicy.shouldExpire(state: .connecting, enabled: true,
            elapsed: 30, systemReconnecting: true))
    }

    func testDialPadClearsAcceptedNumber() async throws {
        try await verifyDialPadInput(initial: "10086", expected: "")
    }

    func testDialPadClearsAcceptedTrimmedNumber() async throws {
        try await verifyDialPadInput(initial: " 10086 ", expected: "")
    }

    func testDialPadKeepsFailedNumberForRetry() async throws {
        try await verifyDialPadInput(initial: "10086", expected: "10086", fail: true)
    }

    func testDialPadKeepsNewDraftWhileDialIsPending() async throws {
        try await verifyDialPadInput(initial: "10086", edited: "10010", expected: "10010")
    }

    func testDialPadKeepsUnrelatedDraftForExternalDial() async throws {
        try await verifyDialPadInput(initial: "10010", expected: "10010")
    }

    private func verifyDialPadInput(initial: String, edited: String? = nil,
                                    expected: String, fail: Bool = false) async throws {
        let previous = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.bluetooth); AndroidAgentBindingPreference.set(nil)
        defer { ConnectionModePreference.set(previous); AndroidAgentBindingPreference.set(binding) }
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let session = hub.prepare(peripheralID: UUID())
        authenticate(session.central, as: "dialpad-fixture")
        let backend = ModeExitBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend }, bluetoothHub: hub, callKitController: CallKitController())
        defer {
            backend.onDial = {}
            if let active = model.deviceCalls.active { model.deviceCallRouter.finished(active) }
            model.stop()
        }
        model.numberInput = initial
        backend.onDial = {
            if let edited { model.numberInput = edited }
            if fail { throw DeviceCallRoutingError.unavailable }
        }
        do {
            try await model.callKitStart(number: "10086")
            XCTAssertFalse(fail, "failed dial must throw")
        } catch {
            guard fail else { throw error }
            XCTAssertEqual(error as? DeviceCallRoutingError, .unavailable)
        }
        XCTAssertEqual(backend.dialCount, 1, "test must exercise the accepted/failed backend receipt")
        XCTAssertEqual(model.numberInput, expected)
        if fail {
            XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
            XCTAssertNil(model.deviceCalls.active)
            XCTAssertNil(model.deviceCallContext.media.owner)
            backend.onDial = {}
            try await model.callKitStart(number: "10086")
            XCTAssertEqual(backend.dialCount, 2, "only an explicit new request may retry")
            XCTAssertEqual(model.numberInput, "")
        }
    }

    func testPairingPageShowsSharedScanBeforeAnyDeviceIsSelected() {
        let io = RadioIOProbe()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        XCTAssertEqual(hub.pairingState, .stopped)
        hub.start()
        XCTAssertNil(hub.selectedPeripheralID)
        XCTAssertEqual(hub.pairingState, .scanning)
        XCTAssertNil(hub.selected.central.authenticatedIdentity)
        XCTAssertNil(hub.bundle(for: "unpaired"))
        XCTAssertEqual(io.scans, 1)
        hub.start()
        XCTAssertEqual(io.scans, 1, "entering pairing must reuse the shared scan")
        hub.stop()
        XCTAssertEqual(hub.pairingState, .stopped)
    }

    func testForegroundReArmsSharedScanWhenFlagStillSaysScanning() {
        let io = RadioIOProbe()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        defer { hub.stop() }
        hub.start()
        XCTAssertEqual(io.scans, 1)
        XCTAssertEqual(hub.pairingState, .scanning)
        // The OS can stop a scan while the app is suspended without changing
        // the in-memory flag; a foreground re-arm must issue a fresh scan.
        hub.radio.rearmScan()
        XCTAssertEqual(io.stops, 1)
        XCTAssertEqual(io.scans, 2)
        XCTAssertEqual(hub.pairingState, .scanning)
    }

    func testMediaPauseStopsSharedScanAndResumesWhenAudioEnds() {
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        radio.start()
        XCTAssertEqual(io.scans, 1)
        radio.pauseScanForMedia()
        XCTAssertEqual(io.stops, 1)
        XCTAssertFalse(radio.scanning)
        // Foreground/re-arm and user rescan must not steal radio time from an
        // active BLE media connection.
        radio.start()
        radio.rearmScan()
        radio.rescan()
        XCTAssertEqual(io.scans, 1, "media must suppress rescan while audio is running")
        radio.resumeScanAfterMedia()
        XCTAssertEqual(io.scans, 2)
        XCTAssertTrue(radio.scanning)
        radio.stop()
    }

    func testLocalIncomingDuringCloudCallStaysReminder() async throws {
        let previous = ConnectionModePreference.selected()
        ConnectionModePreference.set(.automatic)
        defer { ConnectionModePreference.set(previous) }
        let backend = PassiveCallBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend })
        defer { model.stop() }
        let cloudUUID = UUID()
        let cloud = try IncomingVoIPCall(userInfo: [
            "event": "incoming_call", "call_id": "cloud-busy-1",
            "call_uuid": cloudUUID.uuidString, "generation": 1,
            "number": "10086", "agent_id": "cloud-agent",
        ])
        model.callKitDidReceiveIncoming(cloud)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, "cloud-busy-1")
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ringing)

        let local = DeviceCallEvent(agentID: "local-agent", callID: "local-busy-1",
            state: .ringing, transport: .bluetooth, transportEpoch: 1, number: "10010")
        _ = model.receiveOwnedCallEvent(local)
        // The cloud call keeps the primary presentation; the local call must be
        // visible as an "other device" reminder, not silently swallowed.
        XCTAssertEqual(model.callLifecycleSnapshot.callID, "cloud-busy-1")
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ringing)
        let key = try XCTUnwrap(model.deviceCalls.key(agentID: "local-agent", callID: "local-busy-1"))
        XCTAssertEqual(model.deviceCalls.latestEvent(for: key)?.state, .ringing)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertTrue(model.otherDeviceCallReminders.contains { $0.key == key },
                      "local ringing call must surface as a reminder while cloud owns the call")
        do {
            try await model.answerOtherDeviceCall(key)
            XCTFail("answering a local reminder during a cloud call must be busy")
        } catch {
            XCTAssertEqual(error as? DeviceCallRoutingError, .busy)
        }
    }

    func testLiveActivityTreatsBluetoothAsAgentOnline() {
        let agent = AndroidAgentPresentation(
            id: "a", deviceName: "Samsung", phoneNumber: nil, agentKind: "standalone",
            cloudOnline: false, vowlanOnline: false, bluetoothOnline: true, isCurrent: true)
        let snapshot = LiveActivityAgentSnapshot(agent: agent, pairedAgentCount: 1)
        let state = LiveActivityStateBuilder.make(
            call: nil, callerName: nil, moduleOnline: false, cloudOnline: false,
            radio: nil, agent: snapshot, idleStartedAt: Date())
        XCTAssertEqual(state.phase, .standby)
        XCTAssertEqual(state.displayName, "等待 Agent 来电")
        XCTAssertTrue(state.bluetoothOnline == true)
    }

    func testLiveActivityOfflineSaysAgentOffline() {
        let state = LiveActivityStateBuilder.make(
            call: nil, callerName: nil, moduleOnline: false, cloudOnline: false,
            radio: nil, agent: nil, idleStartedAt: Date())
        XCTAssertEqual(state.phase, .offline)
        XCTAssertEqual(state.displayName, "Agent 离线")
    }

    func testAndroidSIMSlotMetadataDecodesNumbers() throws {
        let data = Data(#"""
        {"agent_id":"sim-agent","device_name":"Samsung","call_generation":1,
         "sim_slots":[{"id":"k1","label":"SIM 1","number":"10086","default":true},
                      {"id":"k2","label":"SIM 2","number":""}]}
        """#.utf8)
        let metadata = try AndroidAgentMetadata.decode(data, expectedID: "sim-agent")
        XCTAssertEqual(metadata.simSlots?.count, 2)
        XCTAssertEqual(metadata.simSlots?.first?.displayName, "SIM 1 · 10086")
        XCTAssertEqual(metadata.simSlots?.last?.displayName, "SIM 2")
    }

    func testBluetoothPCMStatusText() {
        XCTAssertEqual(CallAudioStatusPresentation.text(
            transport: .bluetooth, bluetoothRunning: true, bluetoothError: nil,
            localAudioActive: false, cloudState: .idle), "已连接蓝牙 PCM 链路")
        XCTAssertEqual(CallAudioStatusPresentation.text(
            transport: .bluetooth, bluetoothRunning: false, bluetoothError: nil,
            localAudioActive: false, cloudState: .idle), "正在建立蓝牙语音链路")
    }

    func testPairingSheetObservesVerificationCodeWithoutAnotherTap() {
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let session = hub.prepare(peripheralID: UUID())
        var updates = 0
        let observation = hub.objectWillChange.sink { updates += 1 }
        defer { observation.cancel(); hub.stop() }
        // pendingSAS/errorMessage are @Published on the central, not mirrored by
        // $state. Forwarding the central must invalidate the sheet immediately.
        session.central.objectWillChange.send()
        XCTAssertGreaterThan(updates, 0, "pairing sheet must observe verification-code changes")
    }

    func testRadioBecomingAvailablePublishesPairingPageUpdateWithoutSelectedSession() {
        let io = RadioIOProbe(); io.poweredOn = false
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        var updates = 0
        let observation = hub.objectWillChange.sink { updates += 1 }
        defer { observation.cancel(); hub.stop() }
        hub.start()
        XCTAssertGreaterThan(updates, 0, "reopening pairing while power is off must publish enablement")
        XCTAssertEqual(hub.pairingState, .bluetoothUnavailable)
        updates = 0
        io.poweredOn = true
        hub.radio.scanIfNeeded()
        XCTAssertGreaterThan(updates, 0, "radio power/scan updates must invalidate the pairing view")
        XCTAssertEqual(hub.pairingState, .scanning)
        XCTAssertNil(hub.selected.central.authenticatedIdentity)
    }

    func testUnboundBluetoothPeersExposeDialDeviceSelectionAndBindOnlyChosenPhone() {
        let previous = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.bluetooth); AndroidAgentBindingPreference.set(nil)
        defer { ConnectionModePreference.set(previous); AndroidAgentBindingPreference.set(binding) }
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        authenticate(a.central, as: "selector-A"); authenticate(b.central, as: "selector-B")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), bluetoothHub: hub)
        defer { model.stop() }
        XCTAssertNil(model.currentAndroidAgent)
        XCTAssertEqual(model.pairedAndroidAgents.count, 2)
        XCTAssertEqual(DialPadAgentSection.make(mode: .bluetooth, hasCurrent: model.currentAndroidAgent != nil,
            pairedCount: model.pairedAndroidAgents.count), .selection)
        model.bindAndroidAgent("selector-B")
        XCTAssertEqual(model.currentAndroidAgent?.id, "selector-B")
        XCTAssertEqual(a.central.state, .ready)
        XCTAssertEqual(b.central.state, .ready)
    }

    private func authenticate(_ session: VoBLECentralController, as identity: String) {
        session.apply(.discovered(session.targetPeripheralID!))
        session.apply(.connected)
        session.apply(.characteristicsReady)
        session.apply(.controlSubscription(true))
        // Trusted result of the authenticated GATT boundary. The protocol's
        // transcript, SAS and crypto are exercised by the pairing tests.
        session.apply(.authenticated(identity: identity))
    }

    func testCallKitActivationNeverActivatesPassiveBLEForWLANOwner() async throws {
        let io = RadioIOProbe(), id = UUID()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        let session = hub.prepare(peripheralID: id)
        authenticate(session.central, as: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ModeExitBackend() }, bluetoothHub: hub)
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        session.central.onEvent?(.init(callID: "fixture", generation: 1, direction: "outgoing", state: "active", number: ""))
        XCTAssertNotNil(session.calls.currentIdentity)
        await model.callKitAudioSessionDidActivate()
        XCTAssertFalse(session.audio.callKitAudioActive)
        model.callKitAudioSessionDidDeactivate()
        await model.hangup()
    }
    func testNormalDisconnectRestartsDuplicateSuppressedScanWithoutDroppingB() {
        let io = RadioIOProbe()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        hub.start()
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        let before = io.scans
        a.central.apply(.disconnected(nil))
        XCTAssertEqual(io.scans, before + 1)
        XCTAssertEqual(b.central.state, .ready)
        XCTAssertTrue(io.cancelled.isEmpty)
        hub.stop()
    }

    func testTwoAuthenticatedSessionsStayConnectedWhenDefaultChanges() {
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let aID = UUID(), bID = UUID()
        let a = hub.prepare(peripheralID: aID), b = hub.prepare(peripheralID: bID)
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        hub.select(peripheralID: aID)
        XCTAssertTrue(hub.session(for: "A") === a.central)
        hub.select(peripheralID: bID)
        XCTAssertTrue(hub.selected === b)
        XCTAssertTrue(hub.session(for: "A") === a.central)
        XCTAssertEqual(a.central.state, .ready)
        XCTAssertEqual(b.central.state, .ready)
        XCTAssertTrue(io.cancelled.isEmpty)
    }

    func testDisconnectBDoesNotDemoteAAuthenticatedSession() {
        let radio = VoBLERadioController(io: RadioIOProbe())
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        b.central.stop()
        XCTAssertTrue(hub.session(for: "A") === a.central)
        XCTAssertEqual(a.central.state, .ready)
        XCTAssertNil(hub.session(for: "B"))
    }

    func testDisconnectBDoesNotFailAPendingCommand() async throws {
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let a = hub.prepare(peripheralID: UUID()), b = hub.prepare(peripheralID: UUID())
        let sent = expectation(description: "A control request sent")
        let reply = Task { try await a.central.commandMailbox.perform(requestID: "A-request", generation: 7,
            write: { sent.fulfill() }) }
        await fulfillment(of: [sent], timeout: 1)
        b.central.stop()
        a.central.commandMailbox.resolve(.init(requestID: "A-request", generation: 7,
            success: true, code: "ok", detail: "A-only"))
        let result = try await reply.value
        XCTAssertEqual(result.detail, "A-only")
    }

    func testRevokeBDoesNotStopSharedScanOrDisconnectA() async throws {
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let aID = UUID(), bID = UUID()
        let a = hub.prepare(peripheralID: aID), b = hub.prepare(peripheralID: bID)
        hub.start()
        authenticate(a.central, as: "A"); authenticate(b.central, as: "B")
        try await hub.forget(agentID: "B")
        XCTAssertTrue(radio.scanning)
        XCTAssertEqual(a.central.state, .ready)
        XCTAssertNil(hub.session(for: "B"))
        XCTAssertFalse(io.cancelled.contains(aID))
    }

    func testRestoreAdoptsEveryEligibleOSPeripheralAndRequiresFreshAuth() {
        let ids = [UUID(), UUID()]
        let radio = VoBLERadioController(io: RadioIOProbe())
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(), knownPeripheral: { ids.contains($0) })
        hub.start()
        radio.restore(peripheralIDs: ids + [UUID()])
        XCTAssertEqual(hub.sessions.count, 2)
        XCTAssertNil(hub.session(for: "A"))
        XCTAssertNil(hub.session(for: "B"))
        XCTAssertTrue(ids.allSatisfy { hub.sessions[$0]?.central.authenticatedIdentity == nil })
    }

    func testBluetoothLaneStaysAvailableAfterModeExitAndTerminal() async throws {
        let previous = ConnectionModePreference.selected()
        ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(previous) }
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings())
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ModeExitBackend() }, bluetoothHub: hub)
        hub.start()
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        model.setConnectionMode(.vowlan)
        XCTAssertTrue(radio.scanning, "keep active Bluetooth lane until terminal")
        await model.hangup()
        XCTAssertTrue(radio.scanning, "BLE standby link remains after terminal")
        model.stop()
    }

    func testModeExitKeepsAuthenticatedCentralThroughHangup() async throws {
        let previous = ConnectionModePreference.selected()
        ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(previous) }
        let io = RadioIOProbe(), id = UUID()
        let hub = VoBLEDeviceHub(radio: VoBLERadioController(io: io), pairingStore: MemoryPairings())
        let session = hub.prepare(peripheralID: id)
        authenticate(session.central, as: "A")
        let backend = ModeExitBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend }, bluetoothHub: hub)
        hub.start()
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        model.setConnectionMode(.vowlan)
        backend.onEnd = {
            XCTAssertEqual(session.central.state, .ready, "end must reach an authenticated live transport")
            XCTAssertFalse(io.cancelled.contains(id), "UI retirement must not disconnect before sending")
            XCTAssertNil(model.deviceCalls.active, "presentation still retires before network I/O")
            model.setConnectionMode(.cloud)
            model.setConnectionMode(.vowlan)
            await Task.yield()
            XCTAssertEqual(session.central.state, .ready, "keep the lane until the command reply")
        }
        await model.hangup()
        XCTAssertEqual(session.central.state, .ready, "keep authenticated BLE standby after hangup")
        XCTAssertTrue(hub.radio.scanning, "BLE scanner stays available for reconnect")
        model.stop()
    }

    func testBluetoothToggleDoesNotRestoreOnlyFirstPeer() {
        let ids = [UUID(), UUID()]
        let io = RadioIOProbe()
        let radio = VoBLERadioController(io: io)
        let hub = VoBLEDeviceHub(radio: radio, pairingStore: MemoryPairings(), knownPeripheral: { ids.contains($0) })
        hub.start()
        radio.restore(peripheralIDs: ids)
        XCTAssertEqual(hub.sessions.count, 2)
        hub.stop(); hub.start()
        radio.restore(peripheralIDs: ids)
        XCTAssertEqual(hub.sessions.count, 2)
        XCTAssertTrue(hub.sessions.values.allSatisfy { $0.central.state != .ready })
        XCTAssertEqual(io.connected.count, 0)
    }

    func testStandbyPeersNeverRequestPCM() async {
        let central = CallControlBoundary()
        let writer = VoBLECentralController(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let media = VoBLEGATTMediaTransport(writer: writer)
        let audio = VoBLEAudioEngine(transport: media)
        let calls = VoBLECallCoordinator(central: central, media: media, audio: audio)
        var authorizationChecks = 0
        calls.mediaPermission = { _ in authorizationChecks += 1; return false }
        central.onEvent?(.init(callID: "local-android-answer", generation: 2,
            direction: "incoming", state: "active", number: ""))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(authorizationChecks, 1)
        XCTAssertFalse(media.isRunning)
        XCTAssertFalse(audio.running)
        XCTAssertTrue(central.commands.isEmpty)
    }

    func testOutgoingOwnershipIsReservedBeforeCommandCanReply() async throws {
        let central = CallControlBoundary()
        let writer = VoBLECentralController(radio: VoBLERadioController(io: RadioIOProbe()), pairingStore: MemoryPairings())
        let media = VoBLEGATTMediaTransport(writer: writer)
        let calls = VoBLECallCoordinator(central: central, media: media, audio: VoBLEAudioEngine(transport: media))
        var intent = false
        calls.onOutgoingIntent = { _ in intent = true }
        central.beforeSend = { XCTAssertTrue(intent) }
        _ = try await calls.startOutgoing(number: "test")
        XCTAssertEqual(central.commands, ["dial"])
    }

    func testPairingWorkAndCredentialIOStayOffMainThreadForBothPeers() async throws {
        let store = MemoryPairings()
        let android = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let workers = [VoBLEPairingWorker(store: store), VoBLEPairingWorker(store: store)]
        for (index, worker) in workers.enumerated() {
            let identity = "fixture-\(index)"
            let result = try await worker.prepare(identity: identity, androidPublic: android,
                androidNonce: Data(repeating: UInt8(index + 1), count: 32))
            try await worker.save(.init(identity: identity, pairingKey: result.material.pairingKey, createdAt: Date()))
        }
        XCTAssertEqual(store.mainThreadObservations.count, 4)
        XCTAssertFalse(store.mainThreadObservations.contains(true))
    }
}

@MainActor
private final class ModeExitBackend: DeviceCallBackend {
    let epoch: UInt64 = 1
    var onEnd: () async -> Void = {}
    var onDial: () throws -> Void = {}
    var dialCount = 0
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        dialCount += 1
        try onDial()
        return .init(callID: "fixture", backendID: "fixture", generation: nil)
    }
    func answer(callID: String, generation: UInt64?) async throws {}
    func end(callID: String, generation: UInt64?, reject: Bool) async throws { await onEnd() }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws {}
}

private final class MemoryPairings: VoBLEPairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []
    var mainThreadObservations: [Bool] { lock.withLock { observations } }
    func save(_ peer: VoBLEStoredPeer) throws { lock.withLock { observations.append(Thread.isMainThread) } }
    func load(identity: String) throws -> VoBLEStoredPeer? {
        lock.withLock { observations.append(Thread.isMainThread) }; return nil
    }
    func revoke(identity: String) throws {}
}

@MainActor
private final class CallControlBoundary: VoBLECallControlling {
    var state: VoBLEConnectionState = .ready
    var onEvent: ((VoBLEAndroidEvent) -> Void)?
    var onAudioDownlinkFragment: ((Data) -> Void)?
    var onReadyToSendAudio: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReady: (() -> Void)?
    var commands: [String] = []
    var beforeSend: () -> Void = {}
    func send(command: String, callID: String, generation: UInt64, number: String) async throws -> VoBLEControlResponse {
        beforeSend(); commands.append(command)
        return .init(requestID: "fixture", generation: generation, success: true, code: "ok", detail: "accepted")
    }
    func mediaKey(callID: String, generation: UInt64) throws -> Data { Data(repeating: 1, count: 32) }
}

@MainActor
private final class PassiveCallBackend: DeviceCallBackend {
    let epoch: UInt64 = 1
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        .init(callID: operationID, backendID: operationID, generation: 1)
    }
    func answer(callID: String, generation: UInt64?) async throws {}
    func end(callID: String, generation: UInt64?, reject: Bool) async throws {}
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws {}
}

private final class RadioIOProbe: VoBLERadioIO {
    var manager: CBCentralManager? { nil }
    var poweredOn = true
    var cancelled: [UUID] = []
    var connected: [UUID] = []
    var retrieved: [UUID] = []
    var scans = 0
    var stops = 0
    func start(delegate: any CBCentralManagerDelegate) {}
    func scan() { scans += 1 }
    func stopScan() { stops += 1 }
    func connect(_ id: UUID) { connected.append(id) }
    func cancel(_ id: UUID) { cancelled.append(id) }
    func peripheral(_ id: UUID) -> CBPeripheral? { retrieved.append(id); return nil }
}
