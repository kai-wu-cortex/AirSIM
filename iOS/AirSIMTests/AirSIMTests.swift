import CryptoKit
import CoreBluetooth
import AVFoundation
import XCTest
import Contacts
import Network
@testable import AirSIM

@MainActor
final class CallUpdateWorkSchedulerTests: XCTestCase {
    func testEarlyBluetoothHangupAcceptsTerminalIDHandoffWithoutReopeningCall() {
        var store = CallLifecycleStore()
        let uuid = UUID(), now = Date(timeIntervalSince1970: 100)
        func event(_ id: String, _ state: CallLifecycleState,
                   _ source: CallLifecycleSource = .agent) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 4, state: state,
                  source: source, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event("pending", .connecting)))
        XCTAssertTrue(store.apply(event("pending", .ending, .app)))
        XCTAssertFalse(store.apply(event("telecom", .active), replacingProvisionalCallID: "pending"))
        XCTAssertEqual(store.snapshot.state, .ending)
        XCTAssertTrue(store.apply(event("telecom", .ended), replacingProvisionalCallID: "pending"))
        XCTAssertEqual(store.snapshot.callID, "telecom")
        XCTAssertEqual(store.snapshot.state, .ended)
        XCTAssertFalse(store.apply(event("telecom", .active)))
        XCTAssertFalse(store.apply(event("pending", .active)))
    }

    func testLateBluetoothActivityRecordCannotSurviveHangupOrReplaceNewCall() {
        var store = CallLifecycleStore()
        let uuid = UUID(), now = Date(timeIntervalSince1970: 100)
        let old = CallRecord(id: "old-ble", index: 0, direction: "outgoing", state: "active",
                             number: "10010", startedAt: now, updatedAt: now, endedAt: nil, missed: false)
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 4, state: state,
                  source: .agent, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event("old-ble", uuid, .active)))
        XCTAssertNotNil(store.presentationRecord(from: old))
        XCTAssertTrue(store.apply(event("old-ble", uuid, .ending)))
        XCTAssertNil(store.presentationRecord(from: old), "Queued active data cannot bypass local hangup intent")
        XCTAssertTrue(store.apply(event("old-ble", uuid, .ended)))
        let state = LiveActivityStateBuilder.make(call: store.presentationRecord(from: old),
            callerName: nil, moduleOnline: true, transport: .bluetooth, radio: nil, idleStartedAt: now)
        XCTAssertEqual(state.phase, .standby)
        XCTAssertEqual(state.callID, "")
        XCTAssertTrue(store.apply(event("new-ble", UUID(), .ringing)))
        XCTAssertNil(store.presentationRecord(from: old), "Old async updates cannot display a replacement's old call")
    }

    func testActivityBuilderNeverTurnsTerminalOrEndingRecordIntoRunningTimer() {
        let now = Date(timeIntervalSince1970: 100)
        for phase in ["ending", "ended", "failed"] {
            let call = CallRecord(id: "finished", index: 0, direction: "outgoing", state: phase,
                                  number: "10010", startedAt: now, updatedAt: now, endedAt: nil, missed: false)
            let state = LiveActivityStateBuilder.make(call: call, callerName: nil, moduleOnline: true,
                transport: .bluetooth, radio: nil, idleStartedAt: now)
            XCTAssertEqual(state.phase, .standby, phase)
            XCTAssertEqual(state.callID, "", phase)
        }
    }

    func testBluetoothBackendIDAdoptionAllowsMatchingEndToClearActivity() {
        var store = CallLifecycleStore()
        let uuid = UUID()
        let now = Date(timeIntervalSince1970: 100)
        func event(_ id: String, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 4, state: state,
                  source: .agent, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event("iphone-provisional", .connecting)))
        XCTAssertTrue(store.apply(event("android-telecom", .active),
                                  replacingProvisionalCallID: "iphone-provisional"))
        XCTAssertEqual(store.snapshot.callID, "android-telecom")
        XCTAssertTrue(store.apply(event("android-telecom", .ended)))
        XCTAssertFalse(store.snapshot.state.representsCall,
                       "A matching Bluetooth hangup must clear the activity's call source")
        XCTAssertFalse(store.apply(event("iphone-provisional", .active)))
        XCTAssertFalse(store.apply(event("android-telecom", .active)))
    }

    func testBluetoothIdentityAdoptionCannotReplaceAnotherCallOrUndoHangup() {
        let uuid = UUID(), now = Date(timeIntervalSince1970: 100)
        func event(_ id: String, _ idUUID: UUID, _ generation: UInt64,
                   _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: idUUID, generation: generation, state: state,
                  source: .agent, timestamp: now, traceID: nil, failure: nil)
        }
        var store = CallLifecycleStore()
        XCTAssertTrue(store.apply(event("pending", uuid, 4, .connecting)))
        XCTAssertFalse(store.apply(event("real", UUID(), 4, .active), replacingProvisionalCallID: "pending"))
        XCTAssertFalse(store.apply(event("real", uuid, 5, .active), replacingProvisionalCallID: "pending"))
        XCTAssertFalse(store.apply(event("real", uuid, 4, .active), replacingProvisionalCallID: "wrong"))
        XCTAssertEqual(store.snapshot.callID, "pending")
        XCTAssertTrue(store.apply(event("pending", uuid, 4, .ending)))
        XCTAssertFalse(store.apply(event("real", uuid, 4, .active), replacingProvisionalCallID: "pending"))
        XCTAssertEqual(store.snapshot.state, .ending)
    }

    func testPairingCryptoAndCredentialIOStayOffMainThread() async throws {
        let store = PairingThreadProbe()
        let worker = VoBLEPairingWorker(store: store)
        let androidPrivate = Curve25519.KeyAgreement.PrivateKey()
        let prepared = try await worker.prepare(identity: "fixture",
            androidPublic: androidPrivate.publicKey.rawRepresentation,
            androidNonce: Data(repeating: 7, count: 32))
        let remote = try VoBLESessionAuthenticator.derivePairing(
            privateKey: androidPrivate.rawRepresentation,
            peerPublicKey: prepared.publicKey, transcript: prepared.transcript)
        XCTAssertEqual(remote, prepared.material)
        try await worker.save(VoBLEStoredPeer(identity: "fixture",
            pairingKey: prepared.material.pairingKey, createdAt: Date()))
        XCTAssertEqual(store.observedMainThread, [false, false])
    }

    func testExplicitBluetoothUsesEventsInsteadOfInheritedHTTPPolling() {
        XCTAssertFalse(AppRefreshPolicy.shouldRunAgentPolling(mode: .bluetooth))
        XCTAssertTrue(AppRefreshPolicy.shouldRunAgentPolling(mode: .vowlan))
        XCTAssertTrue(AppRefreshPolicy.shouldRunAgentPolling(mode: .automatic))
        XCTAssertTrue(AppRefreshPolicy.shouldRunAgentPolling(mode: .cloud))
    }

    func testScreenLockCannotExpirePendingOrSystemBluetoothReconnection() {
        XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(state: .connecting, enabled: true,
            elapsed: 120, isBackground: true, systemReconnecting: false))
        XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(state: .connecting, enabled: true,
            elapsed: 120, isBackground: false, systemReconnecting: true))
        XCTAssertTrue(VoBLEConnectionTimeoutPolicy.shouldExpire(state: .connecting, enabled: true,
            elapsed: 8, isBackground: false, systemReconnecting: false))
    }

    func testOldBluetoothSubscriptionCannotFailReplacementWithSameUUID() {
        let uuid = CBUUID(string: "7e57a002-7a17-4d9f-9a3c-41a17b1e0001")
        let old = CBMutableCharacteristic(type: uuid, properties: .indicate, value: nil, permissions: .readable)
        let current = CBMutableCharacteristic(type: uuid, properties: .indicate, value: nil, permissions: .readable)
        XCTAssertFalse(VoBLECharacteristicCallbackPolicy.accepts(old, current: [current]))
        XCTAssertTrue(VoBLECharacteristicCallbackPolicy.accepts(current, current: [current]))
        XCTAssertFalse(VoBLECharacteristicCallbackPolicy.accepts(old, current: [nil]))
    }

    func testInvalidatedBluetoothServicesRequireFreshSubscriptionsAndAuthentication() {
        var reducer = VoBLEConnectionReducer()
        reducer.apply(.discovered(UUID()))
        reducer.apply(.connected)
        reducer.apply(.characteristicsReady)
        reducer.apply(.controlSubscription(true))
        reducer.apply(.authenticated(identity: "fixture"))
        XCTAssertEqual(reducer.state, .ready)
        reducer.apply(.servicesInvalidated)
        XCTAssertNil(reducer.authenticatedIdentity)
        XCTAssertEqual(reducer.state, .connected)
        reducer.apply(.authenticated(identity: "fixture"))
        XCTAssertNotEqual(reducer.state, .ready)
        reducer.apply(.characteristicsReady)
        XCTAssertNotEqual(reducer.state, .ready)
        reducer.apply(.controlSubscription(true))
        XCTAssertEqual(reducer.state, .ready)
    }

    func testEndedCallCannotRegisterAfterPhoneActivationReturns() async throws {
        var current = true
        var registrations = 0
        var rollbacks = 0
        let result = await LocalCallAudioStartupCoordinator.start(
            isCurrent: { current },
            activatePhoneAudio: { current = false; return true },
            registerAgentAudio: { registrations += 1; return .registered },
            rollbackPhoneAudio: { rollbacks += 1 }
        )
        XCTAssertEqual(result, .callNoLongerActive)
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(rollbacks, 1)
    }

    func testEndedCallCannotLockRouteAfterRegistrationReturns() async throws {
        var current = true
        var rollbacks = 0
        let result = await LocalCallAudioStartupCoordinator.start(
            isCurrent: { current }, activatePhoneAudio: { true },
            registerAgentAudio: { current = false; return .registered },
            rollbackPhoneAudio: { rollbacks += 1 }
        )
        XCTAssertEqual(result, .callNoLongerActive)
        XCTAssertEqual(rollbacks, 1)
    }

    func testAudioStartupTraceSurvivesDisabledVerboseWithoutCallIdentifiers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("audio-trace.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AgentVerboseTraceRecorder(initiallyEnabled: false, maxEntries: 10, persistenceURL: file)
        await recorder.recordAudioStartup(phase: "engine_ready", elapsedMilliseconds: 180)
        await recorder.recordAudioStartup(phase: "call_id=private")
        let restored = AgentVerboseTraceRecorder(initiallyEnabled: false, maxEntries: 10, persistenceURL: file)
        let entries = await restored.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.category, "call-audio")
        XCTAssertEqual(entries.first?.elapsedMilliseconds, 180)
        XCTAssertEqual(entries.first?.fields, ["phase": "engine_ready"])
    }

    func testSlowSupplementalWorkCannotDelayToneStopOrAudioStartup() async {
        let scheduler = CallUpdateWorkScheduler()
        let waiting = expectation(description: "supplemental network request is pending")
        var release: CheckedContinuation<Void, Never>?
        var tonePlaying = true
        var audioStarted = false
        let operation = Task {
            await scheduler.process(isCurrent: { true }, synchronizeCall: { tonePlaying = false },
                updateAudio: { audioStarted = true }, updateSupplemental: { _ in
                    await withCheckedContinuation { release = $0; waiting.fulfill() }
                })
        }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertFalse(tonePlaying, "connected call must stop waiting tone before a slow cloud request completes")
        XCTAssertTrue(audioStarted, "VoWLAN audio startup must not wait for registration or Live Activity")
        release?.resume()
        await operation.value
        scheduler.cancel()
    }

    func testPollingCoalescesSupplementalRequestsButStillProcessesAudio() async {
        let scheduler = CallUpdateWorkScheduler()
        let waiting = expectation(description: "one supplemental request started")
        var release: CheckedContinuation<Void, Never>?
        var starts = 0
        var audioUpdates = 0
        await scheduler.process(isCurrent: { true }, synchronizeCall: {}, updateAudio: { audioUpdates += 1 },
            updateSupplemental: { _ in
                starts += 1
                await withCheckedContinuation { release = $0; waiting.fulfill() }
            })
        await fulfillment(of: [waiting], timeout: 2)
        await scheduler.process(isCurrent: { true }, synchronizeCall: {}, updateAudio: { audioUpdates += 1 },
            updateSupplemental: { _ in starts += 1 })
        XCTAssertEqual(starts, 1, "slow metadata must not create one new cloud task per poll")
        XCTAssertEqual(audioUpdates, 2, "new call-state updates must not be blocked by pending metadata")
        scheduler.cancel()
        release?.resume()
    }

    func testHangupInvalidatesLateSupplementalResultsEvenIfNetworkIgnoresCancellation() async {
        let scheduler = CallUpdateWorkScheduler()
        let waiting = expectation(description: "old request pending")
        let finished = expectation(description: "old callback resumed")
        var release: CheckedContinuation<Void, Never>?
        var displayedOldCall = false
        await scheduler.process(isCurrent: { true }, synchronizeCall: {}, updateAudio: {},
            updateSupplemental: { isCurrent in
                await withCheckedContinuation { release = $0; waiting.fulfill() }
                if isCurrent() { displayedOldCall = true }
                finished.fulfill()
            })
        await fulfillment(of: [waiting], timeout: 2)
        scheduler.cancel()
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(displayedOldCall, "late cloud result cannot revive a hung-up call")
    }

    func testStaleCallCannotStartAudioOrSupplementalWork() async {
        let scheduler = CallUpdateWorkScheduler()
        var operations = 0
        await scheduler.process(isCurrent: { false }, synchronizeCall: { operations += 1 },
            updateAudio: { operations += 1 }, updateSupplemental: { _ in operations += 1 })
        await Task.yield()
        XCTAssertEqual(operations, 0)
        scheduler.cancel()
    }

    func testCancelDuringAudioStartDoesNotScheduleOldSupplementalWork() async {
        let scheduler = CallUpdateWorkScheduler()
        let waiting = expectation(description: "audio startup suspended")
        var release: CheckedContinuation<Void, Never>?
        var supplementalUpdates = 0
        let operation = Task {
            await scheduler.process(isCurrent: { true }, synchronizeCall: {}, updateAudio: {
                await withCheckedContinuation { release = $0; waiting.fulfill() }
            }, updateSupplemental: { _ in supplementalUpdates += 1 })
        }
        await fulfillment(of: [waiting], timeout: 2)
        scheduler.cancel()
        release?.resume()
        await operation.value
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(supplementalUpdates, 0, "hangup during startup must invalidate the whole old update")
        scheduler.cancel()
    }

    func testSynchronousEndIntentStopsAudioBeforeItCanStart() async {
        let scheduler = CallUpdateWorkScheduler()
        var current = true
        var audioStarts = 0
        await scheduler.process(isCurrent: { current }, synchronizeCall: { current = false },
            updateAudio: { audioStarts += 1 }, updateSupplemental: { _ in })
        XCTAssertEqual(audioStarts, 0, "an end intent during call synchronization must prevent audio startup")
        scheduler.cancel()
    }
}

final class CloudAgentRoutingTests: XCTestCase {
    private func status(_ agents: String, capabilities: String = #", "capabilities":{"agent_command_routing":1}"#) throws -> CloudAgentStatus {
        try JSONDecoder().decode(CloudAgentStatus.self, from: Data((#"{"cloud_online":true,"active_agent_id":"B","agents":\#(agents)\#(capabilities)}"#).utf8))
    }
    func testBoundAgentSurvivesOtherAgentsLatestHeartbeat() throws {
        let s = try status(#"[{"agent_id":"A","cloud_online":true,"command_routing_version":1},{"agent_id":"B","cloud_online":true,"command_routing_version":1}]"#)
        let target = try CloudAgentRouting.select(boundAgentID:"A", agents:s.agents, relayRoutingVersion:s.commandRoutingVersion)
        XCTAssertEqual(target.agentID,"A")
        XCTAssertThrowsError(try CloudAgentRouting.select(boundAgentID:nil,agents:s.agents,relayRoutingVersion:1))
        XCTAssertThrowsError(try CloudAgentRouting.select(boundAgentID:"offline",agents:s.agents,relayRoutingVersion:1))
        XCTAssertThrowsError(try CloudAgentRouting.select(boundAgentID:"A",agents:s.agents,relayRoutingVersion:nil))
        let body = target.addingRouting(to:["command_id":"synthetic-command"])
        XCTAssertEqual(body["target_agent_id"],"A")
        XCTAssertEqual(body["command_id"],"synthetic-command")
    }
    func testLegacyCapabilitiesCannotCreateNewActions() throws {
        let old = try status(#"[{"agent_id":"A","cloud_online":true}]"#,capabilities:"")
        XCTAssertNil(old.commandRoutingVersion)
        XCTAssertThrowsError(try CloudAgentRouting.select(boundAgentID:"A",agents:old.agents,relayRoutingVersion:1))
    }
    func testShortResultPollingRemainsBounded() {
        XCTAssertEqual(CloudAgentRouting.resultDelay(attempt:0),0.5)
        XCTAssertEqual(CloudAgentRouting.resultDelay(attempt:1),1)
        XCTAssertEqual(CloudAgentRouting.resultDelay(attempt:10),2)
    }
    func testDTMFGenerationIsEncodedAsNumber() throws {
        let call = IncomingVoIPCall(bluetoothCallID:"fixture",uuid:UUID(),generation:7,number:nil)
        let fields = CloudAgentRouting.callIdentity(call)
        let data = try JSONSerialization.data(withJSONObject:fields)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(decoded["generation"] as? Int,7)
        XCTAssertNil(decoded["generation"] as? String)
    }
    func testIncomingSourceIsNeverInferredFromSelection() throws {
        var payload:[AnyHashable:Any] = ["event":"incoming_call","call_id":"synthetic-call","call_uuid":"c87f982a-1750-4f03-9a96-6553e454f522"]
        XCTAssertNil(try IncomingVoIPCall(userInfo:payload).agentID)
        payload["agent_id"]="A"
        XCTAssertEqual(try IncomingVoIPCall(userInfo:payload).agentID,"A")
    }
    @MainActor func testResultPollingStopsAtTerminalOrCancellation() async throws {
        var requests = 0
        let value: String = try await CloudAgentRouting.poll(timeout:1, request:{ requests += 1; return "completed" }, isTerminal:{ $0 == "completed" })
        XCTAssertEqual(value,"completed"); XCTAssertEqual(requests,1)
        let task = Task { @MainActor in
            try await CloudAgentRouting.poll(timeout:1, request:{ requests += 1; return "pending" }, isTerminal:{ _ in false })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled poll returned") }
        catch is CancellationError {} catch { XCTFail("wrong cancellation error") }
        XCTAssertEqual(requests,1)
    }
}

final class WatchAgentRoutingTests: XCTestCase {
    func testWatchPushAndOutgoingCopiesKeepSourceAgentAndGeneration() throws {
        let payload:[String:Any] = ["event":"incoming_call", "call_id":"synthetic-call-A",
            "call_uuid":"c87f982a-1750-4f03-9a96-6553e454f522", "agent_id":"android-A", "generation":7,
            "call_secret":String(repeating:"x",count:32),
            "media_url":"wss://relay.example/v1/calls/c87f982a-1750-4f03-9a96-6553e454f522/connect"]
        let call = try WatchVoIPCall(userInfo:payload)
        XCTAssertEqual(call.agentID,"android-A"); XCTAssertEqual(call.generation,7)
        let control = call.controlMessage(action:"end")
        XCTAssertEqual(control["call_id"] as? String,"synthetic-call-A")
        XCTAssertEqual(control["agent_id"] as? String,"android-A")
        XCTAssertEqual(control["generation"] as? UInt64,7)
        let outgoing = try WatchVoIPCall(outgoingReply:payload)
        XCTAssertEqual(outgoing.agentID,call.agentID); XCTAssertEqual(outgoing.generation,7)
        let endpoint = try XCTUnwrap(WatchLocalPCMEndpoint(dictionary:["pcm_host":"192.168.1.2","pcm_port":18080,"pcm_secret":Data(repeating:1,count:32).base64EncodedString()]))
        XCTAssertEqual(outgoing.usingLocalMedia(endpoint).agentID,"android-A")
        var legacy=payload;legacy.removeValue(forKey:"agent_id");legacy.removeValue(forKey:"generation")
        XCTAssertNil(try WatchVoIPCall(userInfo:legacy).agentID)
        XCTAssertEqual(try WatchVoIPCall(userInfo:legacy).generation,1)
    }
}

final class VoWLANNetworkRecoveryTests: XCTestCase {
    func testRecoveryDoesNotMakeACloudOrBluetoothCallPollVoWLAN() {
        XCTAssertFalse(AgentPollingRouteSelector.shouldPollLocal(mode: .automatic, activeTransport: .cloud))
        XCTAssertFalse(AgentPollingRouteSelector.shouldPollLocal(mode: .automatic, activeTransport: .bluetooth))
        XCTAssertTrue(AgentPollingRouteSelector.shouldPollLocal(mode: .automatic, activeTransport: .vowlan))
        XCTAssertFalse(AgentPollingRouteSelector.shouldPollLocal(mode: .cloud, activeTransport: nil))
        XCTAssertFalse(AgentPollingRouteSelector.shouldPollLocal(mode: .bluetooth, activeTransport: nil))
        XCTAssertTrue(AgentPollingRouteSelector.shouldPollLocal(mode: .automatic, activeTransport: nil))
    }
    func testReturnToWiFiAllowsOnlyFreshIdleLocalCapableModes() {
        var gate = VoWLANNetworkRecoveryPlan()
        let cellular = gate.changed(wifiAvailable: false)
        XCTAssertFalse(gate.permits(cellular, mode: .automatic, paired: true, callInProgress: false))
        let wifi = gate.changed(wifiAvailable: true)
        XCTAssertTrue(gate.permits(wifi, mode: .automatic, paired: true, callInProgress: false))
        XCTAssertTrue(gate.permits(wifi, mode: .vowlan, paired: true, callInProgress: false))
        XCTAssertFalse(gate.permits(wifi, mode: .cloud, paired: true, callInProgress: false))
        XCTAssertFalse(gate.permits(wifi, mode: .bluetooth, paired: true, callInProgress: false))
        XCTAssertFalse(gate.permits(wifi, mode: .automatic, paired: false, callInProgress: false))
        XCTAssertFalse(gate.permits(wifi, mode: .automatic, paired: true, callInProgress: true))
        XCTAssertFalse(gate.permits(cellular, mode: .automatic, paired: true, callInProgress: false))
        gate.invalidate()
        XCTAssertFalse(gate.permits(wifi, mode: .automatic, paired: true, callInProgress: false))
    }
}

final class SMSDeletionTests: XCTestCase {
    func testRepeatedFractionalLegacySaveAndUpgradeDoNotDuplicateMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let message = SMSMessage(sender: "fixture", content: "sent", code: nil,
                                 timestamp: Date(timeIntervalSince1970: 1000.125), deliveryID: nil, direction: .outgoing)
        XCTAssertTrue(store.saveMessages([message]))
        XCTAssertTrue(store.saveMessages([message]))
        XCTAssertEqual(store.loadMessages().count, 1)
        var upgraded = message; upgraded.deliveryID = "upgraded"
        XCTAssertTrue(store.saveMessages([upgraded]))
        XCTAssertEqual(store.loadMessages().map(\.deliveryID), ["upgraded"])
    }
    func testDeletedLegacySMSStaysDeletedWhenAgentLaterAddsDeliveryID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let old = SMSMessage(sender: "fixture", content: "legacy", code: nil,
                             timestamp: Date(timeIntervalSince1970: 1000), deliveryID: nil)
        XCTAssertTrue(store.saveMessages([old]))
        XCTAssertTrue(store.deleteMessages(ids: [old.id], from: [old]))
        var upgraded = old; upgraded.deliveryID = "added-by-new-agent"
        XCTAssertTrue(store.saveMessages([upgraded]))
        XCTAssertTrue(store.loadMessages().isEmpty)
    }
    func testDistinctDeliveryIDsNeverShareDeletionEvenWithIdenticalContentAndTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let first = SMSMessage(sender: "fixture", content: "same", code: nil,
                               timestamp: Date(timeIntervalSince1970: 1000), deliveryID: "first")
        var second = first; second.deliveryID = "second"
        XCTAssertTrue(store.saveMessages([first, second]))
        XCTAssertTrue(store.deleteMessages(ids: [first.id], from: [first, second]))
        XCTAssertEqual(store.loadMessages(), [second])
        XCTAssertTrue(store.saveMessages([first, second]))
        XCTAssertEqual(store.loadMessages(), [second])
    }
    func testBatchDeletionDoesNotDeleteNewSameSenderAndRejectsLateBackgroundSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let foreground = LocalHistoryStore(directoryURL: directory)
        let background = LocalHistoryStore(directoryURL: directory)
        let old = SMSMessage(sender: "fixture", content: "old", code: nil,
                             timestamp: Date(timeIntervalSince1970: 1000.125), deliveryID: nil)
        let fresh = SMSMessage(sender: "fixture", content: "fresh", code: nil,
                               timestamp: Date(timeIntervalSince1970: 1002), deliveryID: "fresh")
        XCTAssertTrue(foreground.saveMessages([old]))
        let staleBackgroundSnapshot = background.loadMessages()
        XCTAssertTrue(background.saveMessages(staleBackgroundSnapshot + [fresh]))
        XCTAssertTrue(foreground.deleteMessages(ids: [old.id], from: [old]))
        XCTAssertEqual(foreground.loadMessages(), [fresh])
        XCTAssertTrue(background.saveMessages(staleBackgroundSnapshot + [fresh]))
        XCTAssertEqual(foreground.loadMessages(), [fresh])
        XCTAssertTrue(background.saveMessages(staleBackgroundSnapshot))
        XCTAssertEqual(foreground.loadMessages(), [fresh], "late background writes must not erase a newer inbox record")
        XCTAssertEqual(foreground.visibleMessages([old, fresh]), [fresh])
    }

    func testDeletionSurvivesRestartAndStaleSyncButAllowsNewMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let old = SMSMessage(sender: "fixture", content: "private fixture", code: nil,
                             timestamp: Date(timeIntervalSince1970: 1000), deliveryID: "old")
        let new = SMSMessage(sender: "fixture", content: "new fixture", code: nil,
                             timestamp: Date(timeIntervalSince1970: 1001), deliveryID: "new")
        XCTAssertTrue(store.saveMessages([old]))
        XCTAssertTrue(store.deleteMessages(ids: [old.id], from: [old]))
        let reopened = LocalHistoryStore(directoryURL: directory)
        XCTAssertEqual(reopened.loadMessages(), [])
        XCTAssertTrue(reopened.saveMessages([old, new]))
        XCTAssertEqual(reopened.loadMessages(), [new])
        var legacyDuplicate = old
        legacyDuplicate.deliveryID = nil
        XCTAssertEqual(reopened.visibleMessages([old, legacyDuplicate, new]), [new])
        // Tombstones cannot retain the deleted SMS body or phone number.
        let disk = try String(contentsOf: directory.appendingPathComponent("messages.json"), encoding: .utf8)
        XCTAssertFalse(disk.contains("private fixture"))
    }

    func testLegacyMessageArrayMigratesAndWriteFailureDoesNotDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = SMSMessage(sender: "fixture", content: "legacy", code: nil,
                                 timestamp: Date(timeIntervalSince1970: 1000), deliveryID: nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([message]).write(to: directory.appendingPathComponent("messages.json"))
        let store = LocalHistoryStore(directoryURL: directory)
        XCTAssertEqual(store.loadMessages(), [message])
        XCTAssertTrue(store.deleteMessages(ids: [message.id], from: [message]))
        XCTAssertEqual(store.loadMessages(), [])
        let invalidRoot = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidRoot)
        XCTAssertFalse(LocalHistoryStore(directoryURL: invalidRoot).deleteMessages(ids: [message.id], from: [message]))
    }
}

private final class LocalPairingHTTPProbe: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data?
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    init(response: Data?) throws {
        self.response = response
        listener = try NWListener(using: .tcp)
    }
    func start() async throws -> NWEndpoint {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: DispatchQueue(label: "AirSIMTests.pairing-peer"))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                if let response = self.response {
                    connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port {
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: .hostPort(host: "127.0.0.1", port: port))
                } else if case .failed(let error) = state {
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: DispatchQueue(label: "AirSIMTests.pairing-listener"))
        }
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }
}

private actor ManualPairingPeerProbe {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let secret = Data(0..<32)
    let corruptRoute: Bool
    init(corruptRoute: Bool = false) { self.corruptRoute = corruptRoute }
    func exchange(endpoint: NWEndpoint, body: Data, method: String, path: String, timeout: TimeInterval) throws -> Data {
        guard endpoint == .hostPort(host: "100.64.1.2", port: 38000) else { throw URLError(.badURL) }
        if method == "GET", path == "/pair/v1/info" {
            return try JSONSerialization.data(withJSONObject: ["product": "airsim-pair", "version": 1,
                "session_id": "fixture-session", "server_public_key": key.publicKey.rawRepresentation.base64EncodedString(),
                "expires_at": Date().addingTimeInterval(120).timeIntervalSince1970 * 1000])
        }
        guard method == "POST", path == "/pair/v1/claim",
              let claim = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              claim["want_direct_route"] as? Bool == true,
              claim["session_id"] as? String == "fixture-session",
              let clientKeyText = claim["client_public_key"] as? String,
              let sealedText = claim["sealed_registration"] as? String else { throw URLError(.badServerResponse) }
        func decode(_ text: String) -> Data {
            let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))!
        }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: decode(clientKeyText))
        let shared = try key.sharedSecretFromKeyAgreement(with: publicKey)
        let aes = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("fixture-session".utf8),
            sharedInfo: Data("AirSIMPair/v1:123456".utf8), outputByteCount: 32)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: decode(sealedText)), using: aes,
                                         authenticating: Data("fixture-session".utf8))
        let registration = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertTrue(registration["local_mode"] as? Bool == true)
        XCTAssertNil(registration["relay_url"])
        let encodedSecret = try XCTUnwrap(registration["vowlan_secret"] as? String)
        XCTAssertEqual(decode(encodedSecret), secret)
        let canonical = "AIRSIM-DIRECT1\nfixture-session\n\(clientKeyText)\nfixture-agent\n39001\n39002"
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: secret)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["configured": true, "agent_id": "fixture-agent",
            "control_port": corruptRoute ? 39003 : 39001, "pcm_port": 39002, "route_proof": proof])
    }
}

private final class ContactFetcherProbe: ContactFetching, @unchecked Sendable {
    let result: Result<[ContactStore.Contact], Error>
    let state: ContactAuthorizationState
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    init(_ result: Result<[ContactStore.Contact], Error>, state: ContactAuthorizationState = .authorized) {
        self.result = result
        self.state = state
    }
    func authorizationState() -> ContactAuthorizationState { state }
    func requestAccess() async throws -> Bool { state == .authorized }
    func fetchAll() throws -> [ContactStore.Contact] {
        lock.withLock { reads += 1 }
        return try result.get()
    }
}

// Simulator test runner is unsigned and has no Keychain entitlement (-34018).
// Keep the real controller; replace only the OS credential persistence boundary.
private final class InMemoryVoBLEPairingStore: VoBLEPairingStoring, @unchecked Sendable {
    private var values: [String: VoBLEStoredPeer] = [:]
    func save(_ peer: VoBLEStoredPeer) throws { values[peer.identity] = peer }
    func load(identity: String) throws -> VoBLEStoredPeer? { values[identity] }
    func revoke(identity: String) throws { values.removeValue(forKey: identity) }
}

private final class PairingThreadProbe: VoBLEPairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []
    var observedMainThread: [Bool] { lock.withLock { observations } }
    func save(_ peer: VoBLEStoredPeer) throws { lock.withLock { observations.append(Thread.isMainThread) } }
    func load(identity: String) throws -> VoBLEStoredPeer? {
        lock.withLock { observations.append(Thread.isMainThread) }
        return nil
    }
    func revoke(identity: String) throws {}
}

private actor OutgoingCallServiceProbe: OutgoingCallServicing {
    private let dialError: Error?
    private var actions: [String] = []

    init(dialError: Error? = nil) {
        self.dialError = dialError
    }

    func warmAudioHost() async throws { actions.append("warm") }
    func setAudioHostEnabled(_ enabled: Bool) async throws { actions.append("enable:\(enabled)") }
    func dial(number: String) async throws {
        actions.append("dial:\(number)")
        if let dialError { throw dialError }
    }

    func recordedActions() -> [String] { actions }
}

@MainActor
private final class VoBLEWriterProbe: VoBLEMediaWriting {
    var canSend: Bool
    let maximumLength: Int
    private(set) var writes: [Data] = []

    init(canSend: Bool, maximumLength: Int) {
        self.canSend = canSend
        self.maximumLength = maximumLength
    }

    var canSendWriteWithoutResponse: Bool { canSend }
    var maximumWriteLength: Int { maximumLength }
    func writeWithoutResponse(_ data: Data) { writes.append(data) }
}

private struct LegacyAgentSMSProbe: LegacyAgentPolling {
    let pending: Int?
    let smsStatusAvailable: Bool

    func callStatus() async throws -> CallStatus {
        CallStatus(active: nil, history: [], polling: true, eventDriven: false,
                   pollIntervalSeconds: 1, lastPollError: "", revision: nil)
    }

    func smsStatus() async throws -> SMSStatus {
        if !smsStatusAvailable { throw URLError(.badServerResponse) }
        return SMSStatus(autoCleanupME: true, count: pending, lastPollError: nil)
    }
}

@MainActor
private final class VoBLECallControlProbe: VoBLECallControlling {
    var state: VoBLEConnectionState = .ready
    var onEvent: ((VoBLEAndroidEvent) -> Void)?
    var onAudioDownlinkFragment: ((Data) -> Void)?
    var onReadyToSendAudio: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReady: (() -> Void)?
    var sendOperation: (String, String, UInt64) async throws -> VoBLEControlResponse = { _, _, generation in
        .init(requestID: "test-response", generation: generation, success: true, code: "ok", detail: "accepted")
    }
    func send(command: String, callID: String, generation: UInt64,
              number: String) async throws -> VoBLEControlResponse {
        try await sendOperation(command, callID, generation)
    }
    func mediaKey(callID: String, generation: UInt64) throws -> Data {
        Data(repeating: 1, count: 32)
    }
}

private struct AgentSMSInboxProbe: AgentSMSInboxServicing {
    let name: String
    let inbox: [SMSMessage]

    func messages() async throws -> [SMSMessage] { inbox }
}

final class AirSIMTests: XCTestCase {
    func testOverlayControlAndPCMUseSystemRoutingNotWiFiOrWiredEthernet() throws {
        XCTAssertNil(WiredHTTPTransport.pathSetupTimeout(systemRouting: true, requestTimeout: 20))
        XCTAssertEqual(WiredHTTPTransport.pathSetupTimeout(systemRouting: false, requestTimeout: 20), 1.5)
        let endpoint = try VoWLANEndpoint(host: "100.64.1.2", controlPort: 39001, pcmPort: 39002)
        let credential = try VoWLANCredential(secret: Data(repeating: 1, count: 32))
        let pcm = PCMRoute.vowlan(endpoint: endpoint, credential: credential)
        XCTAssertTrue(AirSIMAPI.isAllowedLocalURL(endpoint.controlBaseURL))
        XCTAssertFalse(pcm.requiresWiFi)
        XCTAssertTrue(pcm.usesSystemRouting)
        XCTAssertTrue(VoWLANNetworkRoutePolicy.usesSystemRouting(host: endpoint.host))
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
        XCTAssertEqual(api.baseURL.absoluteString, "http://100.64.1.2:39001/")
        XCTAssertFalse(AirSIMAPI.isAllowedLocalURL(URL(string: "http://8.8.8.8:39001/")!))
        XCTAssertTrue(AirSIMLiveActivityActionRouting.opensApp(for: .vowlan))
        XCTAssertTrue(AirSIMLiveActivityActionRouting.opensApp(for: .bluetooth))
        XCTAssertFalse(AirSIMLiveActivityActionRouting.opensApp(for: .cloud))
    }
    func testOldProbeCannotOverwriteNewProbeResult() {
        var gate = VoWLANProbeGeneration()
        let old = gate.begin()
        let new = gate.begin()
        XCTAssertFalse(gate.accepts(old))
        XCTAssertTrue(gate.accepts(new))
    }
    func testPairingTCPTransportReadsFramedResponseAndBoundsUnresponsivePeer() async throws {
        let peer = try LocalPairingHTTPProbe(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8))
        let endpoint = try await peer.start()
        defer { peer.stop() }
        let data = try await SamsungPairingClient.networkTransport(endpoint, Data(), "GET", "/pair/v1/info", 3)
        XCTAssertEqual(data, Data("{}".utf8))
        let silent = try LocalPairingHTTPProbe(response: nil)
        let silentEndpoint = try await silent.start()
        defer { silent.stop() }
        do {
            _ = try await SamsungPairingClient.networkTransport(silentEndpoint, Data(), "GET", "/pair/v1/info", 0.1)
            XCTFail("silent peer must time out")
        } catch {
            XCTAssertEqual(error as? SamsungPairingClientError, .timedOut)
        }
        let cancelled = Task { try await SamsungPairingClient.networkTransport(silentEndpoint, Data(), "GET", "/pair/v1/info", 10) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("cancelled request must finish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testManualPairingEncryptsLocalCredentialsAndAcceptsOnlyAuthenticatedPorts() async throws {
        let peer = ManualPairingPeerProbe()
        let registration = AgentPushRegistration.local(vowlanSecret: Data(0..<32).base64EncodedString())
        let address = try SamsungManualPairingAddress(host: "100.64.1.2", port: "38000")
        let result = try await SamsungPairingClient.pairManually(address: address, code: "123456", registration: registration,
            transport: { endpoint, body, method, path, timeout in
                try await peer.exchange(endpoint: endpoint, body: body, method: method, path: path, timeout: timeout)
            })
        XCTAssertEqual(result.route, .init(agentID: "fixture-agent", host: "100.64.1.2", controlPort: 39001, pcmPort: 39002))
        let corrupt = ManualPairingPeerProbe(corruptRoute: true)
        do {
            _ = try await SamsungPairingClient.pairManually(address: address, code: "123456", registration: registration,
                transport: { endpoint, body, method, path, timeout in
                    try await corrupt.exchange(endpoint: endpoint, body: body, method: method, path: path, timeout: timeout)
                })
            XCTFail("tampered port must not become a dial route")
        } catch {
            XCTAssertEqual(error as? SamsungPairingClientError, .directGatewayUnavailable)
        }
    }
    func testPairingHTTPResponseDistinguishesBadCodeFromMissingManualSupport() throws {
        let ok = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        XCTAssertEqual(try SamsungPairingHTTPResponse.decode(ok, metadata: false), Data("{}".utf8))
        XCTAssertThrowsError(try SamsungPairingHTTPResponse.decode(Data("HTTP/1.1 401 Error\r\nContent-Length: 0\r\n\r\n".utf8), metadata: false)) { error in
            XCTAssertEqual(error as? SamsungPairingClientError, .rejected)
        }
        XCTAssertThrowsError(try SamsungPairingHTTPResponse.decode(Data("HTTP/1.1 404 Error\r\nContent-Length: 0\r\n\r\n".utf8), metadata: true)) { error in
            XCTAssertEqual(error as? SamsungPairingClientError, .manualUnsupported)
        }
        for invalid in ["HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n{}", "HTTP/1.1 500 200 Error\r\nContent-Length: 2\r\n\r\n{}"] {
            XCTAssertThrowsError(try SamsungPairingHTTPResponse.decode(Data(invalid.utf8), metadata: false))
        }
    }

    func testManualRouteSelectionSurvivesRestartButHonorsBindingAndDeletion() throws {
        let suite = "AirSIMTests.manual-selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = VoWLANManualRoute(agentID: "manual-agent", host: "100.64.1.2", controlPort: 39001, pcmPort: 39002)
        try VoWLANManualRouteStore.save(route, defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(VoWLANManualRouteStore.selected(defaults: reopened), route)
        AndroidAgentBindingPreference.set("other-agent", defaults: reopened)
        XCTAssertNil(VoWLANManualRouteStore.selected(defaults: reopened))
        AndroidAgentBindingPreference.set("manual-agent", defaults: reopened)
        PairedAndroidDeviceStore.forget("manual-agent", defaults: reopened)
        XCTAssertNil(VoWLANManualRouteStore.selected(defaults: reopened))
    }

    func testFreshDiscoveryReplacesUnreachableManualRouteForSamePhone() throws {
        let saved = VoWLANManualRoute(agentID: "agent", host: "100.64.1.2", controlPort: 39001, pcmPort: 39002)
        let wifi = VoWLANDiscoveredAgent(id: "agent", endpoint: try .init(host: "192.168.1.2", controlPort: 40001, pcmPort: 40002),
            deviceName: "Fresh phone", manufacturer: nil, model: nil, phoneNumber: nil, agentKind: "standalone")
        let fallback = VoWLANRouteCandidates.merge(discovered: [wifi], manual: [saved], live: [], preferred: nil)
        XCTAssertEqual(fallback, [wifi])
        let manualFirst = VoWLANRouteCandidates.merge(discovered: [wifi], manual: [saved], live: [], preferred: saved.endpoint)
        XCTAssertEqual(manualFirst.first?.endpoint, saved.endpoint)
        let noBroadcast = VoWLANRouteCandidates.merge(discovered: [], manual: [saved], live: [], preferred: nil)
        XCTAssertEqual(noBroadcast.first?.endpoint, saved.endpoint)
    }
    func testManualPairingValidatesAddressesAndNeverAcceptsPublicOrMalformedTargets() throws {
        let secret = Data(0..<32)
        let proof = "hQLACWxrSaTjg3tib03xCffgi2LQfdBAV_HLMPmj3hI"
        XCTAssertTrue(SamsungDirectRouteProof.verify(proof, secret: secret, sessionID: "session-1", clientKey: "client-key", agentID: "agent-1", controlPort: 7592, pcmPort: 7593))
        XCTAssertFalse(SamsungDirectRouteProof.verify(proof, secret: secret, sessionID: "session-2", clientKey: "client-key", agentID: "agent-1", controlPort: 7592, pcmPort: 7593))
        XCTAssertFalse(SamsungDirectRouteProof.verify(proof, secret: secret, sessionID: "session-1", clientKey: "client-key", agentID: "other", controlPort: 7592, pcmPort: 7593))
        XCTAssertFalse(SamsungDirectRouteProof.verify(proof, secret: secret, sessionID: "session-1", clientKey: "client-key", agentID: "agent-1", controlPort: 9999, pcmPort: 7593))
        let address = try SamsungManualPairingAddress(host: " 100.64.1.2 ", port: " 38000 ")
        XCTAssertEqual(address.host, "100.64.1.2")
        XCTAssertEqual(address.port, 38000)
        for host in ["8.8.8.8", "127.0.0.1", "0.0.0.0", "100.128.1.2", "192.168.1..2", "192.168.1.2/path", "http://192.168.1.2", "192.168.1.2:80", "010.0.0.1", "192.168.001.2"] {
            XCTAssertThrowsError(try SamsungManualPairingAddress(host: host, port: "38000"), host)
        }
        for port in ["", "0", "65536", "-1", "123/", "1.5"] {
            XCTAssertThrowsError(try SamsungManualPairingAddress(host: "192.168.1.2", port: port))
        }
        XCTAssertNoThrow(try VoWLANEndpoint(host: "100.127.255.254", controlPort: 7592, pcmPort: 7593))
        XCTAssertThrowsError(try VoWLANEndpoint(host: "100.128.0.1", controlPort: 7592, pcmPort: 7593))
        XCTAssertThrowsError(try VoWLANEndpoint(host: "192.168..1.2", controlPort: 7592, pcmPort: 7593))
    }

    func testManualRoutePersistenceDropsDeletedDevicesAndDoesNotStorePhoneNumbers() throws {
        let suite = "AirSIMTests.manual-route.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = VoWLANManualRoute(agentID: "fixture-agent", host: "100.64.1.2", controlPort: 7592, pcmPort: 7593)
        try VoWLANManualRouteStore.save(route, defaults: defaults)
        XCTAssertEqual(VoWLANManualRouteStore.routes(defaults: defaults), [route])
        VoWLANManualRouteStore.remove(agentID: "fixture-agent", defaults: defaults)
        XCTAssertTrue(VoWLANManualRouteStore.routes(defaults: defaults).isEmpty)
        XCTAssertThrowsError(try VoWLANManualRouteStore.save(.init(agentID: "bad", host: "8.8.8.8", controlPort: 7592, pcmPort: 7593), defaults: defaults))
    }
    func testContactMappingUsesAllSystemNameComponents() throws {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        contact.middleName = "Augusta"
        contact.familyName = "Lovelace"
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                              value: CNPhoneNumber(stringValue: "+1 202 555 0100"))]
        let mapped = try XCTUnwrap(ContactFetcher.contact(from: contact))
        XCTAssertEqual(mapped.name, CNContactFormatter.string(from: contact, style: .fullName))
        for component in ["Ada", "Augusta", "Lovelace"] {
            XCTAssertTrue(mapped.name.contains(component))
        }
        contact.givenName = ""
        contact.middleName = ""
        XCTAssertEqual(ContactFetcher.contact(from: contact)?.name, "Lovelace")
        contact.familyName = ""
        contact.middleName = "Augusta"
        XCTAssertEqual(ContactFetcher.contact(from: contact)?.name, "Augusta")
        contact.givenName = "小明"
        contact.middleName = ""
        contact.familyName = "王"
        XCTAssertEqual(ContactFetcher.contact(from: contact)?.name,
                       CNContactFormatter.string(from: contact, style: .fullName))
    }

    @MainActor
    func testLegacyContactCacheRefreshesOnceWithoutLosingOfflineNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contacts.json")
        let old = ContactStore.Contact(id: "fixture", name: "Ada", phones: ["12025550100"], emails: [], photoData: nil)
        let full = ContactStore.Contact(id: "fixture", name: "Ada Augusta Lovelace", phones: old.phones, emails: [], photoData: nil)
        try JSONEncoder().encode([old]).write(to: url)
        let cache = ContactCacheStore(fileURL: url)
        let failing = ContactFetcherProbe(.failure(URLError(.notConnectedToInternet)))
        let offline = ContactStore(fetcher: failing, cache: cache)
        await offline.loadIfAuthorized()
        XCTAssertEqual(offline.contacts, [old])
        XCTAssertTrue(cache.needsNameRefresh)
        let denied = ContactFetcherProbe(.success([]), state: .denied)
        await ContactStore(fetcher: denied, cache: cache).loadIfAuthorized()
        XCTAssertEqual(denied.readCount, 0)
        XCTAssertTrue(cache.needsNameRefresh)
        let fetcher = ContactFetcherProbe(.success([full]))
        let upgraded = ContactStore(fetcher: fetcher, cache: cache)
        await upgraded.loadIfAuthorized()
        XCTAssertEqual(upgraded.contacts, [full])
        XCTAssertFalse(cache.needsNameRefresh)
        await upgraded.loadIfAuthorized()
        XCTAssertEqual(fetcher.readCount, 1)
        XCTAssertEqual(ContactCacheStore(fileURL: url).load(), [full])
    }

    func testAppVersionReadsBundleMetadataAndHandlesMissingValues() {
        XCTAssertEqual(AppInformation.version(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "456"]), "1.2.3 (456)")
        XCTAssertEqual(AppInformation.version(info: [:]), "未知版本")
        XCTAssertFalse(AppInformation.version.isEmpty)
        XCTAssertEqual(AppInformation.repositoryURL.host, "github.com")
        XCTAssertEqual(AppInformation.releasesURL.path, "/kai-wu-cortex/AirSIM/releases")
    }
    func testOldEndedHistoryCannotFinishANewSystemCall() {
        XCTAssertTrue(CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: "a", endedID: "a"))
        XCTAssertFalse(CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: "b", endedID: "a"))
        XCTAssertFalse(CallKitSynchronizationPolicy.mayFinishEndedHistory(currentBackendID: nil, endedID: "a"))
    }

    func testRetiredAgentCallCannotBypassEndIntentWithSynthesizedUUID() {
        var store = CallLifecycleStore()
        let original = UUID()
        let now = Date()
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 1, state: state,
                  source: .agent, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event("a", original, .active)))
        XCTAssertTrue(store.apply(event("a", original, .ended)))
        XCTAssertTrue(store.apply(event("b", UUID(), .ringing)))
        let b = try! XCTUnwrap(store.snapshot.callUUID)
        XCTAssertTrue(store.apply(event("b", b, .ended)))
        XCTAssertFalse(store.apply(event("a", UUID(), .ringing)))
        XCTAssertTrue(store.apply(event("c", UUID(), .ringing)))
    }

    @MainActor
    func testCancelledCloudDialDiscardsLateCallInsteadOfAdoptingIt() async {
        var current = true
        var completion: CheckedContinuation<String, Error>?
        var discarded: [String] = []
        let started = expectation(description: "dial submitted")
        let task = Task { @MainActor in
            do {
                _ = try await OutgoingCallRouteCoordinator.start(
                    number: "test", vowlanService: nil, cloudModeEnabled: true,
                    isCurrent: { current }, discardCloud: { discarded.append($0) }
                ) {
                    try await withCheckedThrowingContinuation { continuation in
                        completion = continuation; started.fulfill()
                    }
                }
                XCTFail("cancelled outgoing call must not be adopted")
            } catch is CancellationError { }
            catch { XCTFail("unexpected error: \(error)") }
        }
        await fulfillment(of: [started], timeout: 2)
        current = false
        completion?.resume(returning: "late-call")
        await task.value
        XCTAssertEqual(discarded, ["late-call"])
    }

    func testCloudDownlinkActualBacklogFallsAfterBurstRecovers() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let start = Date(timeIntervalSince1970: 0)
        for sequence in 0..<12 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: start)
        }
        for sequence in 12..<212 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: start.addingTimeInterval(Double(sequence - 11) * 0.02))
            _ = buffer.dequeue(maxFrames: 1)
        }
        XCTAssertLessThanOrEqual(buffer.bufferedFrameCount, 6)
    }

    @MainActor
    func testLateCloudReconnectDoesNotCompleteOrFailANewerCall() async {
        for succeeds in [true, false] {
            var current = UUID()
            let original = current
            var completion: CheckedContinuation<Void, Error>?
            let started = expectation(description: "connect suspended")
            var connected = 0
            var failed = 0
            let recovery = Task { @MainActor in
                await CloudCallRecoveryCoordinator.run(
                    delays: [0], isCurrent: { current == original },
                    connect: { _ in
                        try await withCheckedThrowingContinuation { continuation in
                            completion = continuation; started.fulfill()
                        }
                    }, connected: { connected += 1 }, failed: { _ in failed += 1 }
                )
            }
            await fulfillment(of: [started], timeout: 2)
            current = UUID() // Hangup, followed by a new call, while connect is pending.
            if succeeds { completion?.resume() }
            else { completion?.resume(throwing: URLError(.networkConnectionLost)) }
            await recovery.value
            XCTAssertEqual(connected, 0)
            XCTAssertEqual(failed, 0)
        }
    }

    func testCloudControlCannotAcknowledgeAnotherCallOrGeneration() throws {
        let uuid = UUID()
        let control = try XCTUnwrap(CloudPCMControlMessage.decode("""
            {"status":"active","call_id":"a","call_uuid":"\(uuid.uuidString)","generation":2}
            """))
        XCTAssertTrue(control.matches(callID: "a", uuid: uuid, generation: 2))
        XCTAssertFalse(control.matches(callID: "b", uuid: uuid, generation: 2))
        XCTAssertFalse(control.matches(callID: "a", uuid: UUID(), generation: 2))
        XCTAssertFalse(control.matches(callID: "a", uuid: uuid, generation: 3))
    }

    func testEndingCallCannotReopenInAppPresentation() {
        let call = CallRecord(id: "ending-call", index: 0, direction: "outgoing",
                              state: "ending", number: nil, startedAt: Date(), updatedAt: Date(),
                              endedAt: nil, missed: false)
        XCTAssertNil(CallPresentationPolicy.inAppCall(surface: .app, local: call, remote: nil))
    }

    func testLocalEndIntentRejectsSameCallWithHigherGeneration() {
        var store = CallLifecycleStore()
        let uuid = UUID()
        let now = Date()
        func event(_ state: CallLifecycleState, _ generation: UInt64) -> CallLifecycleEvent {
            .init(callID: "cloud-call", callUUID: uuid, generation: generation, state: state,
                  source: state == .ending ? .app : .relay, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event(.active, 1)))
        XCTAssertTrue(store.apply(event(.ending, 1)))
        XCTAssertFalse(store.apply(event(.active, 2)), "reconnect must not revoke the user's end intent")
        XCTAssertEqual(store.snapshot.state, .ending)
    }

    func testRetiredCloudCallCannotReturnAfterANewerCallEnds() {
        var store = CallLifecycleStore()
        let first = UUID(), next = UUID(), now = Date()
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 1, state: state,
                  source: .relay, timestamp: now, traceID: nil, failure: nil)
        }
        XCTAssertTrue(store.apply(event("first", first, .active)))
        XCTAssertTrue(store.apply(event("first", first, .ending)))
        XCTAssertTrue(store.apply(event("next", next, .ringing)))
        XCTAssertTrue(store.apply(event("next", next, .ended)))
        XCTAssertFalse(store.apply(event("first", first, .connecting)))
        XCTAssertEqual(store.snapshot.callID, "next")
    }

    func testCloudBufferReturnsToLowDelayAfterNetworkRecovers() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        for _ in 0..<6 { buffer.notePlaybackUnderrun() }
        let raised = buffer.targetFrameCount
        let epoch = Date(timeIntervalSince1970: 100)
        for sequence in 0..<500 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
            _ = buffer.dequeue(maxFrames: 1)
        }
        XCTAssertLessThan(buffer.targetFrameCount, raised, "stable networks must not retain permanent high delay")
        XCTAssertLessThanOrEqual(buffer.targetFrameCount, 6)
    }

    func testCloudUplinkDoesNotReplayHalfSecondOldSpeech() {
        var sender = CloudPCMUplinkSendQueue()
        sender.enqueue(Data(repeating: 1, count: 320), at: 0)
        XCTAssertNil(sender.next(at: 0.5))
        sender.enqueue(Data(repeating: 2, count: 320), at: 0.5)
        XCTAssertEqual(sender.next(at: 0.5)?.first, 2)
    }

    func testCloudBufferConcealsOnlyShortGapWithoutReprimingImmediately() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let start = Date(timeIntervalSince1970: 100)
        let pcm = Data(repeating: 16, count: 320)
        for sequence in 0..<10 { buffer.enqueue(sequence: UInt32(sequence), pcm: pcm, arrivedAt: start) }
        _ = buffer.dequeue(maxFrames: 10)
        let concealed = buffer.dequeue(maxFrames: 1)
        XCTAssertEqual(concealed.count, 1, "a 20 ms shortage should not cause a long buffering pause")
        XCTAssertNotEqual(concealed.first?.pcm, pcm, "concealed speech must decay")
        _ = buffer.dequeue(maxFrames: 1)
        XCTAssertTrue(buffer.dequeue(maxFrames: 1).isEmpty, "never replay old speech through a long outage")
    }

    func testCloudBufferBoundsBurstToLessThan300Milliseconds() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let now = Date()
        for sequence in 0..<100 {
            buffer.enqueue(sequence: UInt32(sequence), pcm: Data(repeating: 1, count: 320), arrivedAt: now)
        }
        XCTAssertLessThanOrEqual(buffer.bufferedFrameCount * 20, 240)
        XCTAssertEqual(buffer.dequeue(maxFrames: 1).first?.sequence, 88)
    }

    @MainActor
    func testVoBLEHangupReplyCannotResurrectAnEndedCall() async throws {
        let central = VoBLECallControlProbe()
        let media = VoBLEGATTMediaTransport(writer: VoBLEWriterProbe(canSend: true, maximumLength: 247))
        let coordinator = VoBLECallCoordinator(central: central, media: media,
                                               audio: VoBLEAudioEngine(transport: media))
        var states: [CallLifecycleState] = []
        var ended = 0
        coordinator.onState = { _, state in states.append(state) }
        coordinator.onEnded = { _ in ended += 1 }
        central.onEvent?(.init(callID: "call-1", generation: 1, direction: "outgoing",
                              state: "dialing", number: ""))
        states.removeAll()
        central.sendOperation = { command, id, generation in
            XCTAssertEqual(command, "end")
            central.onEvent?(.init(callID: id, generation: generation, direction: "outgoing",
                                  state: "ended", number: ""))
            return .init(requestID: "end-1", generation: generation,
                         success: true, code: "ok", detail: "accepted")
        }
        try await coordinator.end(rejectIfRinging: false)
        XCTAssertNil(coordinator.currentIdentity)
        XCTAssertEqual(ended, 1)
        XCTAssertTrue(states.isEmpty, "An acknowledged terminal event must not become ending again")
    }

    @MainActor
    func testVoBLELateHangupMismatchIsIgnoredOnlyForAcknowledgedEndedIdentity() async throws {
        let central = VoBLECallControlProbe()
        let media = VoBLEGATTMediaTransport(writer: VoBLEWriterProbe(canSend: true, maximumLength: 247))
        let coordinator = VoBLECallCoordinator(central: central, media: media,
                                               audio: VoBLEAudioEngine(transport: media))
        central.onEvent?(.init(callID: "call-1", generation: 1, direction: "outgoing",
                              state: "dialing", number: ""))
        central.sendOperation = { _, id, generation in
            central.onEvent?(.init(callID: id, generation: generation, direction: "outgoing",
                                  state: "ended", number: ""))
            central.onEvent?(.init(callID: "next-call", generation: 2, direction: "outgoing",
                                  state: "dialing", number: ""))
            return .init(requestID: "late-end", generation: generation,
                         success: false, code: "call_mismatch", detail: "")
        }
        try await coordinator.end(rejectIfRinging: false)
        XCTAssertEqual(coordinator.currentIdentity?.callID, "next-call")
        central.sendOperation = { _, _, generation in
            .init(requestID: "real-error", generation: generation,
                  success: false, code: "call_mismatch", detail: "")
        }
        do {
            try await coordinator.end(rejectIfRinging: false)
            XCTFail("A mismatch on a still-current call must remain an error")
        } catch {
            XCTAssertEqual(error as? VoBLECentralError, .bluetooth("call_mismatch"))
        }
        XCTAssertEqual(coordinator.currentIdentity?.callID, "next-call")
    }

    func testVoBLELiveActivityActionURLRoutesBackToHostApp() throws {
        let url = try XCTUnwrap(URL(
            string: "airsim://call/hangup?call_id=android-call-7"
        ))
        XCTAssertEqual(
            SystemCommunicationURL.destination(for: url),
            .liveActivity(.hangup, callID: "android-call-7")
        )
        XCTAssertEqual(
            AirSIMLiveActivityActionURL.make(
                action: .hangup, callID: "android-call-7"
            ),
            url
        )
    }

    func testBluetoothPoweredOnDoesNotDemoteReadyConnection() {
        var reducer = VoBLEConnectionReducer()
        let peripheralID = UUID()
        reducer.apply(.discovered(peripheralID))
        reducer.apply(.connected)
        reducer.apply(.characteristicsReady)
        reducer.apply(.controlSubscription(true))
        reducer.apply(.authenticated(identity: "samsung-agent"))
        XCTAssertEqual(reducer.state, .ready)

        reducer.apply(.bluetoothPoweredOn)

        XCTAssertEqual(reducer.state, .ready)
    }

    @MainActor
    func testRejectIsNotSilentlyDroppedWhileAnotherActionIsBusy() async {
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "reject was not attempted"

        await model.reject()

        XCTAssertNotEqual(model.errorMessage, "reject was not attempted")
    }

    @MainActor
    func testHangupIsNotSilentlyDroppedWhileAnotherActionIsBusy() async {
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "hangup was not attempted"

        await model.hangup()

        XCTAssertNotEqual(model.errorMessage, "hangup was not attempted")
    }

    func testLocalCallControlBodyCarriesCallIdentity() throws {
        let targeted = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: "visible-call-7"))
        ) as? [String: String]
        XCTAssertEqual(targeted, ["call_id": "visible-call-7"])
        let legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: nil))
        ) as? [String: String]
        XCTAssertEqual(legacy, [String: String]())
    }

    func testUnansweredPushRejectRoutesToRelayEvenWithoutPreparedMedia() {
        XCTAssertEqual(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ), .cloudReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: .cloud, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ), .cloudReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: .vowlan, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: true
        ), .localReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: false, systemCallAnswered: false,
            activeIncomingRinging: true
        ), .localReject)
    }

    func testLateEndCallbackDoesNotReachBackendAfterCallAlreadyEnded() {
        XCTAssertFalse(CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: false
        ))
        XCTAssertTrue(CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: true
        ))
    }

    func testLocalRejectKeepsObservedAgentDuringReconnect() {
        XCTAssertEqual(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "三星"),
            fallback: "小米",
            targetCallID: "call-on-samsung"
        ), "三星")
        XCTAssertNil(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "三星"),
            fallback: "小米",
            targetCallID: nil
        ))
        XCTAssertNil(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "old-call", service: "三星"),
            fallback: "小米",
            targetCallID: "new-call"
        ))
    }

    @MainActor
    func testInitialPermissionsWaitForMicrophoneDecisionBeforeOtherPrompts() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var events: [String] = []

        await coordinator.requestIfNeeded(
            isForeground: { true },
            microphoneIsUndetermined: { microphoneUndetermined },
            requestMicrophone: {
                events.append("microphone")
                await Task.yield()
                microphoneUndetermined = false
            },
            startDiscovery: { events.append("discovery") },
            requestNotifications: { events.append("notifications") }
        )

        XCTAssertEqual(events, ["microphone", "discovery", "notifications"])
        XCTAssertTrue(coordinator.didStartDiscovery)
    }

    @MainActor
    func testInitialPermissionsRetryWhenMicrophonePromptWasDeferred() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var requestCount = 0
        var notifications = 0
        var discovery = 0

        func request() async {
            await coordinator.requestIfNeeded(
                isForeground: { true },
                microphoneIsUndetermined: { microphoneUndetermined },
                requestMicrophone: { requestCount += 1 },
                startDiscovery: { discovery += 1 },
                requestNotifications: { notifications += 1 }
            )
        }

        await request()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(discovery, 0)
        XCTAssertEqual(notifications, 0)

        microphoneUndetermined = false
        await request()
        await request()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(discovery, 1)
        XCTAssertEqual(notifications, 1)
    }

    func testRelayRetryDoesNotRepeatSuccessfulAgentRegistration() {
        XCTAssertFalse(PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "samsung",
            lastFingerprint: "same-token",
            lastRoute: "samsung"
        ))
    }

    func testNewAgentRouteRequiresRegistrationEvenWithSameToken() {
        XCTAssertTrue(PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "new-samsung",
            lastFingerprint: "same-token",
            lastRoute: "old-samsung"
        ))
    }

    func testRelayQuotaPausesOnlyRelayRegistrationUntilRetryTime() {
        let now = Date(timeIntervalSince1970: 43_200)
        let retryAfter = Date(timeIntervalSince1970: 43_500)
        XCTAssertFalse(PushRegistrationRetryPolicy.shouldAttemptRelay(now: now, retryAfter: retryAfter))
        XCTAssertTrue(PushRegistrationRetryPolicy.shouldAttemptRelay(now: retryAfter, retryAfter: retryAfter))
        XCTAssertEqual(PushRegistrationRetryPolicy.quotaRetryDate(now: now), retryAfter)
        XCTAssertEqual(
            PushRegistrationRetryPolicy.quotaRetryDate(now: Date(timeIntervalSince1970: 86_280)),
            Date(timeIntervalSince1970: 86_410)
        )
    }

    func testCloudStatusRefreshDoesNotRepeatJustBecauseTimeElapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: false, lastAttempt: .distantPast, appIsForeground: true))
        XCTAssertTrue(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: false))
        XCTAssertTrue(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast,
            appIsForeground: false, beforeLiveActivityCall: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-5), appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-30), appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-3_600),
            appIsForeground: false, beforeLiveActivityCall: true))
    }

    func testLegacyAgentPollFetchesPendingSMSWithoutEventEndpoint() async throws {
        let withMessage = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 1, smsStatusAvailable: true))
        XCTAssertTrue(withMessage.smsChanged)

        let empty = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 0, smsStatusAvailable: true))
        XCTAssertFalse(empty.smsChanged)

        let unavailableStatus = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: nil, smsStatusAvailable: false))
        XCTAssertTrue(unavailableStatus.smsChanged)
    }

    func testPendingSMSIsFetchedEvenWhenRevisionWasAlreadyObserved() {
        XCTAssertTrue(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 7, observedSMSRevision: 7))
        XCTAssertTrue(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 0, observedSMSRevision: 7))
        XCTAssertFalse(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 0, eventRevision: 8, observedSMSRevision: 7))
    }

    func testSMSFetchUsesReportingAgentAfterDiscoverySwitchesPhones() async throws {
        let samsung = AgentSMSInboxProbe(name: "三星", inbox: [SMSMessage(
            sender: "10086", content: "来自三星", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "samsung-sms-1", direction: .incoming
        )])
        let xiaomi = AgentSMSInboxProbe(name: "小米", inbox: [])

        let fetched = try await AgentSMSInboxFetch.fetch(
            reportingAgent: samsung, discoveredAgent: xiaomi
        )

        XCTAssertEqual(fetched.messages.map(\.content), ["来自三星"])
        XCTAssertEqual(fetched.agent.name, "三星")
    }

    func testPCMReconnectCreatesFreshHandshakeForEveryAttempt() throws {
        var generated = 0
        let handshakes = PCMHandshakeSequence {
            generated += 1
            return Data("handshake-\(generated)".utf8)
        }

        XCTAssertEqual(try handshakes.next(), Data("handshake-1".utf8))
        XCTAssertEqual(try handshakes.next(), Data("handshake-2".utf8))
        XCTAssertEqual(generated, 2)
    }

    func testIncomingSMSPushAcceptsAgentNanosecondTimestamp() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-nano-1",
            "sender": "10086",
            "content": "短信正文",
            "timestamp": "2026-10-08T08:30:12.123456789Z",
        ])
        XCTAssertEqual(pushed.deliveryID, "sms-nano-1")
        XCTAssertEqual(pushed.message.content, "短信正文")
        XCTAssertEqual(pushed.timestamp.timeIntervalSince1970, 1_791_448_212.123456789, accuracy: 0.001)
    }

    func testIncomingSMSPushAcceptsWholeSecondTimestamp() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-second-1",
            "sender": "10086",
            "content": "短信正文",
            "timestamp": "2026-10-08T08:30:12Z",
        ])
        XCTAssertEqual(pushed.deliveryID, "sms-second-1")
    }

    func testColdLaunchSMSNavigationRequestIsConsumedOnce() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        IncomingSMSPresentationRequest.markPending(sender: "10086", defaults: defaults)
        XCTAssertEqual(IncomingSMSPresentationRequest.consume(defaults: defaults), "10086")
        XCTAssertNil(IncomingSMSPresentationRequest.consume(defaults: defaults))
    }

    func testSMSDeliveryIDDeduplicatesPushAndAgentCopies() {
        let pushed = SMSMessage(
            sender: "10086", content: "短信正文", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        let synchronized = SMSMessage(
            sender: "10086", content: "短信正文", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212.123456789),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        XCTAssertEqual(pushed.id, synchronized.id)
    }

    func testCloudUplinkNeverBurstsAfterBlockedSend() {
        var queue = CloudPCMUplinkSendQueue()
        for index in 0..<10 {
            queue.enqueue(Data(repeating: UInt8(index), count: 320), at: Double(index) * 0.02)
        }
        XCTAssertEqual(queue.next(at: 0.2)?.first, 0)
        XCTAssertNil(queue.next(at: 0.21))
        queue.complete()
        XCTAssertEqual(queue.next(at: 0.23)?.first, 1)
        queue.complete()
        XCTAssertNil(queue.next(at: 0.231))
        XCTAssertEqual(queue.next(at: 0.251)?.first, 2)
    }

    func testCloudUplinkDropsStaleBacklog() {
        var queue = CloudPCMUplinkSendQueue()
        for _ in 0..<200 { queue.enqueue(Data(repeating: 1, count: 320), at: 0) }
        XCTAssertEqual(queue.pendingPackets, 12)
        XCTAssertNil(queue.next(at: 2))
        XCTAssertEqual(queue.pendingPackets, 0)
        XCTAssertEqual(queue.droppedPackets, 200)
    }

    func testCloudDownlinkPrimesAndReordersBurst() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in [0, 2, 1, 3, 4, 5, 6, 7, 8, 9] {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: UInt8(sequence), count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.dequeue(maxFrames: 10).map(\.sequence), Array(0..<10).map(UInt32.init))
        buffer.notePlaybackUnderrun()
        XCTAssertFalse(buffer.isPrimed)
    }

    func testCloudDownlinkLimitsLateBurstLatency() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in 0..<75 {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.bufferedFrameCount, 12)
        XCTAssertEqual(buffer.droppedFrameCount, 63)
        XCTAssertEqual(buffer.dequeue(maxFrames: 50).map(\.sequence), Array(63..<75).map(UInt32.init))
    }

    func testCloudPlaybackReserveRefillsOnRenderedFrames() {
        var window = CloudPCMPlaybackWindow()
        for _ in 0..<2 { window.schedulePacket() }
        XCTAssertEqual(window.availablePackets, 0)
        window.didRenderPacket()
        XCTAssertEqual(window.availablePackets, 1)
        window.schedulePacket()
        XCTAssertEqual(window.scheduledPackets, 2)
    }

    func testOnlySamsungPrivateEndpointsAreAccepted() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.43.1", controlPort: 7575, pcmPort: 7576)
        XCTAssertEqual(endpoint.controlBaseURL.absoluteString, "http://192.168.43.1:7575/")
        XCTAssertThrowsError(try VoWLANEndpoint(host: "8.8.8.8", controlPort: 7575, pcmPort: 7576))
        XCTAssertFalse(AirSIMRoutePolicy.permits(.moduleLocal))
    }

    func testLegacyModuleRequestIsRejectedBeforeNetworkAccess() async {
        do {
            _ = try await AirSIMAPI().health()
            XCTFail("旧模块路线不应发出请求")
        } catch APIError.disabledLegacyRoute {
            // Expected: the old module route is blocked at the transport boundary.
        } catch {
            XCTFail("预期得到旧路线已停用错误，实际为 \(error)")
        }
    }

    func testLegacyModulePCMHandshakeIsRejected() {
        XCTAssertThrowsError(try PCMRoute.moduleLocal.handshake()) { error in
            guard case APIError.disabledLegacyRoute = error else {
                return XCTFail("预期旧模块 PCM 被拦截，实际为 \(error)")
            }
        }
    }

    func testDialTransportPrefersVoWLANOverCloud() {
        let route = DialPadTransportPresentation.make(
            mode: .automatic,
            vowlanOnline: true,
            moduleLocalReachable: false,
            cloudOnline: true,
            bluetoothReady: true
        )
        XCTAssertEqual(route?.transport, .vowlan)
    }

    func testAutomaticDialRouteFallsBackFromVoWLANToBluetoothThenCloud() {
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: true,
            bluetoothReady: true,
            cloudReady: true
        ), .vowlan)
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: false,
            bluetoothReady: true,
            cloudReady: true
        ), .bluetooth)
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .automatic,
            vowlanReady: false,
            bluetoothReady: false,
            cloudReady: true
        ), .cloud)
    }

    func testExplicitBluetoothRouteDoesNotDependOnVoWLANOrRelay() {
        XCTAssertEqual(DialRouteSelector.preferred(
            mode: .bluetooth,
            vowlanReady: false,
            bluetoothReady: true,
            cloudReady: false
        ), .bluetooth)
        XCTAssertTrue(OutgoingCommandAvailability.isAvailable(
            mode: .bluetooth,
            localControlReachable: false,
            bluetoothReady: true,
            cloudModeEnabled: false,
            cloudHeartbeatFresh: false
        ))
    }

    func testAndroidAgentBindingPersistsAndRejectsOtherRoutes() {
        let suite = "AirSIMTests.agent-binding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(AndroidAgentBindingPreference.selected(defaults: defaults))
        XCTAssertTrue(AndroidAgentBindingPreference.permits("samsung", defaults: defaults))
        AndroidAgentBindingPreference.set("vivo-x60", defaults: defaults)
        XCTAssertEqual(AndroidAgentBindingPreference.selected(defaults: defaults), "vivo-x60")
        XCTAssertTrue(AndroidAgentBindingPreference.permits("vivo-x60", defaults: defaults))
        XCTAssertFalse(AndroidAgentBindingPreference.permits("samsung", defaults: defaults))
        AndroidAgentBindingPreference.set(nil, defaults: defaults)
        XCTAssertNil(AndroidAgentBindingPreference.selected(defaults: defaults))
    }

    func testPairedDeviceDeletionPersistsAndDoesNotReturnFromDiscovery() {
        let suite = "AirSIMTests.paired-devices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let samsung = PairedAndroidDeviceRecord(id: "samsung", deviceName: "Flip7", agentKind: "standalone")
        let vivo = PairedAndroidDeviceRecord(id: "vivo", deviceName: "X60", agentKind: "standalone")
        PairedAndroidDeviceStore.remember(samsung, defaults: defaults)
        PairedAndroidDeviceStore.remember(vivo, defaults: defaults)
        AndroidAgentBindingPreference.set("samsung", defaults: defaults)
        PairedAndroidDeviceStore.forget("samsung", defaults: defaults)
        PairedAndroidDeviceStore.remember(samsung, defaults: defaults)
        XCTAssertEqual(PairedAndroidDeviceStore.records(defaults: defaults).map(\.id), ["vivo"])
        XCTAssertFalse(PairedAndroidDeviceStore.permits("samsung", defaults: defaults))
        XCTAssertNil(AndroidAgentBindingPreference.selected(defaults: defaults))
        let reopened = UserDefaults(suiteName: suite)!
        XCTAssertFalse(PairedAndroidDeviceStore.permits("samsung", defaults: reopened))
        PairedAndroidDeviceStore.allowPairing("samsung", defaults: reopened)
        PairedAndroidDeviceStore.remember(samsung, defaults: reopened)
        XCTAssertEqual(Set(PairedAndroidDeviceStore.records(defaults: reopened).map(\.id)), ["vivo", "samsung"])
    }

    func testFreshVoWLANIdentityClearsOldNumberWhenNewSIMDoesNotReportNumber() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.31.203", controlPort: 7592, pcmPort: 7593)
        let previous = VoWLANDiscoveredAgent(id: "samsung", endpoint: endpoint, deviceName: "Flip7",
            manufacturer: "samsung", model: "Flip7", phoneNumber: "+10000000001", agentKind: "standalone")
        let empty = try JSONDecoder().decode(VoWLANHealthIdentity.self,
            from: Data(#"{"ok":true,"agent_id":"samsung","phone_number":""}"#.utf8))
        XCTAssertNil(previous.refreshed(with: empty).phoneNumber)
        let changed = try JSONDecoder().decode(VoWLANHealthIdentity.self,
            from: Data(#"{"ok":true,"agent_id":"samsung","phone_number":"+10000000002"}"#.utf8))
        XCTAssertEqual(previous.refreshed(with: changed).phoneNumber, "+10000000002")
    }

    func testAuthenticatedBluetoothMetadataUsesCurrentNumberAndRejectsAnotherDevice() throws {
        let metadata = try AndroidAgentMetadata.decode(
            Data(#"{"agent_id":"samsung","device_name":"Flip7","phone_number":"","agent_kind":"standalone"}"#.utf8),
            expectedID: "samsung")
        XCTAssertNil(metadata.phoneNumber)
        XCTAssertEqual(metadata.deviceName, "Flip7")
        XCTAssertThrowsError(try AndroidAgentMetadata.decode(
            Data(#"{"agent_id":"other","device_name":"Other"}"#.utf8), expectedID: "samsung"))
    }

    func testDeletedBluetoothAdvertisementCannotAutomaticallyReconnect() {
        let suite = "AirSIMTests.deleted-peripheral.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PairedAndroidDeviceStore.rememberPeripheral("peripheral-samsung", for: "samsung", defaults: defaults)
        PairedAndroidDeviceStore.rememberPeripheral("peripheral-vivo", for: "vivo", defaults: defaults)
        PairedAndroidDeviceStore.forget("samsung", defaults: defaults)
        XCTAssertFalse(PairedAndroidDeviceStore.permitsPeripheral("peripheral-samsung", defaults: defaults))
        XCTAssertTrue(PairedAndroidDeviceStore.permitsPeripheral("peripheral-vivo", defaults: defaults))
        PairedAndroidDeviceStore.allowPairing("samsung", defaults: defaults)
        XCTAssertTrue(PairedAndroidDeviceStore.permitsPeripheral("peripheral-samsung", defaults: defaults))
    }

    @MainActor
    func testOfflineBluetoothDeviceDeletionRevokesOnlyThatKeychainCredential() async throws {
        let store = InMemoryVoBLEPairingStore()
        let one = VoBLEStoredPeer(identity: "samsung", pairingKey: Data(repeating: 1, count: 32), createdAt: Date())
        let two = VoBLEStoredPeer(identity: "vivo", pairingKey: Data(repeating: 2, count: 32), createdAt: Date())
        defer { try? store.revoke(identity: "samsung"); try? store.revoke(identity: "vivo") }
        try store.save(one); try store.save(two)
        let controller = VoBLECentralController(pairingStore: store)
        try await controller.forgetDevice("samsung")
        XCTAssertNil(try store.load(identity: "samsung"))
        XCTAssertEqual(try store.load(identity: "vivo"), two)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testCloudStatusDecodesMultipleAndroidAgentsAndCurrentRoute() throws {
        let data = Data(#"""
        {
            "cloud_online": true,
            "active_agent_id": "samsung-standalone",
            "agents": [
                {
                    "agent_id": "xiaomi-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Xiaomi 15",
                    "phone_number": "+8613800000001",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": false
                },
                {
                    "agent_id": "samsung-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Samsung Flip7",
                    "phone_number": "+8613800000002",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": true
                }
            ]
        }
        """#.utf8)
        let status = try JSONDecoder().decode(CloudAgentStatus.self, from: data)
        XCTAssertEqual(status.activeAgentID, "samsung-standalone")
        XCTAssertEqual(status.agents.count, 2)
        XCTAssertEqual(status.agents.last?.deviceName, "Samsung Flip7")
        XCTAssertEqual(status.agents.last?.phoneNumber, "+8613800000002")
    }

    func testCloudModeCanBeDisabledWithoutDisablingLocalCalls() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudModePreference.key)
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
        XCTAssertTrue(OutgoingCommandAvailability.isAvailable(
            localControlReachable: true,
            cloudModeEnabled: false,
            cloudHeartbeatFresh: false
        ))
    }

    func testExplicitBluetoothModeDisablesUnrelatedLifecycles() {
        let policy = ConnectionModeRuntimePolicy(mode: .bluetooth)

        XCTAssertTrue(policy.startsBluetooth)
        XCTAssertFalse(policy.startsVoWLAN)
        XCTAssertFalse(policy.startsCloud)
        XCTAssertFalse(policy.allowsCrossModeFallback)
        XCTAssertTrue(policy.usesCallKit)
    }

    func testOnlyAutomaticAllowsCrossModeSelection() {
        XCTAssertTrue(ConnectionModeRuntimePolicy(mode: .automatic).allowsCrossModeFallback)
        for mode in [AirSIMConnectionMode.vowlan, .bluetooth, .cloud] {
            XCTAssertFalse(ConnectionModeRuntimePolicy(mode: mode).allowsCrossModeFallback)
        }
    }

    func testVoBLEAudioVectorUsesBigEndianHeaderAndRoundTripsAtCommonMTUs() throws {
        let packet = VoBLEAudioPacket(
            flags: [], codec: .g711MuLaw, streamID: 7,
            sequence: 0x01020304, sampleTimestamp: 0x05060708,
            payload: Data([0x00, 0x7f, 0x80, 0xff]),
            authenticationTag: Data(repeating: 0xa5, count: 16)
        )

        for maximumPacketLength in [23, 185, 247] {
            let fragments = try packet.encodedFragments(maximumPacketLength: maximumPacketLength)
            XCTAssertTrue(fragments.allSatisfy { $0.count <= maximumPacketLength })
            XCTAssertEqual(Array(fragments[0][7..<11]), [0x01, 0x02, 0x03, 0x04])
            XCTAssertEqual(Array(fragments[0][11..<15]), [0x05, 0x06, 0x07, 0x08])

            var reassembler = VoBLEAudioReassembler()
            var decoded: VoBLEAudioPacket?
            for fragment in fragments {
                decoded = try reassembler.append(fragment, now: Date(timeIntervalSince1970: 10)) ?? decoded
            }
            XCTAssertEqual(decoded, packet)
        }
        XCTAssertEqual(
            try packet.encodedFragments(maximumPacketLength: 247)[0],
            Data([
                0xa5, 0x5a, 0x01, 0x01, 0x00, 0x01, 0x07,
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x00, 0x01, 0x14, 0x00, 0x7f, 0x80, 0xff,
            ] + Array(repeating: 0xa5, count: 16))
        )
    }

    func testVoBLEReassemblyExpiryMarksNextFrameDiscontinuous() throws {
        let first = VoBLEAudioPacket(
            flags: [], codec: .g711MuLaw, streamID: 1, sequence: 1,
            sampleTimestamp: 0, payload: Data(repeating: 1, count: 160),
            authenticationTag: Data(repeating: 2, count: 16)
        )
        let second = VoBLEAudioPacket(
            flags: [], codec: .g711MuLaw, streamID: 1, sequence: 2,
            sampleTimestamp: 160, payload: Data([3]),
            authenticationTag: Data(repeating: 4, count: 16)
        )
        var reassembler = VoBLEAudioReassembler()
        let incomplete = try first.encodedFragments(maximumPacketLength: 23)
        _ = try reassembler.append(incomplete[0], now: Date(timeIntervalSince1970: 1))
        let complete = try second.encodedFragments(maximumPacketLength: 247)
        let decoded = try reassembler.append(complete[0], now: Date(timeIntervalSince1970: 1.201))

        XCTAssertTrue(decoded?.flags.contains(.discontinuity) == true)
    }

    func testVoBLEMediaCipherAndMuLawMatchAndroidVector() throws {
        let pcm = Data((0..<160).flatMap { value -> [UInt8] in
            let sample = Int16(truncatingIfNeeded: value * 257 - 20_000)
            return [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)]
        })
        let encoded = VoBLEMULaw.encode(pcm)
        XCTAssertEqual(encoded.count, 160)
        XCTAssertEqual(VoBLEMULaw.decode(encoded).count, 320)
        let key = Data(0..<32)
        let sealed = try VoBLEMediaCipher.seal(
            encoded, key: key, direction: .uplink, streamID: 1,
            sequence: 7, timestamp: 160)
        XCTAssertEqual(try VoBLEMediaCipher.open(
            sealed, key: key, direction: .uplink, streamID: 1,
            sequence: 7, timestamp: 160), encoded)
        XCTAssertThrowsError(try VoBLEMediaCipher.open(
            sealed, key: key, direction: .downlink, streamID: 1,
            sequence: 7, timestamp: 160))
    }

    func testVoBLEJitterRejectsReplayAndConcealsGap() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        for sequence in [UInt32(10), 11, 13] {
            XCTAssertTrue(jitter.insert(sequence: sequence,
                pcm: Data(repeating: UInt8(sequence), count: 320)))
        }
        XCTAssertFalse(jitter.insert(sequence: 11, pcm: Data(repeating: 0, count: 320)))
        XCTAssertEqual(jitter.dequeue()?.sequence, 10)
        XCTAssertEqual(jitter.dequeue()?.sequence, 11)
        let concealed = jitter.dequeue()
        XCTAssertEqual(concealed?.sequence, 12)
        XCTAssertTrue(concealed?.concealed == true)
        XCTAssertEqual(jitter.dequeue()?.sequence, 13)
    }

    @MainActor
    func testVoBLEStreamingReplenishesBeforeDevicePresentationFinishes() async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 160)
        try engine.start()
        defer { player.stop(); engine.stop() }
        let consumed = expectation(description: "streaming buffer can be replenished without a device sink")
        consumed.expectedFulfillmentCount = 3
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for _ in 0..<3 {
            VoBLEPlaybackScheduling.schedule(buffer, on: player) { consumed.fulfill() }
        }
        player.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        for _ in 0..<8 { _ = try engine.renderOffline(160, to: output) }
        await fulfillment(of: [consumed], timeout: 1)
    }

    func testBluetoothAudioStatusIgnoresInactiveWiFiAndStaleCloudState() {
        for cloud in [CloudCallAudioState.idle, .failed("old relay failure")] {
            XCTAssertEqual(CallAudioStatusPresentation.text(
                transport: .bluetooth, bluetoothRunning: true, bluetoothError: nil,
                localAudioActive: false, cloudState: cloud), "蓝牙语音已连接")
        }
        XCTAssertEqual(CallAudioStatusPresentation.text(
            transport: .bluetooth, bluetoothRunning: false, bluetoothError: "音频启动失败",
            localAudioActive: true, cloudState: .connected), "音频启动失败")
    }

    func testVoBLEReconnectWaitsForOldDisconnectionAndIgnoresUnrelatedCallback() {
        let old = UUID(), other = UUID()
        var barrier = VoBLEReconnectBarrier()
        barrier.begin(old)
        XCTAssertFalse(barrier.permitsConnection)
        XCTAssertFalse(barrier.finish(other))
        XCTAssertFalse(barrier.permitsConnection)
        XCTAssertEqual(barrier.disconnectingID, old)
        XCTAssertTrue(barrier.finish(old))
        XCTAssertTrue(barrier.permitsConnection)
        XCTAssertFalse(barrier.finish(old))
    }

    func testVoBLECancellationCanRecoverFromMissingCallbackOnlyAfterActualDisconnection() {
        let old = UUID(), other = UUID()
        var barrier = VoBLEReconnectBarrier()
        barrier.begin(old)
        XCTAssertFalse(barrier.finishIfDisconnected(other, state: .disconnected))
        for state: CBPeripheralState in [.connecting, .connected, .disconnecting] {
            XCTAssertFalse(barrier.finishIfDisconnected(old, state: state))
            XCTAssertFalse(barrier.permitsConnection)
        }
        XCTAssertTrue(barrier.finishIfDisconnected(old, state: .disconnected))
        XCTAssertTrue(barrier.permitsConnection)
        XCTAssertFalse(barrier.finishIfDisconnected(old, state: .disconnected))
    }

    func testVoBLEJitterUnderflowDoesNotDiscardDelayedAudio() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        let pcm = Data(repeating: 1, count: 320)
        for sequence in UInt32(10)...12 { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        for sequence in UInt32(10)...12 { XCTAssertEqual(jitter.dequeue()?.sequence, sequence) }
        for _ in 0..<20 { XCTAssertNil(jitter.dequeue()) }
        for sequence in UInt32(13)...15 { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        XCTAssertEqual(jitter.dequeue()?.sequence, 13)
        XCTAssertEqual(jitter.dequeue()?.concealed, false)
    }

    func testVoBLEJitterOverflowRetainsRecentAudioInsteadOfGrowingLatency() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        let pcm = Data(repeating: 1, count: 320)
        for sequence in UInt32(0)...8 { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        XCTAssertEqual(jitter.dequeue()?.sequence, 1)
        for sequence in UInt32(2)...8 { XCTAssertEqual(jitter.dequeue()?.sequence, sequence) }
        XCTAssertNil(jitter.dequeue())
        XCTAssertFalse(jitter.insert(sequence: 0, pcm: pcm))
    }

    func testVoBLEJitterLongGapDoesNotRepeatOldSpeech() {
        var jitter = VoBLEJitterBuffer(targetFrames: 3)
        let pcm = Data(repeating: 1, count: 320)
        for sequence in [UInt32(0), 1, 20] { XCTAssertTrue(jitter.insert(sequence: sequence, pcm: pcm)) }
        XCTAssertEqual(jitter.dequeue()?.sequence, 0)
        XCTAssertEqual(jitter.dequeue()?.sequence, 1)
        let recovered = jitter.dequeue()
        XCTAssertEqual(recovered?.sequence, 20)
        XCTAssertEqual(recovered?.concealed, false)
    }

    func testVoBLEJitterAdaptsWithinThreeToEightFrames() {
        var jitter = VoBLEJitterBuffer(targetFrames: 4)
        for _ in 0..<10 { jitter.noteDiscontinuity() }
        XCTAssertEqual(jitter.targetFrames, 8)

        for sequence in 0..<60 {
            XCTAssertTrue(jitter.insert(sequence: UInt32(sequence), pcm: Data(repeating: 0, count: 320)))
            _ = jitter.dequeue()
        }
        XCTAssertEqual(jitter.targetFrames, 7)
    }

    @MainActor
    func testVoBLETransportBackpressureBoundsEightFramesAndRejectsStaleCall() async throws {
        let writer = VoBLEWriterProbe(canSend: false, maximumLength: 185)
        let transport = VoBLEGATTMediaTransport(writer: writer)
        try transport.start(identity: .init(callID: "call-a", generation: 4),
                            mediaKey: Data(repeating: 7, count: 32))
        for _ in 0..<10 { transport.enqueueCapturedPCM(Data(repeating: 1, count: 320)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.queuedFrameCount, 8)
        XCTAssertEqual(transport.droppedFrameCount, 2)
        XCTAssertTrue(writer.writes.isEmpty)
        writer.canSend = true
        transport.peripheralIsReadyToSend()
        XCTAssertFalse(writer.writes.isEmpty)
        transport.stop(identity: .init(callID: "other", generation: 4))
        XCTAssertTrue(transport.isRunning)
        transport.stop(identity: .init(callID: "call-a", generation: 4))
        XCTAssertFalse(transport.isRunning)
    }

    func testVoBLEAudioGateRequiresMediaAndCallKit() {
        var gate = VoBLEAudioStartGate()
        gate.mediaReady = true
        XCTAssertFalse(gate.canStart)
        gate.callKitAudioActive = true
        XCTAssertTrue(gate.canStart)
        gate.mediaReady = false
        XCTAssertFalse(gate.canStart)
    }

    func testVoBLEAppManagedAudioDoesNotWaitForCallKit() {
        var gate = VoBLEAudioStartGate()
        gate.mediaReady = true
        XCTAssertFalse(gate.canStart)
        gate.appAudioSessionActive = true
        XCTAssertTrue(gate.canStart)
        gate.mediaReady = false
        XCTAssertFalse(gate.canStart)
        gate.mediaReady = true
        gate.appAudioSessionActive = false
        XCTAssertFalse(gate.canStart)
    }

    func testVoBLEOutgoingAdoptsAndroidCallIDAndStartsMediaOnce() {
        var lifecycle = VoBLECallLifecycleReducer()
        let pending = lifecycle.beginOutgoing(
            callID: "pending", generation: 4, number: "10086")
        XCTAssertEqual(pending.direction, "outgoing")
        XCTAssertTrue(pending.isProvisional)

        let event = VoBLEAndroidEvent(
            callID: "android-call", generation: 4, direction: "outgoing",
            state: "active", number: "10086")
        guard case let .active(active, startMedia) = lifecycle.apply(event) else {
            return XCTFail("expected active")
        }
        XCTAssertEqual(active.callID, "android-call")
        XCTAssertEqual(active.uuid, pending.uuid)
        XCTAssertFalse(active.isProvisional)
        XCTAssertTrue(startMedia)
        guard case let .active(repeated, repeatedStart) = lifecycle.apply(event) else {
            return XCTFail("expected repeated active")
        }
        XCTAssertEqual(repeated, active)
        XCTAssertFalse(repeatedStart)
    }

    func testVoBLEMatchingEndCleansUpOnceAndStaleEndIsIgnored() {
        var lifecycle = VoBLECallLifecycleReducer()
        _ = lifecycle.apply(VoBLEAndroidEvent(
            callID: "call-7", generation: 7, direction: "incoming",
            state: "incoming", number: "123"))
        XCTAssertEqual(lifecycle.current?.callID, "call-7")

        XCTAssertEqual(lifecycle.apply(VoBLEAndroidEvent(
            callID: "old", generation: 6, direction: "incoming",
            state: "ended", number: "")), .ignored)
        let end = VoBLEAndroidEvent(
            callID: "call-7", generation: 7, direction: "incoming",
            state: "ended", number: "")
        guard case .ended = lifecycle.apply(end) else { return XCTFail("expected ended") }
        XCTAssertNil(lifecycle.current)
        XCTAssertEqual(lifecycle.apply(end), .ignored)
    }

    func testWatchPayloadCarriesBluetoothTransport() {
        let payload = WatchCallPayload(
            callID: "ble-call", callUUID: UUID(), phase: .active,
            number: "10010", callerName: nil, transport: "bluetooth",
            updatedAt: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(payload.dictionary["transport"] as? String, "bluetooth")
        XCTAssertEqual(WatchCallPayload(dictionary: payload.dictionary)?.transport, "bluetooth")
    }

    func testVoBLEDiagnosticsRedactsSecretsAndMedia() {
        let sanitized = VoBLEDiagnosticsSnapshot.sanitize([
            "pcm_ready": "true",
            "phone_number": "+8613800000000",
            "media_key": "secret",
            "nonce": "secret",
            "authentication_tag": "secret",
            "audio_payload": "secret",
        ])
        XCTAssertEqual(sanitized, ["pcm_ready": "true"])
    }

    func testVoBLERecoveryAcceptsOnlySameGenerationWithinThreeSeconds() {
        let start = Date(timeIntervalSince1970: 100)
        let identity = VoBLEMediaSessionIdentity(callID: "call-4", generation: 4)
        let recovery = VoBLERecoveryPolicy(identity: identity, disconnectedAt: start)
        XCTAssertTrue(recovery.accepts(identity, at: start.addingTimeInterval(2.9)))
        XCTAssertFalse(recovery.accepts(
            .init(callID: "call-4", generation: 5), at: start.addingTimeInterval(1)))
        XCTAssertFalse(recovery.accepts(identity, at: start.addingTimeInterval(3.1)))
    }

    func testDialPadCanPresentBluetoothAsIndependentTransport() {
        let route = DialPadTransportPresentation.make(
            mode: .bluetooth,
            vowlanOnline: false, moduleLocalReachable: false,
            cloudOnline: false, bluetoothReady: true)
        XCTAssertEqual(route?.transport, .bluetooth)
        XCTAssertEqual(route?.title, "蓝牙")
    }

    func testVoBLEControlEnvelopeRoundTripsAndRejectsBadMagic() throws {
        let envelope = VoBLEControlEnvelope(
            command: "answer", callID: "call-7", generation: 0x0102030405060708,
            sessionID: Data([1, 2, 3, 4]), nonce: Data(repeating: 5, count: 12),
            ciphertext: Data([6, 7, 8]), authenticationTag: Data(repeating: 9, count: 16)
        )
        let encoded = try envelope.encoded()
        XCTAssertEqual(Array(encoded[4..<12]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(try VoBLEControlEnvelope.decode(encoded), envelope)

        var corrupted = encoded
        corrupted[0] = 0
        XCTAssertThrowsError(try VoBLEControlEnvelope.decode(corrupted))

        for maximumPacketLength in [23, 185, 247] {
            let fragments = try VoBLEMessageFragmenter.encode(
                encoded, type: .control, messageID: 0x1234,
                maximumPacketLength: maximumPacketLength)
            XCTAssertTrue(fragments.allSatisfy { $0.count <= maximumPacketLength })
            var reassembler = VoBLEMessageReassembler()
            var message: VoBLEMessage?
            for fragment in fragments {
                message = try reassembler.append(
                    fragment, now: Date(timeIntervalSince1970: 10)) ?? message
            }
            XCTAssertEqual(message?.messageID, 0x1234)
            XCTAssertEqual(message?.payload, encoded)
        }
    }

    func testVoBLEPairingTranscriptAndSessionKeysAreDeterministic() throws {
        let androidPrivate = Data((1...32).map(UInt8.init))
        let iphonePrivate = Data((33...64).map(UInt8.init))
        let androidPublic = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: androidPrivate).publicKey.rawRepresentation
        let iphonePublic = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: iphonePrivate).publicKey.rawRepresentation
        let transcript = VoBLEPairingTranscript(
            androidIdentity: "samsung-test", androidPublicKey: androidPublic,
            iphonePublicKey: iphonePublic,
            androidNonce: Data(repeating: 0x11, count: 32),
            iphoneNonce: Data(repeating: 0x22, count: 32)
        )
        let android = try VoBLESessionAuthenticator.derivePairing(
            privateKey: androidPrivate, peerPublicKey: iphonePublic, transcript: transcript)
        let iphone = try VoBLESessionAuthenticator.derivePairing(
            privateKey: iphonePrivate, peerPublicKey: androidPublic, transcript: transcript)
        XCTAssertEqual(android, iphone)
        XCTAssertEqual(android.pairingKey.map { String(format: "%02x", $0) }.joined(),
                       "41cef6294f3575441997664149bd8a014c8db026ad3a5312410be90f7d76c48a")
        XCTAssertEqual(android.sas, "922247")

        let modified = VoBLEPairingTranscript(
            androidIdentity: "samsung-modified", androidPublicKey: androidPublic,
            iphonePublicKey: iphonePublic,
            androidNonce: Data(repeating: 0x11, count: 32),
            iphoneNonce: Data(repeating: 0x22, count: 32)
        )
        let modifiedMaterial = try VoBLESessionAuthenticator.derivePairing(
            privateKey: androidPrivate, peerPublicKey: iphonePublic, transcript: modified)
        XCTAssertNotEqual(modifiedMaterial.pairingKey, android.pairingKey)

        let first = try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: android.pairingKey, sessionID: Data(repeating: 3, count: 16),
            callID: "call-1", generation: 1)
        let reconnect = try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: android.pairingKey, sessionID: Data(repeating: 4, count: 16),
            callID: "call-1", generation: 1)
        XCTAssertNotEqual(first.control, first.media)
        XCTAssertNotEqual(first.media, first.reconnect)
        XCTAssertNotEqual(first, reconnect)
        XCTAssertEqual(try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: android.pairingKey, sessionID: Data(repeating: 5, count: 16),
            callID: "", generation: 0).control.count, 32)
        let message = Data("authenticated-control".utf8)
        let tag = try VoBLESessionAuthenticator.tag(message: message, key: first.control)
        XCTAssertTrue(VoBLESessionAuthenticator.authenticate(
            message: message, tag: tag, key: first.control))
        XCTAssertFalse(VoBLESessionAuthenticator.authenticate(
            message: message, tag: tag, key: Data(repeating: 0, count: 32)))
        let reconnectTag = try VoBLESessionAuthenticator.reconnectTag(
            pairingKey: android.pairingKey, transcript: transcript)
        XCTAssertEqual(reconnectTag.count, 16)
        XCTAssertEqual(reconnectTag.map { String(format: "%02x", $0) }.joined(),
                       "a09d46e2afc3444bffc9013831d265c7")
        XCTAssertEqual(reconnectTag, try VoBLESessionAuthenticator.reconnectTag(
            pairingKey: android.pairingKey, transcript: transcript))
        XCTAssertNotEqual(reconnectTag, try VoBLESessionAuthenticator.reconnectTag(
            pairingKey: android.pairingKey, transcript: modified))
        XCTAssertEqual(try VoBLESessionAuthenticator.confirmationTag(
            pairingKey: android.pairingKey, challengeID: "challenge-1").count, 16)
    }

    func testVoBLEReplayWindowRejectsDuplicateExpiredAndRevokedPeer() {
        let now = Date(timeIntervalSince1970: 100)
        var window = VoBLEReplayWindow(maximumAge: 30, capacity: 4)
        XCTAssertTrue(window.accept(nonce: Data([1]), timestamp: now, now: now))
        XCTAssertFalse(window.accept(nonce: Data([1]), timestamp: now, now: now))
        XCTAssertFalse(window.accept(
            nonce: Data([2]), timestamp: now.addingTimeInterval(-31), now: now))
        window.revoke()
        XCTAssertFalse(window.accept(nonce: Data([3]), timestamp: now, now: now))
    }

    func testVoBLEConnectionRequiresAuthenticationAndControlSubscription() {
        var reducer = VoBLEConnectionReducer()
        reducer.apply(.bluetoothPoweredOn)
        reducer.apply(.discovered(UUID()))
        reducer.apply(.connected)
        reducer.apply(.characteristicsReady)
        reducer.apply(.controlSubscription(true))
        XCTAssertNotEqual(reducer.state, .ready)

        reducer.apply(.authenticationFailed("wrong key"))
        XCTAssertEqual(reducer.state, .failed("wrong key"))
        reducer.apply(.restored(UUID()))
        XCTAssertEqual(reducer.state, .connecting)
        reducer.apply(.characteristicsReady)
        reducer.apply(.controlSubscription(true))
        reducer.apply(.authenticated(identity: "samsung-test"))
        XCTAssertEqual(reducer.state, .ready)
    }

    func testVoBLEPairingFailureExplainsHowToRecoverStaleCredentials() {
        XCTAssertEqual(
            VoBLEPairingRecovery.userMessage(for: "peer is already paired; authenticated reconnect required"),
            "Android 仍保存旧的 VoBLE 凭据。请在 Android AirSIM → 设置 → VoBLE 认证中清除旧配对，再重新配对。"
        )
        XCTAssertEqual(
            VoBLEPairingRecovery.userMessage(for: "reconnect authentication failed"),
            "两端 VoBLE 密钥不一致。请在 Android AirSIM → 设置 → VoBLE 认证中清除旧配对，再重新配对。"
        )
        XCTAssertEqual(
            VoBLEPairingRecovery.userMessage(for: "peer is not paired"),
            "Android 已没有对应的 VoBLE 凭据。请清除本机旧凭据，然后重新核对安全码。"
        )
        XCTAssertEqual(VoBLEPairingRecovery.userMessage(for: "蓝牙配对失败"), "蓝牙配对失败")
    }

    func testVoBLEControlLedgerRejectsStaleResponseAndExpiresDeadline() {
        var ledger = VoBLEControlRequestLedger()
        let now = Date(timeIntervalSince1970: 100)
        ledger.begin(requestID: "request-1", generation: 7, deadline: now.addingTimeInterval(1))
        XCTAssertEqual(ledger.resolve(requestID: "request-1", generation: 6), .stale)
        XCTAssertEqual(ledger.resolve(requestID: "missing", generation: 7), .missing)
        XCTAssertEqual(ledger.expire(now: now.addingTimeInterval(1.001)), ["request-1"])
    }

    @MainActor
    func testExplicitBluetoothFailureDoesNotStartVoWLANOrCloud() {
        final class FakeBluetooth: VoBLECentralControlling {
            var starts = 0
            var stops = 0
            func start() { starts += 1 }
            func stop() { stops += 1 }
        }
        let bluetooth = FakeBluetooth()
        let controller = VoBLEModeController(bluetooth: bluetooth)
        let actions = controller.activate(.bluetooth)
        XCTAssertEqual(bluetooth.starts, 1)
        XCTAssertFalse(actions.startVoWLAN)
        XCTAssertFalse(actions.startCloud)
        XCTAssertFalse(controller.shouldFallbackAfterBluetoothFailure)
    }

    @MainActor
    func testRemovingPairingResumesScanningButDoesNotReactivateDisabledMode() {
        final class BluetoothTransport: VoBLECentralControlling {
            var operations: [String] = []
            func start() { operations.append("scan") }
            func stop() { operations.append("disconnect") }
        }
        let bluetooth = BluetoothTransport()
        VoBLEPairingConnectionReset.perform(on: bluetooth, resumeScanning: true)
        XCTAssertEqual(bluetooth.operations, ["disconnect", "scan"])
        bluetooth.operations.removeAll()
        VoBLEPairingConnectionReset.perform(on: bluetooth, resumeScanning: false)
        XCTAssertEqual(bluetooth.operations, ["disconnect"])
    }

    func testVoBLECachedConnectionExpiresWithoutInterruptingAuthenticationOrReadyPeer() {
        XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(
            state: .connecting, enabled: true, elapsed: 7.9))
        XCTAssertTrue(VoBLEConnectionTimeoutPolicy.shouldExpire(
            state: .connecting, enabled: true, elapsed: 8))
        XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(
            state: .connecting, enabled: false, elapsed: 20))
        for state in [VoBLEConnectionState.authenticating, .ready, .stopped] {
            XCTAssertFalse(VoBLEConnectionTimeoutPolicy.shouldExpire(
                state: state, enabled: true, elapsed: 20))
        }
    }

    func testConnectionModePreferenceMigratesLegacyLocalModeAndPersistsBluetooth() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: LocalModePreference.key)
        XCTAssertEqual(ConnectionModePreference.selected(defaults: defaults), .vowlan)

        ConnectionModePreference.set(.bluetooth, defaults: defaults)
        XCTAssertEqual(ConnectionModePreference.selected(defaults: defaults), .bluetooth)
        XCTAssertFalse(LocalModePreference.isEnabled(defaults: defaults))
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
    }

    @MainActor
    func testVoWLANTransportFailureFallsBackOnceToCloud() async throws {
        let local = OutgoingCallServiceProbe(dialError: URLError(.timedOut))
        var cloudAttempts = 0

        let result = try await OutgoingCallRouteCoordinator.start(
            number: "10086",
            vowlanService: local,
            cloudModeEnabled: true
        ) {
            cloudAttempts += 1
            return "cloud-call"
        }

        XCTAssertEqual(result, .cloud("cloud-call"))
        XCTAssertEqual(cloudAttempts, 1)
        let localActions = await local.recordedActions()
        XCTAssertEqual(localActions, ["warm", "dial:10086"])
    }

    @MainActor
    func testVoWLANAgentRejectionDoesNotReplayDialThroughCloud() async {
        let local = OutgoingCallServiceProbe(
            dialError: APIError.http(502, "Android Telecom 拒绝拨号")
        )
        var cloudAttempts = 0

        do {
            _ = try await OutgoingCallRouteCoordinator.start(
                number: "10086",
                vowlanService: local,
                cloudModeEnabled: true
            ) {
                cloudAttempts += 1
                return "cloud-call"
            }
            XCTFail("Agent 已明确拒绝时不得通过云端重放非幂等拨号")
        } catch APIError.http(let status, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("预期保留 Agent HTTP 错误，实际为 \(error)")
        }

        XCTAssertEqual(cloudAttempts, 0)
    }

    func testVoWLANDialWaitsPastSamsungTelecomAcknowledgementWindow() {
        XCTAssertGreaterThan(AirSIMAPI.voWLANDialTimeout, 12)
    }

    func testMaintainerBundleUsesDedicatedRelayFallback() {
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            ""
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            "https://push.remotepilot.site/"
        )
    }

    func testRelayHealthRequiresAirSIMServiceIdentity() {
        let airSIM = Data(#"{"ok":true,"service":"airsim-push-relay","version":"0.2.1"}"#.utf8)
        let djonehub = Data(#"{"ok":true,"service":"djonehub-push-relay","version":"1.0.0"}"#.utf8)
        XCTAssertTrue(RelayHealthValidation.accepts(statusCode: 200, data: airSIM))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 200, data: djonehub))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 503, data: airSIM))
    }

    func testRelayQuotaResponseExplainsRegistrationFailure() {
        let response = Data("error code: 1027".utf8)
        let error = CloudAgentStatusError.relayFailure(statusCode: 429, data: response)
        guard case .requestLimitExceeded = error else {
            return XCTFail("Cloudflare 1027 must not be reported as an invalid Relay response")
        }
        XCTAssertTrue(error.localizedDescription.contains("额度"))
    }

    func testCurrentModePrefersVoWLANAndReportsCloudFailure() {
        XCTAssertEqual(
            ConnectionModePresentation.make(
                selectedMode: .automatic,
                vowlanOnline: true,
                bluetoothReady: true,
                cloudModeEnabled: true,
                cloudOnline: true
            ).mode,
            .vowlan
        )
        let bluetooth = ConnectionModePresentation.make(
            selectedMode: .automatic,
            vowlanOnline: false,
            bluetoothReady: true,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        XCTAssertEqual(bluetooth.mode, .bluetooth)
        XCTAssertEqual(bluetooth.status, "已连接")
        let cloud = ConnectionModePresentation.make(
            selectedMode: .automatic,
            vowlanOnline: false,
            bluetoothReady: false,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        XCTAssertEqual(cloud.mode, .cloud)
        XCTAssertEqual(cloud.status, "已连接")

        let unreachable = ConnectionModePresentation.make(
            selectedMode: .cloud,
            vowlanOnline: false,
            bluetoothReady: false,
            cloudModeEnabled: true,
            cloudOnline: false
        )
        XCTAssertEqual(unreachable.mode, .cloud)
        XCTAssertEqual(unreachable.status, "不可达")
    }

    func testCloudSelfTestReportOnlyPassesWhenEveryStagePasses() {
        var report = CloudSelfTestReport.initial
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.steps.map(\.id), CloudSelfTestStepID.allCases)

        for id in CloudSelfTestStepID.allCases {
            report.update(id, state: .passed, detail: "通过")
        }
        report.completedAt = Date()
        XCTAssertTrue(report.allPassed)

        report.update(.agentHeartbeat, state: .failed, detail: "无心跳")
        XCTAssertFalse(report.allPassed)
    }

    func testLiveActivityIncludesCurrentAndroidAgentIdentity() {
        let agent = AndroidAgentPresentation(
            id: "samsung-1",
            deviceName: "samsung SM-F766U",
            phoneNumber: "+8615502030017",
            agentKind: "standalone",
            cloudOnline: true,
            vowlanOnline: true,
            bluetoothOnline: true,
            isCurrent: true
        )
        let state = LiveActivityStateBuilder.make(
            call: nil,
            callerName: nil,
            moduleOnline: true,
            transport: .vowlan,
            radio: nil,
            agent: LiveActivityAgentSnapshot(agent: agent, pairedAgentCount: 2),
            idleStartedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(state.agentDeviceName, "samsung SM-F766U")
        XCTAssertEqual(state.agentPhoneNumber, "+8615502030017")
        XCTAssertEqual(state.agentKind, "standalone")
        XCTAssertEqual(state.pairedAgentCount, 2)
        XCTAssertEqual(state.vowlanOnline, true)
        XCTAssertEqual(state.bluetoothOnline, true)
        XCTAssertEqual(state.cloudOnline, true)
    }

    func testHiddenLiveActivityDoesNotRegisterPushToStartToken() {
        let suiteName = "AirSIMTests.live-activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults),
            "abc123"
        )
        defaults.set(false, forKey: LiveActivityVisibilityPreference.key)
        XCTAssertEqual(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults),
            ""
        )
    }

    func testLocalModeLiveActivityDoesNotRequestRemotePushUpdates() {
        XCTAssertNil(LiveActivityCreationPolicy.pushType(localModeEnabled: true))
        XCTAssertNotNil(LiveActivityCreationPolicy.pushType(localModeEnabled: false))
    }

    func testVoWLANRecoveryRetriesAfterTemporaryVPNRouteLoss() {
        var recovery = VoWLANRecoveryGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let unavailable = VoWLANAvailability.unavailable("VPN 路由切换")

        XCTAssertTrue(recovery.shouldAttempt(for: unavailable, at: start))
        XCTAssertFalse(recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(3)))
        XCTAssertTrue(recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(10)))
        XCTAssertFalse(recovery.shouldAttempt(for: .unpaired, at: start.addingTimeInterval(20)))
    }

    func testIslandCallActionsReserveOnlyRightSideButtonWidth() {
        typealias Phase = AirSIMCallActivityAttributes.ContentState.Phase
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.incoming), 96)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.active), 44)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.held), 44)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.standby), 0)
    }

    func testLiveActivityStateDecodesLegacyPayloadWithoutAgentFields() throws {
        let state = AirSIMCallActivityAttributes.ContentState(
            callID: "",
            number: "",
            displayName: "等待模块来电",
            phase: .standby,
            startedAt: Date(timeIntervalSince1970: 1),
            transport: .vowlan
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            AirSIMCallActivityAttributes.ContentState.self,
            from: encoded
        )

        XCTAssertNil(decoded.agentDeviceName)
        XCTAssertNil(decoded.agentPhoneNumber)
        XCTAssertNil(decoded.pairedAgentCount)
    }

    func testLocalModeForcesEffectiveCloudModeOff() {
        let suiteName = "AirSIMTests.local-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: LocalModePreference.key)
        defaults.set(true, forKey: CloudModePreference.key)

        XCTAssertTrue(LocalModePreference.isEnabled(defaults: defaults))
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
    }

    func testLocalPairingChoiceDoesNotReadCloudCredentialsOrChangeGlobalMode() throws {
        let suite = "AirSIMTests.pairing-choice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: LocalModePreference.key)
        let registration = try SamsungPairingRegistrationPolicy.registration(
            localOnly: true, vowlanSecret: "fixture-key",
            cloudRegistration: { XCTFail("local pairing must not request push credentials"); return nil }
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(registration)) as? [String: Any])
        XCTAssertEqual(payload["vowlan_secret"] as? String, "fixture-key")
        XCTAssertNil(payload["relay_url"])
        XCTAssertFalse(LocalModePreference.isEnabled(defaults: defaults))
    }

    func testCloudPairingChoiceRequiresCredentialsWithoutFallingBackToLocal() throws {
        XCTAssertThrowsError(try SamsungPairingRegistrationPolicy.registration(
            localOnly: false, vowlanSecret: "fixture-key", cloudRegistration: { nil }
        ))
        var cloud = AgentPushRegistration.local(vowlanSecret: "old-key")
        cloud.localMode = false
        let registration = try SamsungPairingRegistrationPolicy.registration(
            localOnly: false, vowlanSecret: "new-key", cloudRegistration: { cloud }
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(registration)) as? [String: Any])
        XCTAssertEqual(payload["local_mode"] as? Bool, false)
        XCTAssertEqual(payload["vowlan_secret"] as? String, "new-key")
        XCTAssertNotNil(payload["relay_url"])
    }

    @MainActor
    func testLocalPairingWaitsForOldAgentWriteAndBlocksNewWrites() async throws {
        let gate = SamsungPairingRegistrationGate()
        XCTAssertTrue(gate.beginAgentWrite())
        var pairingStarted = false
        let pair = Task { @MainActor in
            try await gate.withPairing {
                pairingStarted = true
                XCTAssertFalse(gate.beginAgentWrite())
            }
        }
        await Task.yield()
        XCTAssertFalse(pairingStarted, "old cloud write must finish before local claim")
        XCTAssertFalse(gate.beginAgentWrite(), "no new cloud write while pairing is waiting")
        gate.endAgentWrite()
        try await pair.value
        XCTAssertTrue(pairingStarted)
        XCTAssertTrue(gate.beginAgentWrite(), "other/global operations resume after pairing")
        gate.endAgentWrite()
    }

    @MainActor
    func testPairingFailureReleasesAgentWriteGate() async throws {
        let gate = SamsungPairingRegistrationGate()
        do {
            try await gate.withPairing { throw SamsungPairingClientError.expired }
            XCTFail("pairing must fail")
        } catch { /* preserve original error, unlock for retry */ }
        XCTAssertTrue(gate.beginAgentWrite())
        gate.endAgentWrite()
    }

    func testAutomaticRegistrationPreservesLocalPairingForStandaloneAndLegacyAgent() throws {
        for json in [
            #"{"local_mode":true,"configured":true,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#,
            #"{"configured":true,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#
        ] {
            let status = try JSONDecoder().decode(AgentPushStatus.self, from: Data(json.utf8))
            XCTAssertTrue(status.preservesLocalPairing)
        }
        let unconfigured = try JSONDecoder().decode(AgentPushStatus.self, from: Data(
            #"{"configured":false,"cloud_enabled":false,"call_push_ready":false,"message_push_ready":false}"#.utf8))
        XCTAssertFalse(unconfigured.preservesLocalPairing)
        let cloud = try JSONDecoder().decode(AgentPushStatus.self, from: Data(
            #"{"local_mode":false,"configured":true,"cloud_enabled":false,"relay_url":"https://relay.example","call_push_ready":false,"message_push_ready":false}"#.utf8))
        XCTAssertFalse(cloud.preservesLocalPairing)
    }

    func testLocalPairingPayloadOmitsRelayAndPushCredentials() throws {
        let registration = AgentPushRegistration.local(vowlanSecret: "local-vowlan-secret")
        let data = try JSONEncoder().encode(registration)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["local_mode"] as? Bool, true)
        XCTAssertEqual(payload["cloud_enabled"] as? Bool, false)
        XCTAssertEqual(payload["vowlan_secret"] as? String, "local-vowlan-secret")
        XCTAssertNil(payload["relay_url"])
        XCTAssertNil(payload["device_id"])
        XCTAssertNil(payload["device_secret"])
        XCTAssertNil(payload["voip_token"])
        XCTAssertNil(payload["alert_token"])
    }
}
