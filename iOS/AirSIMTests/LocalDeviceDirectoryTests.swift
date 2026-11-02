import XCTest
import Foundation
import Network
import CryptoKit
import WatchConnectivity
@testable import AirSIM

@MainActor
final class LocalDeviceDirectoryTests: XCTestCase {

    func testSystemAnswerUsesPublishedBackendIDInsteadOfTelecomID() async throws {
        let previousMode = ConnectionModePreference.selected()
        let previousBinding = AndroidAgentBindingPreference.selected()
        defer {
            ConnectionModePreference.set(previousMode)
            AndroidAgentBindingPreference.set(previousBinding)
        }
        ConnectionModePreference.set(.cloud)
        AndroidAgentBindingPreference.set(nil)

        let publishedID = "android-1700000000000"
        let telecomID = UUID().uuidString
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret,
                                               callID: telecomID, backendCallID: publishedID)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))

        let controller = CallKitController(observesSystemCallbacks: false)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
                             localDirectory: directory, callKitController: controller)
        defer { model.stop() }
        let push = try IncomingVoIPCall(userInfo: ["event": "incoming_call", "call_id": publishedID,
            "call_uuid": UUID().uuidString, "generation": 1, "agent_id": "A"])
        let reported = expectation(description: "incoming system call reported")
        controller.reportIncomingPush(push, systemReport: { _, _, completion in completion(nil) }) { error in
            XCTAssertNil(error)
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 2)
        model.activeCall = CallRecord(id: publishedID, index: 1, direction: "incoming", state: "incoming",
            number: nil, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false, androidID: telecomID)
        ConnectionModePreference.set(.vowlan)

        try await model.callKitAnswer(uuid: push.uuid, origin: .system)
        XCTAssertEqual(peer.commands.filter { $0.path == "/api/calls/answer" }.map(\.callID), [publishedID])
    }

    func testOfflinePeerCannotDelayAnotherPeersAuthentication() async throws {
        let slowID = "slow-" + UUID().uuidString, fastID = "fast-" + UUID().uuidString
        let fast = try AuthenticatedHealthPeer(agentID: fastID, secret: aSecret)
        defer { fast.stop() }
        let fastEndpoint = try await fast.start()
        let slowEndpoint = try VoWLANEndpoint(host: "10.0.0.2", controlPort: 39002, pcmPort: 39003)
        let store = MemoryWLANCredentials()
        let credential = try VoWLANCredential(secret: aSecret)
        try store.save(credential, agentID: slowID)
        try store.save(credential, agentID: fastID)
        let gate = ResponseGate()
        let slowWaiting = expectation(description: "offline peer probe pending")
        let fastVerified = expectation(description: "healthy peer verified independently")
        let directory = LocalDeviceDirectory(credentials: store, healthTransport: { request in
            if request.url?.host == slowEndpoint.host {
                slowWaiting.fulfill()
                await gate.wait()
                throw URLError(.timedOut)
            }
            return try await AuthenticatedHealthPeer.transport(request)
        })
        directory.onVerified = { _ in fastVerified.fulfill() }
        let candidates = [(slowID, slowEndpoint), (fastID, fastEndpoint)].map { id, endpoint in
            VoWLANDiscoveredAgent(id: id, endpoint: endpoint, deviceName: "fixture",
                manufacturer: nil, model: nil, phoneNumber: nil, agentKind: nil)
        }
        let verification = Task { await directory.verifyCandidates(candidates) }
        await fulfillment(of: [slowWaiting, fastVerified], timeout: 2)
        XCTAssertNotNil(directory.api(for: fastID))
        XCTAssertNil(directory.api(for: slowID))
        await gate.release()
        await verification.value
    }

    func testForegroundRefreshRequestsSnapshotWithoutWaitingForOldCursor() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "wake-peer", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let cursor = CursorHTTPBoundary()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: cursor) }, healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "wake-peer", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        directory.start(); defer { directory.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let before = cursor.afterValues.count
        directory.refreshAfterForeground()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(cursor.afterValues.first, AgentEventCursor.initial)
        XCTAssertEqual(cursor.afterValues.dropFirst(before).first, AgentEventCursor.initial)
    }

    func testPushRegistrationCallbackOnlyReceivesAuthenticatedGateways() async throws {
        let id = "push-sync-" + UUID().uuidString
        let peer = try AuthenticatedHealthPeer(agentID: id, secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), healthTransport: AuthenticatedHealthPeer.transport)
        var routes: [LocalAgentRoute] = []
        directory.onVerified = { routes.append($0.route) }
        XCTAssertTrue(routes.isEmpty)
        try await directory.verifyPairing(agentID: id, endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        XCTAssertEqual(routes, [directory.api(for: id)!.route])
        try await directory.forget(agentID: id)
        XCTAssertNil(directory.api(for: id))
        XCTAssertEqual(routes.count, 1)
    }

    func testHealthWithoutDeviceNameCannotPersistSpoofedBonjourName() async throws {
        let id = "nameless-" + UUID().uuidString
        defer { PairedAndroidDeviceStore.forget(id); PairedAndroidDeviceStore.allowPairing(id) }
        let peer = try AuthenticatedHealthPeer(agentID: id, secret: aSecret, deviceName: nil)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), healthTransport: AuthenticatedHealthPeer.transport)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), localDirectory: directory)
        defer { model.stop() }
        let candidate = VoWLANDiscoveredAgent(id: id, endpoint: endpoint, deviceName: "Spoofed TXT name",
            manufacturer: nil, model: nil, phoneNumber: nil, agentKind: nil)
        model.rememberVerifiedLocalDevice(candidate)
        XCTAssertFalse(PairedAndroidDeviceStore.records().contains { $0.id == id })
        try await directory.verifyPairing(agentID: id, endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        model.rememberVerifiedLocalDevice(candidate)
        XCTAssertEqual(PairedAndroidDeviceStore.records().first { $0.id == id }?.deviceName, "Android 手机")
        PairedAndroidDeviceStore.remember(.init(id: id, deviceName: "Previously paired phone", agentKind: nil))
        model.rememberVerifiedLocalDevice(candidate)
        XCTAssertEqual(PairedAndroidDeviceStore.records().first { $0.id == id }?.deviceName, "Previously paired phone")
    }

    func testUnauthenticatedDiscoveryNeverAppearsAsPairedOrOverridesVerifiedIdentity() async throws {
        let id = "discovery-" + UUID().uuidString
        let peer = try AuthenticatedHealthPeer(agentID: id, secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), healthTransport: AuthenticatedHealthPeer.transport)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), localDirectory: directory)
        defer { model.stop() }
        let advertisement = VoWLANDiscoveredAgent(id: id, endpoint: endpoint, deviceName: "Unauthenticated name",
            manufacturer: nil, model: nil, phoneNumber: "untrusted-number", agentKind: "untrusted-kind")
        XCTAssertFalse(model.androidAgentPresentations(discoveredAgents: [advertisement]).contains { $0.id == id })
        try await directory.verifyPairing(agentID: id, endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        let verified = try XCTUnwrap(model.androidAgentPresentations(discoveredAgents: [advertisement]).first { $0.id == id })
        XCTAssertTrue(verified.vowlanOnline)
        XCTAssertNotEqual(verified.deviceName, "Unauthenticated name")
        XCTAssertNotEqual(verified.phoneNumber, "untrusted-number")
        XCTAssertNotEqual(verified.agentKind, "untrusted-kind")
    }

    private let aSecret = Data(repeating: 0x41, count: 32)
    private let bSecret = Data(repeating: 0x42, count: 32)
    func testPushedVoWLANRemoteEndClosesOriginalSystemCall() async throws {
        let old = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.automatic); AndroidAgentBindingPreference.set("A")
        defer {
            ConnectionModePreference.set(old); AndroidAgentBindingPreference.set(binding)
            IPhoneCloudCallSession.shared.stop()
        }
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret, callID: "call-191")
        peer.setCallState(nil)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        let controller = CallKitController(observesSystemCallbacks: false)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            localDirectory: directory, callKitController: controller,
            historyStore: LocalHistoryStore(directoryURL: path))
        defer { model.stop() }
        directory.stop()
        let pushed = try IncomingVoIPCall(userInfo: ["event": "incoming_call", "agent_id": "A",
            "call_id": "call-191", "call_uuid": UUID().uuidString, "generation": 7])
        let reported = expectation(description: "APNs system call reported")
        controller.reportIncomingPush(pushed, systemReport: { _, _, done in done(nil) }) { error in
            XCTAssertNil(error); reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 2)
        let epoch = directory.transportEpoch(for: "A")
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "call-191", state: .ringing,
            transport: .vowlan, transportEpoch: epoch, backendCallID: "call-191"))
        try await model.callKitAnswer(uuid: pushed.uuid, origin: .system)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "call-191", state: .active,
            transport: .vowlan, transportEpoch: epoch, backendCallID: "call-191"))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .active)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, pushed.uuid)
        let startupInvalidation = model.makeLocalAudioStartupInvalidationCheck()
        XCTAssertNil(startupInvalidation())
        // BLE and Relay counters are independent; only compare BLE's own history.
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "call-191", state: .active,
            transport: .bluetooth, transportEpoch: 5, backendGeneration: 11))
        let active = model.callLifecycleSnapshot
        for event in [
            DeviceCallEvent(agentID: "B", callID: "call-191", state: .ended, transport: .vowlan, transportEpoch: epoch),
            DeviceCallEvent(agentID: "A", callID: "other-call", state: .ended, transport: .vowlan, transportEpoch: epoch),
            DeviceCallEvent(agentID: "A", callID: "call-191", state: .ended, transport: .vowlan, transportEpoch: epoch - 1),
            DeviceCallEvent(agentID: "A", callID: "call-191", state: .ended, transport: .bluetooth,
                transportEpoch: 5, backendGeneration: 10),
            DeviceCallEvent(agentID: "A", callID: "call-191", state: .ended, transport: .bluetooth,
                transportEpoch: 4, backendGeneration: 11)
        ] {
            _ = model.receiveOwnedCallEvent(event)
            XCTAssertEqual(model.callLifecycleSnapshot, active)
            XCTAssertEqual(controller.currentSystemCallUUID, pushed.uuid)
        }

        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "call-191", state: .ended,
            transport: .vowlan, transportEpoch: epoch, backendCallID: "call-191"))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, pushed.callID)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, pushed.uuid)
        XCTAssertEqual(model.callLifecycleSnapshot.generation, pushed.generation)
        XCTAssertNil(controller.currentSystemCallUUID)
        XCTAssertNil(model.remoteCall)
        XCTAssertNotNil(startupInvalidation(), "An in-flight audio startup must not revive the ended APNs call")
        XCTAssertFalse(peer.commands.contains { ["/api/calls/hangup", "/api/calls/reject"].contains($0.path) })
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "call-191", state: .active,
            transport: .vowlan, transportEpoch: epoch + 1))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended, "A late active event cannot revive the call")
        let next = IncomingVoIPCall(bluetoothCallID: "next-call", uuid: UUID(), generation: 1, number: nil, agentID: "A")
        let nextReported = expectation(description: "next call reported")
        controller.reportIncomingPush(next, systemReport: { _, _, done in done(nil) }) { error in
            XCTAssertNil(error); nextReported.fulfill()
        }
        await fulfillment(of: [nextReported], timeout: 2)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "call-191", state: .ended,
            transport: .vowlan, transportEpoch: epoch + 1))
        XCTAssertEqual(controller.currentSystemCallUUID, next.uuid)
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ringing)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "next-call", state: .ended,
            transport: .vowlan, transportEpoch: epoch + 1))
        XCTAssertNil(controller.currentSystemCallUUID)
    }

    func testPushedRemoteEndDuringAnswerCannotRelockOrRestartAudio() async throws {
        let old = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.automatic); AndroidAgentBindingPreference.set("A")
        defer {
            ConnectionModePreference.set(old); AndroidAgentBindingPreference.set(binding)
            IPhoneCloudCallSession.shared.stop()
        }
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        peer.setCallState(nil)
        defer { peer.stop() }
        let endpoint = try await peer.start(), gate = ResponseGate()
        let held = expectation(description: "answer response pending")
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), apiFactory: { route in
            AirSIMAPI(route: route, transport: GatedPeerHTTPTransport(gate: gate, held: held, heldPath: "/api/calls/answer"))
        }, healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        let controller = CallKitController(observesSystemCallbacks: false)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            localDirectory: directory, callKitController: controller,
            historyStore: LocalHistoryStore(directoryURL: path))
        defer { model.stop() }
        directory.stop()
        let pushed = IncomingVoIPCall(bluetoothCallID: "answer-in-flight", uuid: UUID(),
            generation: 7, number: nil, agentID: "A")
        let reported = expectation(description: "APNs system call reported")
        controller.reportIncomingPush(pushed, systemReport: { _, _, done in done(nil) }) { error in
            XCTAssertNil(error); reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 2)
        let answer = Task { try await model.callKitAnswer(uuid: pushed.uuid, origin: .system) }
        await fulfillment(of: [held], timeout: 2)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "answer-in-flight", state: .ended,
            transport: .vowlan, transportEpoch: directory.transportEpoch(for: "A")))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        await gate.release()
        do { try await answer.value; XCTFail("The ended call must invalidate the pending answer") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        XCTAssertNil(controller.currentSystemCallUUID)
        XCTAssertNil(model.remoteCall)
        XCTAssertNotNil(model.makeLocalAudioStartupInvalidationCheck()())
        XCTAssertFalse(peer.commands.contains { $0.path == "/api/calls/audio/host/register" })
    }

    func testMappedVoWLANEndAfterBLEEndClosesPushedCall() async throws {
        for answered in [false, true] {
            for legacyIngress in [false, true] {
                try await assertMappedVoWLANEndAfterBLEEnd(answered: answered, legacyIngress: legacyIngress)
            }
        }
    }

    private func assertMappedVoWLANEndAfterBLEEnd(answered: Bool, legacyIngress: Bool) async throws {
        let old = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.automatic); AndroidAgentBindingPreference.set("A")
        defer {
            ConnectionModePreference.set(old); AndroidAgentBindingPreference.set(binding)
            IPhoneCloudCallSession.shared.stop()
        }
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret,
            callID: "telecom-A", backendCallID: "backend-A")
        peer.setCallState(nil)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        let controller = CallKitController(observesSystemCallbacks: false)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            localDirectory: directory, callKitController: controller,
            historyStore: LocalHistoryStore(directoryURL: path))
        defer { model.stop() }
        directory.stop()
        let pushed = IncomingVoIPCall(bluetoothCallID: "backend-A", uuid: UUID(), generation: 7, number: nil, agentID: "A")
        let reported = expectation(description: "pushed call reported")
        controller.reportIncomingPush(pushed, systemReport: { _, _, done in done(nil) }) { error in
            XCTAssertNil(error); reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 2)
        let epoch = directory.transportEpoch(for: "A")
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "telecom-A", state: .ringing,
            transport: .vowlan, transportEpoch: epoch, backendCallID: "backend-A"))
        if answered { try await model.callKitAnswer(uuid: pushed.uuid, origin: .system) }
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "telecom-A", state: .ended,
            transport: .bluetooth, transportEpoch: 5, backendGeneration: 11))
        let before = model.callLifecycleSnapshot
        XCTAssertEqual(before.state, answered ? .active : .ringing)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "telecom-A", state: .ended,
            transport: .vowlan, transportEpoch: epoch - 1, backendCallID: "backend-A"))
        XCTAssertEqual(model.callLifecycleSnapshot, before, "The tombstone must retain the WLAN epoch watermark")
        peer.setCallState("ended")
        let api = try XCTUnwrap(directory.api(for: "A"))
        let status = try await api.waitForCallEvent(after: 0, timeout: 1)
        let terminal = try XCTUnwrap(status.history?.first)
        if legacyIngress {
            _ = model.receiveDeviceCallEvent(.init(agentID: "A", callID: try XCTUnwrap(terminal.androidID),
                state: .ended, transport: .vowlan, transportEpoch: epoch, backendCallID: terminal.id))
        } else {
            _ = model.applyAgentCallRecord(terminal, forcedState: .ended, agentID: "A")
        }
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, pushed.callID)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, pushed.uuid)
        XCTAssertEqual(model.callLifecycleSnapshot.generation, pushed.generation)
        XCTAssertNil(controller.currentSystemCallUUID)
        XCTAssertFalse(peer.commands.contains { ["/api/calls/hangup", "/api/calls/reject"].contains($0.path) })
    }

    func testColdLaunchPushIsAdoptedBeforeVoWLANAnswer() async throws {
        let old = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.automatic); AndroidAgentBindingPreference.set("A")
        defer {
            ConnectionModePreference.set(old); AndroidAgentBindingPreference.set(binding)
            IPhoneCloudCallSession.shared.stop()
        }
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        peer.setCallState(nil)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        let controller = CallKitController(observesSystemCallbacks: false); controller.setEnabled(true)
        let pushed = IncomingVoIPCall(bluetoothCallID: "cold-call", uuid: UUID(), generation: 7, number: nil, agentID: "A")
        let reported = expectation(description: "push reported before AppModel exists")
        controller.reportIncomingPush(pushed, systemReport: { _, _, done in done(nil) }) { error in
            XCTAssertNil(error); reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 2)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            localDirectory: directory, callKitController: controller,
            historyStore: LocalHistoryStore(directoryURL: path))
        defer { model.stop() }
        directory.stop()
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ringing)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, pushed.uuid)
        try await model.callKitAnswer(uuid: pushed.uuid, origin: .system)
        XCTAssertEqual(model.callLifecycleSnapshot.state, .active)
        XCTAssertTrue(peer.commands.contains { $0.path == "/api/calls/answer" })
        controller.reportCurrentCallEnded(reason: .remoteEnded)
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ending)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "cold-call", state: .ended,
            transport: .vowlan, transportEpoch: directory.transportEpoch(for: "A")))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, pushed.uuid)
        XCTAssertNil(controller.currentSystemCallUUID)
    }

    func testSMSIngestionCapturesAuthenticatedProducerAndAcknowledgesRawDeliveryIDs() async throws {
        let a = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        let b = try AuthenticatedHealthPeer(agentID: "B", secret: bSecret)
        defer { a.stop(); b.stop() }
        let ae = try await a.start(), be = try await b.start()
        let aBoundary = SMSProducerBoundary(), bBoundary = SMSProducerBoundary()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), apiFactory: { route in
            AirSIMAPI(route: route, transport: route.baseURL.port == Int(ae.controlPort) ? aBoundary : bBoundary)
        }, healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: ae, credential: VoWLANCredential(secret: aSecret))
        try await directory.verifyPairing(agentID: "B", endpoint: be, credential: VoWLANCredential(secret: bSecret))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let previous = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.vowlan); AndroidAgentBindingPreference.set("B")
        defer { ConnectionModePreference.set(previous); AndroidAgentBindingPreference.set(binding) }
        let store = LocalHistoryStore(directoryURL: path)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            localDirectory: directory, historyStore: store)
        defer { model.stop() }
        await model.loadMessagesFromAgent(silently: true, reportingAgent: directory.api(for: "A"))
        await model.loadMessagesFromAgent(silently: true, reportingAgent: directory.api(for: "B"))
        XCTAssertEqual(model.messages.count, 2)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.loadMessages())) as? [[String:Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["source_agent_id"] as? String }), ["A","B"])
        XCTAssertEqual(aBoundary.acks, [["same-wire-id"]])
        XCTAssertEqual(bBoundary.acks, [["same-wire-id"]])
    }
    func testUnboundLegacyPairingMigratesOnlyWithFreshIdentityProof() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let store = MemoryWLANCredentials(legacy: try VoWLANCredential(secret: aSecret))
        let directory = LocalDeviceDirectory(credentials: store, legacyBinding: { nil },
            healthTransport: AuthenticatedHealthPeer.transport)
        do { try await directory.verify(agentID: "B", endpoint: endpoint); XCTFail("wrong advertised identity") } catch {}
        XCTAssertNil(store.load(agentID: "B"))
        try await directory.verify(agentID: "A", endpoint: endpoint)
        XCTAssertEqual(store.load(agentID: "A")?.secret, aSecret)
        XCTAssertNotNil(directory.api(for: "A"))
    }

    func testVerifiedDirectoryDrivesModePresentationAndAudioRouteWithoutLegacyBrowser() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        peer.setCallState(nil)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) }, healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        let old = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.vowlan); AndroidAgentBindingPreference.set(nil)
        defer { ConnectionModePreference.set(old); AndroidAgentBindingPreference.set(binding) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), localDirectory: directory)
        defer { model.stop() }
        XCTAssertEqual(model.pairedAndroidAgents.first { $0.id == "A" }?.vowlanOnline, true)
        XCTAssertEqual(model.connectionModePresentation.status, "已连接")
        XCTAssertTrue(model.canStartOutgoingCommand)
        XCTAssertEqual(model.dialPadTransportPresentation?.transport, .vowlan)
        XCTAssertEqual(model.currentAndroidAgent?.id, "A")
        let route = await model.readyVoWLANRoute()
        XCTAssertEqual(route?.0.route, .vowlan(endpoint: endpoint, credential: try VoWLANCredential(secret: aSecret)))
    }
    func testHistoryAckCannotDelayCurrentIncomingEvent() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start(), gate = ResponseGate()
        let held = expectation(description: "history ack pending"), incoming = expectation(description: "incoming delivered")
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: HistoryAckGateTransport(gate: gate, held: held)) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        directory.onHistory = { _, _ in true }
        var seen = false
        directory.onCallEvent = { event in if event.state == .ringing && !seen { seen = true; incoming.fulfill() } }
        directory.start(); defer { directory.stop() }
        await fulfillment(of: [held], timeout: 2)
        await fulfillment(of: [incoming], timeout: 0.3)
        await gate.release()
    }
    func testRestartedPeerResetsEventCursorInsteadOfPollingOldHighRevision() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let cursor = CursorHTTPBoundary()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: cursor) }, healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        directory.start(); defer { directory.stop() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(Array(cursor.afterValues.prefix(3)), [AgentEventCursor.initial, 8, 2])
    }

    func testWatchDialOwnsSourceAndBlocksSecondPhoneDial() async throws {
        let a = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        let b = try AuthenticatedHealthPeer(agentID: "B", secret: bSecret)
        defer { a.stop(); b.stop() }
        a.setCallState(nil); b.setCallState(nil)
        let ae = try await a.start(), be = try await b.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: ae, credential: VoWLANCredential(secret: aSecret))
        try await directory.verifyPairing(agentID: "B", endpoint: be, credential: VoWLANCredential(secret: bSecret))
        let old = ConnectionModePreference.selected(), binding = AndroidAgentBindingPreference.selected()
        ConnectionModePreference.set(.vowlan)
        defer { ConnectionModePreference.set(old); AndroidAgentBindingPreference.set(binding) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), localDirectory: directory)
        model.bindAndroidAgent("A")
        let replied = expectation(description: "Watch dial reply")
        var reply: [String: Any] = [:]
        WatchCallCoordinator.shared.session(WCSession.default, didReceiveMessage: ["action": "dial",
            "number": "123", "request_id": UUID().uuidString]) { value in reply = value; replied.fulfill() }
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        guard reply["ok"] as? Bool == true else { model.stop(); return }
        XCTAssertEqual(model.deviceCalls.active?.agentID, "A")
        XCTAssertEqual(model.deviceCallContext.media.owner?.agentID, "A")
        model.bindAndroidAgent("B")
        do { try await model.callKitStart(number: "123"); XCTFail("second phone dial must be rejected") }
        catch { XCTAssertEqual(error as? DeviceCallRoutingError, .busy) }
        XCTAssertFalse(b.commands.contains { $0.path == "/api/calls/dial" })
        let ended = expectation(description: "Watch end reply")
        WatchCallCoordinator.shared.session(WCSession.default, didReceiveMessage: ["action": "watch_local_end",
            "call_id": reply["call_id"] ?? "", "call_uuid": reply["call_uuid"] ?? ""]) { value in
                XCTAssertEqual(value["ok"] as? Bool, true); ended.fulfill()
            }
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertTrue(a.commands.contains { $0.path == "/api/calls/hangup" && $0.callID == "backend-A" })
        model.stop()
    }

    func testTwoPeerHistoryKeepsLegacyAndAcknowledgesEachProducer() async throws {
        let a = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret, callID: "same", backendCallID: "same")
        let b = try AuthenticatedHealthPeer(agentID: "B", secret: bSecret, callID: "same", backendCallID: "same")
        defer { a.stop(); b.stop() }
        a.setCallState("ended"); b.setCallState("ended")
        let ae = try await a.start(), be = try await b.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: ae, credential: VoWLANCredential(secret: aSecret))
        try await directory.verifyPairing(agentID: "B", endpoint: be, credential: VoWLANCredential(secret: bSecret))
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(old) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), localDirectory: directory)
        let now = Date()
        model.callHistory = [.init(id: "same", index: 0, direction: "incoming", state: "ended", number: nil,
            startedAt: now, updatedAt: now, endedAt: now, missed: true)]
        directory.start(); defer { directory.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (model.callHistory.count < 3 || a.commands.filter { $0.path == "/api/calls/history/ack" }.isEmpty
            || b.commands.filter { $0.path == "/api/calls/history/ack" }.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.callHistory.count, 3)
        XCTAssertEqual(Set(model.callHistory.compactMap(\.sourceAgentID)), ["A", "B"])
        XCTAssertEqual(a.commands.filter { $0.path == "/api/calls/history/ack" }.count, 1)
        XCTAssertEqual(b.commands.filter { $0.path == "/api/calls/history/ack" }.count, 1)
    }

    func testRecoveryCannotRestoreTrustFromStatusAfterInvalidHealthProof() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let boundary = RecoveryHTTPBoundary()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { route in AirSIMAPI(route: route, transport: RecoveryTransport(boundary: boundary)) }, healthTransport: { request in
                if boundary.firstHealth() { return try await AuthenticatedHealthPeer.transport(request) }
                return WiredHTTPResponse(statusCode: 200, body: Data(#"{"ok":true,"agent_id":"A"}"#.utf8))
            })
        try await directory.verifyPairing(agentID: "A", endpoint: endpoint, credential: VoWLANCredential(secret: aSecret))
        var events = 0
        directory.onCallEvent = { _ in events += 1 }
        directory.start(); defer { directory.stop() }
        try await Task.sleep(for: .milliseconds(2400))
        XCTAssertNil(directory.api(for: "A"))
        XCTAssertEqual(events, 0)
    }

    func testOwnedWLANLossEndsOnlyItsSourceAfterRecoveryGrace() async throws {
        let a = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        let b = try AuthenticatedHealthPeer(agentID: "B", secret: bSecret)
        defer { a.stop(); b.stop() }
        let ae = try await a.start(), be = try await b.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(), healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: ae, credential: VoWLANCredential(secret: aSecret))
        try await directory.verifyPairing(agentID: "B", endpoint: be, credential: VoWLANCredential(secret: bSecret))
        // Keep this fixture deterministic: no subscriptions/recovery can mask failed health.
        let oldMode = ConnectionModePreference.selected()
        ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(oldMode) }
        let backend = LossBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in backend }, localDirectory: directory)
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        do { try await directory.verifyPairing(agentID: "B", endpoint: be, credential: VoWLANCredential(secret: aSecret)) }
        catch {}
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(model.deviceCalls.active, route.key)
        XCTAssertTrue(backend.ended.isEmpty)
        do { try await directory.verifyPairing(agentID: "A", endpoint: ae, credential: VoWLANCredential(secret: bSecret)) }
        catch {}
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertEqual(backend.ended, ["fixture"])
        await model.hangup()
    }

    func testProductionTwoDeviceChainUsesAuthenticatedAPIsAndNeverRetargetsA() async throws {
        let previousMode = ConnectionModePreference.selected()
        ConnectionModePreference.set(.vowlan)
        defer { ConnectionModePreference.set(previousMode) }
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let a = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret, callID: "telecom-A", backendCallID: "backend-A")
        let b = try AuthenticatedHealthPeer(agentID: "B", secret: bSecret, callID: "telecom-B", backendCallID: "backend-B", dialSuffix: "-next")
        a.setCallState(nil); b.setCallState(nil)
        defer { a.stop(); b.stop() }
        let ae = try await a.start(), be = try await b.start()
        let directory = LocalDeviceDirectory(credentials: MemoryWLANCredentials(),
            apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verifyPairing(agentID: "A", endpoint: ae, credential: VoWLANCredential(secret: aSecret))
        try await directory.verifyPairing(agentID: "B", endpoint: be, credential: VoWLANCredential(secret: bSecret))
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            localDirectory: directory, callKitController: CallKitController(), historyStore: LocalHistoryStore(directoryURL: historyURL))
        defer { model.stop() }
        let oldBinding = AndroidAgentBindingPreference.selected()
        defer { AndroidAgentBindingPreference.set(oldBinding) }
        let ringing = expectation(description: "B real authenticated subscription"), ended = expectation(description: "B terminal")
        var gotRinging = false, gotEnded = false
        let consume = directory.onCallEvent
        directory.onCallEvent = { event in
            consume?(event)
            if event.agentID == "B", event.state == .ringing, !gotRinging { gotRinging = true; ringing.fulfill() }
            if event.agentID == "B", event.state == .ended, !gotEnded { gotEnded = true; ended.fulfill() }
        }
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        try await model.deviceCallRouter.sendDTMF("5", for: route.key)
        XCTAssertTrue(a.commands.contains { $0.path == "/api/calls/dtmf" && $0.callID == "backend-A" })
        model.bindAndroidAgent("B")
        let sent = await model.sendSMS(to: "123", content: "fixture only")
        XCTAssertTrue(sent)
        XCTAssertEqual(b.commands.filter { $0.path == "/api/sms/send" }.count, 1)
        XCTAssertFalse(a.commands.contains { $0.path == "/api/sms/send" })
        let started = model.remoteCall?.startedAt
        b.setCallState("incoming")
        await fulfillment(of: [ringing], timeout: 4)
        XCTAssertEqual(model.deviceCalls.active, route.key)
        XCTAssertEqual(model.deviceCallContext.media.owner, route.key)
        XCTAssertEqual(model.remoteCall?.startedAt, started)
        XCTAssertEqual(model.otherDeviceCallReminders.map(\.key.agentID), ["B"])
        XCTAssertFalse(b.commands.contains { $0.path == "/api/calls/answer" || $0.path.contains("audio") })
        b.setCallState("ended")
        await fulfillment(of: [ended], timeout: 4)
        XCTAssertTrue(model.callHistory.contains { $0.sourceAgentID == "B" && $0.sourceCallID == "backend-B" })
        XCTAssertEqual(model.deviceCalls.active, route.key)
        XCTAssertTrue(model.otherDeviceCallReminders.isEmpty)
        await model.hangup()
        XCTAssertTrue(a.commands.contains { $0.path == "/api/calls/hangup" && $0.callID == "backend-A" })
        XCTAssertFalse(b.commands.contains { $0.path == "/api/calls/hangup" })
        model.bindAndroidAgent("B")
        try await model.callKitStart(number: "fixture")
        XCTAssertEqual(model.deviceCalls.active?.agentID, "B")
        XCTAssertEqual(a.commands.filter { $0.path == "/api/calls/dial" }.count, 1)
        XCTAssertEqual(b.commands.filter { $0.path == "/api/calls/dial" }.count, 1)
        await model.hangup()
    }

    func testPairingBDoesNotOverwriteACredentialOrRoute() async throws {
        let a = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        let b = try AuthenticatedHealthPeer(agentID: "B", secret: bSecret)
        defer { a.stop(); b.stop() }
        let aEndpoint = try await a.start(), bEndpoint = try await b.start()
        let store = MemoryWLANCredentials()
        let aCredential = try VoWLANCredential(secret: aSecret)
        try store.save(aCredential, agentID: "A")
        let directory = LocalDeviceDirectory(credentials: store, healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verify(agentID: "A", endpoint: aEndpoint)
        try await directory.verifyPairing(agentID: "B", endpoint: bEndpoint,
            credential: VoWLANCredential(secret: bSecret))
        XCTAssertEqual(store.load(agentID: "A"), aCredential)
        XCTAssertEqual(store.load(agentID: "B")?.secret, bSecret)
        XCTAssertEqual(directory.routes(for: "A")?.vowlan, aEndpoint)
        XCTAssertEqual(directory.routes(for: "B")?.vowlan, bEndpoint)
        XCTAssertEqual(a.requests, 1); XCTAssertEqual(b.requests, 1)
    }

    func testWrongHealthIdentityCannotJoinTwoTransports() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "B", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let store = MemoryWLANCredentials()
        try store.save(VoWLANCredential(secret: aSecret), agentID: "A")
        let directory = LocalDeviceDirectory(credentials: store, healthTransport: AuthenticatedHealthPeer.transport)
        do { try await directory.verify(agentID: "A", endpoint: endpoint); XCTFail("wrong identity accepted") } catch {}
        XCTAssertNil(directory.routes(for: "A")?.vowlan)
        XCTAssertNil(directory.routes(for: "B"))
        XCTAssertEqual(peer.requests, 1)
    }

    func testLegacyCredentialMigratesOnlyAfterAuthenticatedBinding() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let store = MemoryWLANCredentials(legacy: try VoWLANCredential(secret: aSecret))
        let directory = LocalDeviceDirectory(credentials: store, legacyBinding: { "A" },
            healthTransport: AuthenticatedHealthPeer.transport)
        do { try await directory.verify(agentID: "B", endpoint: endpoint); XCTFail("legacy key copied to stranger") } catch {}
        XCTAssertNil(store.load(agentID: "B"))
        XCTAssertEqual(peer.requests, 0)
        try await directory.verify(agentID: "A", endpoint: endpoint)
        XCTAssertEqual(store.load(agentID: "A")?.secret, aSecret)
        XCTAssertEqual(peer.requests, 1)
    }

    func testHTTP200WithoutHMACNeverMakesDeviceReady() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret, includeProof: false)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let store = MemoryWLANCredentials()
        try store.save(VoWLANCredential(secret: aSecret), agentID: "A")
        let directory = LocalDeviceDirectory(credentials: store, healthTransport: AuthenticatedHealthPeer.transport)
        do { try await directory.verify(agentID: "A", endpoint: endpoint); XCTFail("unsigned 200 accepted") } catch {}
        XCTAssertNil(directory.api(for: "A"))
        XCTAssertEqual(peer.requests, 1)
    }

    func testDefaultDialBindingDoesNotFilterBIncomingEvents() async throws {
        let a = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        let b = try AuthenticatedHealthPeer(agentID: "B", secret: bSecret)
        defer { a.stop(); b.stop() }
        let aEndpoint = try await a.start(), bEndpoint = try await b.start()
        let store = MemoryWLANCredentials()
        try store.save(VoWLANCredential(secret: aSecret), agentID: "A")
        try store.save(VoWLANCredential(secret: bSecret), agentID: "B")
        let directory = LocalDeviceDirectory(credentials: store, legacyBinding: { "A" },
            apiFactory: { AirSIMAPI(route: $0, transport: PeerHTTPTransport()) },
            healthTransport: AuthenticatedHealthPeer.transport)
        defer { directory.stop() }
        try await directory.verify(agentID: "A", endpoint: aEndpoint)
        try await directory.verify(agentID: "B", endpoint: bEndpoint)
        let incoming = expectation(description: "B incoming while default remains A")
        var received: [DeviceCallEvent] = []
        var deliveredB = false
        directory.onCallEvent = { event in
            received.append(event)
            if event.agentID == "B", !deliveredB { deliveredB = true; incoming.fulfill() }
        }
        directory.start()
        await fulfillment(of: [incoming], timeout: 2)
        XCTAssertTrue(received.contains { $0.agentID == "B" && $0.callID == "call-B" && $0.state == .ringing })
        XCTAssertNotNil(directory.api(for: "A"))
    }

    func testDeletedDeviceCannotReappearFromSavedRoute() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let store = MemoryWLANCredentials(legacy: try VoWLANCredential(secret: aSecret))
        try store.save(VoWLANCredential(secret: aSecret), agentID: "A")
        let directory = LocalDeviceDirectory(credentials: store, legacyBinding: { "A" },
            healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verify(agentID: "A", endpoint: endpoint)
        try await directory.forget(agentID: "A")
        do { try await directory.verify(agentID: "A", endpoint: endpoint); XCTFail("deleted credentials were reused") } catch {}
        XCTAssertNil(directory.api(for: "A"))
        XCTAssertNil(store.load(agentID: "A"))
        XCTAssertEqual(peer.requests, 1)
    }

    func testManualRouteAndBonjourMergeKeepTheVerifiedAgent() async throws {
        let manual = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        let bonjour = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { manual.stop(); bonjour.stop() }
        let old = try await manual.start(), fresh = try await bonjour.start()
        let store = MemoryWLANCredentials()
        try store.save(VoWLANCredential(secret: aSecret), agentID: "A")
        let directory = LocalDeviceDirectory(credentials: store, healthTransport: AuthenticatedHealthPeer.transport)
        try await directory.verify(agentID: "A", endpoint: old)
        try await directory.verify(agentID: "A", endpoint: fresh)
        XCTAssertEqual(directory.agentIDs, ["A"])
        XCTAssertEqual(directory.routes(for: "A")?.vowlan, fresh)
        XCTAssertNil(directory.metadata(for: "A")?.phoneNumber)
    }

    func testEndpointReplacementDropsOldPollResponse() async throws {
        let old = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret, callID: "old-call")
        let fresh = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret, callID: "new-call")
        defer { old.stop(); fresh.stop() }
        let oldEndpoint = try await old.start(), newEndpoint = try await fresh.start()
        let store = MemoryWLANCredentials()
        try store.save(VoWLANCredential(secret: aSecret), agentID: "A")
        let held = expectation(description: "old endpoint has pending event response")
        let gate = ResponseGate()
        let directory = LocalDeviceDirectory(credentials: store,
            apiFactory: { route in
                if case let .vowlan(endpoint, _) = route, endpoint == oldEndpoint {
                    return AirSIMAPI(route: route, transport: GatedPeerHTTPTransport(gate: gate, held: held))
                }
                return AirSIMAPI(route: route, transport: PeerHTTPTransport())
            }, healthTransport: AuthenticatedHealthPeer.transport)
        defer { directory.stop() }
        try await directory.verify(agentID: "A", endpoint: oldEndpoint)
        directory.start()
        await fulfillment(of: [held], timeout: 2)
        let current = expectation(description: "new endpoint event delivered")
        let stale = expectation(description: "old endpoint event suppressed"); stale.isInverted = true
        var deliveredCurrent = false
        directory.onCallEvent = { event in
            if event.callID == "new-call", !deliveredCurrent { deliveredCurrent = true; current.fulfill() }
            if event.callID == "old-call" { stale.fulfill() }
        }
        try await directory.verify(agentID: "A", endpoint: newEndpoint)
        await gate.release()
        await fulfillment(of: [current, stale], timeout: 2)
        XCTAssertEqual(directory.routes(for: "A")?.vowlan, newEndpoint)
    }

    func testOwnedDialReceiptPreservesCanonicalAndBackendIdentities() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: try VoWLANCredential(secret: aSecret)),
            transport: PeerHTTPTransport())
        let receipt = try await api.dialOwnedCall(number: "fixture-no-real-call", operationID: "operation-A")
        XCTAssertEqual(receipt.callID, "telecom-A")
        XCTAssertEqual(receipt.backendID, "backend-A")
    }

    func testOwnedDialReceiptRejectsProofForAnotherOperation() async throws {
        let peer = try AuthenticatedHealthPeer(agentID: "A", secret: aSecret, includeProof: false)
        defer { peer.stop() }
        let endpoint = try await peer.start()
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: try VoWLANCredential(secret: aSecret)),
            transport: PeerHTTPTransport())
        do {
            _ = try await api.dialOwnedCall(number: "fixture-no-real-call", operationID: "operation-A")
            XCTFail("receipt for another operation was accepted")
        } catch { XCTAssertEqual(error as? DeviceCallRoutingError, .unsupportedPeer) }
    }
}

private final class RecoveryHTTPBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var health = true, status = true
    func firstHealth() -> Bool { lock.withLock { defer { health = false }; return health } }
    func failFirstStatus() -> Bool { lock.withLock { defer { status = false }; return status } }
}

private struct RecoveryTransport: AirSIMHTTPTransport {
    let boundary: RecoveryHTTPBoundary
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        if boundary.failFirstStatus() { throw URLError(.networkConnectionLost) }
        return try await AuthenticatedHealthPeer.transport(request)
    }
}

private final class CursorHTTPBoundary: AirSIMHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var values = [UInt64]()
    var afterValues: [UInt64] { lock.withLock { values } }
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value.flatMap(UInt64.init) ?? 0
        let revision = lock.withLock { values.append(after); return values.count == 1 ? 8 : 2 }
        return WiredHTTPResponse(statusCode: 200, body: Data("{\"active\":null,\"history\":[],\"polling\":true,\"poll_interval_s\":2,\"last_poll_error\":\"\",\"revision\":\(revision)}".utf8))
    }
}

@MainActor
private final class LossBackend: DeviceCallBackend {
    let epoch: UInt64 = 1
    var ended = [String]()
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        .init(callID: "fixture", backendID: "fixture", generation: nil)
    }
    func answer(callID: String, generation: UInt64?) async throws {}
    func end(callID: String, generation: UInt64?, reject: Bool) async throws { ended.append(callID) }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws {}
}

private actor ResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async { if !open { await withCheckedContinuation { continuation = $0 } } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

private struct GatedPeerHTTPTransport: AirSIMHTTPTransport {
    let gate: ResponseGate
    let held: XCTestExpectation
    var heldPath = "/api/calls/events"
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        let response = try await AuthenticatedHealthPeer.transport(request)
        if request.url?.path == heldPath { held.fulfill(); await gate.wait() }
        return response
    }
}

private struct HistoryAckGateTransport: AirSIMHTTPTransport {
    let gate: ResponseGate
    let held: XCTestExpectation
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        if request.url?.path == "/api/calls/history/ack" { held.fulfill(); await gate.wait() }
        let response = try await AuthenticatedHealthPeer.transport(request)
        if request.url?.path == "/api/calls/events",
           var json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] {
            json["history"] = [["id": "old", "android_id": "old", "index": 0, "direction": "incoming",
                "state": "ended", "started_at": "2026-10-17T10:00:00Z", "updated_at": "2026-10-17T10:00:01Z",
                "ended_at": "2026-10-17T10:00:01Z", "missed": true]]
            return WiredHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: json))
        }
        return response
    }
}

private final class SMSProducerBoundary: AirSIMHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String]] = []
    var acks: [[String]] { lock.withLock { captured } }
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        if request.url?.path == "/api/sms" {
            return .init(statusCode: 200, body: Data(
                #"[{"sender":"fixture","content":"same","timestamp":"2026-10-18T00:00:00Z","delivery_id":"same-wire-id","source_agent_id":"untrusted"}]"#.utf8))
        }
        if request.url?.path == "/api/sms/ack" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String:Any]
            lock.withLock { captured.append(body?["ids"] as? [String] ?? []) }
            return .init(statusCode: 200, body: Data("{}".utf8))
        }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}

private struct PeerHTTPTransport: AirSIMHTTPTransport {
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        XCTAssertNil(uploadFileURL)
        return try await AuthenticatedHealthPeer.transport(request)
    }
}

private final class MemoryWLANCredentials: LocalDeviceCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: VoWLANCredential] = [:]
    private let old: VoWLANCredential?
    init(legacy: VoWLANCredential? = nil) { old = legacy }
    func load(agentID: String) -> VoWLANCredential? { lock.withLock { values[agentID] } }
    func save(_ credential: VoWLANCredential, agentID: String) throws { lock.withLock { values[agentID] = credential } }
    func remove(agentID: String) { _ = lock.withLock { values.removeValue(forKey: agentID) } }
    func legacy() -> VoWLANCredential? { old }
}

private final class AuthenticatedHealthPeer: @unchecked Sendable {
    private let listener: NWListener
    private let agentID: String
    private let secret: Data
    private let includeProof: Bool
    private let callID: String
    private let backendCallID: String
    private let dialSuffix: String
    private let deviceName: String?
    struct Command { let path: String; let callID: String? }
    private var commandLog = [Command]()
    private var callState: String? = "incoming"
    private let lock = NSLock()
    private var requestCount = 0
    private var nonces = Set<String>()
    private var connections: [NWConnection] = []
    var requests: Int { lock.withLock { requestCount } }
    var commands: [Command] { lock.withLock { commandLog } }
    func setCallState(_ value: String?) { lock.withLock { callState = value } }

    init(agentID: String, secret: Data, includeProof: Bool = true, callID: String? = nil, backendCallID: String? = nil, dialSuffix: String = "", deviceName: String? = "Fixture Android") throws {
        self.agentID = agentID; self.secret = secret; self.includeProof = includeProof
        self.callID = callID ?? "call-\(agentID)"
        self.backendCallID = backendCallID ?? self.callID
        self.dialSuffix = dialSuffix
        self.deviceName = deviceName
        listener = try NWListener(using: .tcp)
    }
    func start() async throws -> VoWLANEndpoint {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: DispatchQueue(label: "AirSIMTests.health-peer"))
            self.receive(connection, accumulated: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port {
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(with: Result { try VoWLANEndpoint(host: "10.0.0.1",
                        controlPort: port.rawValue, pcmPort: 39001) })
                } else if case .failed(let error) = state {
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: DispatchQueue(label: "AirSIMTests.health-listener"))
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let bytes = accumulated + data
            guard let text = String(data: bytes, encoding: .utf8), let split = text.range(of: "\r\n\r\n") else {
                if !complete { self.receive(connection, accumulated: bytes) }; return
            }
            let header = String(text[..<split.lowerBound])
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            if text[split.upperBound...].utf8.count < length { self.receive(connection, accumulated: bytes); return }
            self.respond(connection, request: text)
        }
    }
    private func respond(_ connection: NWConnection, request: String) {
        lock.withLock { requestCount += 1 }
        let headers = request.components(separatedBy: "\r\n").dropFirst().reduce(into: [String: String]()) { result, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            result[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let nonce = headers["x-airsim-vowlan-nonce"] ?? ""
        let timestamp = headers["x-airsim-vowlan-timestamp"] ?? ""
        let rawBody = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let digest = SHA256.hash(data: Data(rawBody.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = request.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let path = target.split(separator: "?").first.map(String.init) ?? ""
        let method = request.components(separatedBy: "\r\n").first?.split(separator: " ").first.map(String.init) ?? "GET"
        let expected = mac("\(method)\n\(target)\n\(digest)\n\(timestamp)\n\(nonce)")
        let valid = headers["x-airsim-vowlan-signature"] == expected && !nonce.isEmpty
            && lock.withLock { nonces.insert(nonce).inserted }
        var responseStatus = valid ? 200 : 401
        if valid, method == "POST" {
            let input = (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: Any]
            let callID = input?["call_id"] as? String
            lock.withLock { commandLog.append(.init(path: path, callID: callID)) }
            if path == "/api/calls/answer", let callID, callID != backendCallID { responseStatus = 502 }
        }
        var json: [String: Any] = ["ok": valid, "agent_id": agentID, "canonical_call_ids": true]
        json["device_name"] = deviceName
        if includeProof { json["identity_proof"] = mac("AIRSIM-HEALTH1\n\(nonce)\n\(agentID)") }
        if path == "/api/calls/dial" {
            let input = (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: String] ?? [:]
            let operation = input["operation_id"] ?? ""
            json = ["operation_id": operation, "android_id": "telecom-\(agentID)\(dialSuffix)", "backend_id": "backend-\(agentID)\(dialSuffix)",
                "operation_proof": mac("AIRSIM-DIAL1\n\(nonce)\n\(includeProof ? operation : "other-operation")\ntelecom-\(agentID)\(dialSuffix)\nbackend-\(agentID)\(dialSuffix)")]
        }
        if path == "/api/sms/send" { json = ["sent": true, "segments": 1] }
        if path == "/api/calls/events" {
            let state = lock.withLock { callState }
            var call: [String: Any] = ["id": backendCallID, "android_id": callID, "index": 1,
                    "direction": state == "incoming" ? "incoming" : "outgoing", "state": state ?? "ended",
                    "number": "", "started_at": "2026-10-17T12:00:00Z", "updated_at": "2026-10-17T12:00:00Z",
                    "missed": false]
            if state == "ended" { call["ended_at"] = "2026-10-17T12:01:00Z" }
            json = ["active": state != nil && state != "ended" ? call : NSNull(),
                    "history": state == "ended" ? [call] : [], "polling": true, "poll_interval_s": 2,
                    "last_poll_error": "", "revision": 1]
        }
        if responseStatus == 502 { json = ["error": "active call id mismatch"] }
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let head = "HTTP/1.1 \(responseStatus) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
    private func mac(_ value: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: secret)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static let transport: LocalDeviceDirectory.HealthTransport = { request in
        var local = request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.host = "127.0.0.1" // OS socket boundary only; signed path/nonce/body remain real.
        local.url = url.url!
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: local)
        return WiredHTTPResponse(statusCode: (response as! HTTPURLResponse).statusCode, body: data)
    }
    func stop() { listener.cancel(); lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() } }
}
