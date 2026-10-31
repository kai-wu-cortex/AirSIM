import XCTest
@testable import AirSIM

@MainActor
final class DeviceCallActionRouterTests: XCTestCase {
    func testTerminalCleanupKeepsCapturedHangupBackendUntilReply() async throws {
        let gate = BackendReplyGate(), started = expectation(description: "end awaiting reply")
        var service: DeviceBackendProbe? = DeviceBackendProbe(id: "A")
        service?.beforeEndReply = { started.fulfill(); await gate.wait() }
        weak var retained = service
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        let route = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "end-in-flight",
            state: .ringing, transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
        service = nil
        let ending = Task { try await router.end(route.key, rejectIfRinging: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(router.hasPendingTermination)
        XCTAssertNotNil(retained)
        XCTAssertEqual(retained?.commands, ["reject:end-in-flight"])
        XCTAssertNil(router.route(for: route.systemUUID))
        await gate.release()
        try await ending.value
        XCTAssertFalse(router.hasPendingTermination)
        XCTAssertNil(retained)
    }

    func testDialCarriesSelectedSIMAccountToBackend() async throws {
        let service = DeviceBackendProbe(id: "A")
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        let route = try await router.dial(agentID: "A", number: "10086", mode: .bluetooth,
                                          simAccount: "slot-2")
        XCTAssertEqual(service.lastSimAccount, "slot-2")
        XCTAssertEqual(service.commands, ["dial:10086"])
        router.finished(route.key)
    }

    func testFailedAnswerReleasesOwnershipAndAllowsRetry() async throws {
        let service = DeviceBackendProbe(id: "A")
        service.answerError = VoBLECentralError.disconnected
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        let route = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "answer-retry",
            state: .ringing, transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
        do {
            try await router.answer(route.key)
            XCTFail("the failed answer must throw")
        } catch {}
        XCTAssertNil(router.context.registry.active)
        XCTAssertNil(router.context.media.owner)
        XCTAssertEqual(router.context.registry.latestEvent(for: route.key)?.state, .ringing)
        service.answerError = nil
        try await router.answer(route.key)
        XCTAssertEqual(router.context.registry.active, route.key)
        XCTAssertEqual(router.context.media.owner, route.key)
        router.finished(route.key)
    }

    func testExpiredCallKitUUIDCannotHangupReplacementCall() async throws {
        let service = DeviceBackendProbe(id: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in service })
        defer { model.stop() }
        var oldest: UUID?
        for index in 0..<300 {
            let route = try XCTUnwrap(model.deviceCallRouter.registerIncoming(.init(agentID: "history",
                callID: "ended-\(index)", state: .ringing, transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
            if oldest == nil { oldest = route.systemUUID }
            model.deviceCallRouter.finished(route.key)
        }
        let active = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        do { try await model.callKitEnd(uuid: try XCTUnwrap(oldest)) } catch {
            XCTAssertEqual(error as? DeviceCallRoutingError, .stale)
        }
        XCTAssertEqual(model.deviceCalls.active, active.key)
        XCTAssertEqual(service.commands, ["dial:fixture"])
        await model.hangup()
    }

    func testTerminalHistoryIsBoundedAndDoesNotRetainBackendResources() throws {
        weak var retired: DeviceBackendProbe?
        var service: DeviceBackendProbe?
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        var lastUUID: UUID?
        for index in 0..<300 {
            service = DeviceBackendProbe(id: "history")
            retired = service
            let route = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "history-\(index)",
                state: .ringing, transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
            service = nil
            lastUUID = route.systemUUID
            router.finished(route.key)
        }
        XCTAssertLessThanOrEqual(router.routes.count, 128)
        XCTAssertNil(retired, "terminal UUID tombstones must not retain live backend sessions")
        XCTAssertTrue(router.contains(uuid: try XCTUnwrap(lastUUID)), "recent stale CallKit actions stay recognizable")
        XCTAssertNil(router.route(for: try XCTUnwrap(lastUUID)))
        service = DeviceBackendProbe(id: "B")
        let active = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "new", state: .ringing,
            transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
        XCTAssertEqual(router.route(for: active.systemUUID), active)
    }

    func testOwnedAudioStartupSurvivesUnrelatedPollRestart() async throws {
        let old = ConnectionModePreference.selected()
        ConnectionModePreference.set(.vowlan)
        defer { ConnectionModePreference.set(old) }
        let backend = DeviceBackendProbe(id: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend })
        defer { model.stop() }
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "shared", state: .active,
            transport: .vowlan, transportEpoch: 1, backendCallID: "shared"))
        let invalidation = model.makeLocalAudioStartupInvalidationCheck()
        XCTAssertNil(invalidation())
        model.restartPolling()
        XCTAssertNil(invalidation(), "Poll refresh cannot cancel the unchanged owned call")
        model.deviceCallRouter.finished(route.key)
        XCTAssertNotNil(invalidation(), "A real hangup must still invalidate in-flight audio startup")
    }
    func testLegacyAudioRegistrationSurvivesPollRestart() async {
        let old = ConnectionModePreference.selected()
        ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(old) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()))
        defer { model.stop() }
        let now = Date()
        let call = CallRecord(id: "legacy-push", index: 0, direction: "incoming", state: "active",
            number: "fixture", startedAt: now, updatedAt: now, endedAt: nil, missed: false)
        XCTAssertTrue(model.applyAgentCallRecord(call))
        XCTAssertNil(model.deviceCalls.active, "Exercise the APNs/legacy path, not an owned device call")
        let invalidation = model.makeLocalAudioStartupInvalidationCheck()
        var rollbacks = 0
        let outcome = await LocalCallAudioStartupCoordinator.start(
            invalidationReason: invalidation, activatePhoneAudio: { true },
            registerAgentAudio: { model.restartPolling(); return .registered },
            rollbackPhoneAudio: { _ in rollbacks += 1 })
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(rollbacks, 0)
        XCTAssertTrue(model.applyAgentCallRecord(call, forcedState: .ended))
        XCTAssertEqual(invalidation(), .callNotActive, "Actual call termination must still revoke startup")
    }

    func testLocalFirstCallKeepsIdentityWhenPushArrivesBeforeAnswer() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.automatic)
        defer { ConnectionModePreference.set(old) }
        let backend = DeviceBackendProbe(id: "A"), controller = CallKitController()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend }, callKitController: controller)
        defer { model.stop() }
        controller.setEnabled(false)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same-call", state: .ringing,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 3))
        let key = try XCTUnwrap(model.deviceCalls.key(agentID: "A", callID: "same-call"))
        let route = try XCTUnwrap(model.deviceCallRouter.route(for: key))
        let localID = model.callLifecycleSnapshot.callID
        model.callKitDidReceiveIncoming(.init(bluetoothCallID: "same-call", uuid: UUID(),
            generation: 3, number: nil, agentID: "A"))
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, route.systemUUID)
        try await model.callKitAnswer(uuid: route.systemUUID, origin: .system)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same-call", state: .active,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 3))
        XCTAssertEqual(model.deviceCallContext.media.owner, key)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same-call", state: .ended,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 3))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, localID)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, route.systemUUID)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertNil(model.deviceCallContext.media.owner)
        XCTAssertEqual(backend.commands, ["answer:same-call"])
    }

    func testOtherLaneEventCannotInvalidateProvenBLEAliasBeforeACK() async throws {
        let backend = DeviceBackendProbe(id: "A")
        backend.provisionalReply = true
        let context = DeviceCallContext()
        var wlanReady = false
        let router = DeviceCallActionRouter(context: context) { _, lane in
            lane == .bluetooth || wlanReady ? backend : nil
        }
        backend.beforeDialReply = {
            let key = context.registry.active!
            _ = router.ingest(.init(agentID: "A", callID: key.callID, state: .connecting,
                transport: .bluetooth, transportEpoch: 1, backendGeneration: 1,
                direction: "outgoing"), mode: .localDual)
            _ = router.ingest(.init(agentID: "A", callID: "telecom-A", replacesCallID: key.callID,
                state: .active, transport: .bluetooth, transportEpoch: 1,
                backendGeneration: 1, direction: "outgoing"), mode: .localDual)
            wlanReady = true
            _ = router.ingest(.init(agentID: "A", callID: "telecom-A", state: .active,
                transport: .vowlan, transportEpoch: 1, direction: "outgoing",
                backendCallID: "wlan-backend-A"), mode: .localDual)
        }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .localDual)
        XCTAssertEqual(route.transport, .bluetooth)
        XCTAssertEqual(context.media.owner, route.key)
        try await router.end(route.key, rejectIfRinging: false)
        XCTAssertEqual(backend.commands.last, "end:telecom-A", "WLAN status cannot replace the locked BLE target")
    }
    func testAuthenticatedBLEAliasBeforeProvisionalReplyKeepsCanonicalTarget() async throws {
        let backend = DeviceBackendProbe(id: "A")
        backend.provisionalReply = true
        let context = DeviceCallContext()
        let router = DeviceCallActionRouter(context: context) { _, _ in backend }
        backend.beforeDialReply = {
            let key = context.registry.active!
            // The outgoing intent establishes this authenticated lane's generation.
            _ = router.ingest(.init(agentID: "A", callID: key.callID, state: .connecting,
                transport: .bluetooth, transportEpoch: 1, backendGeneration: 1,
                direction: "outgoing"), mode: .bluetooth)
            // CoreBluetooth can deliver Telecom's alias while the ACK continuation
            // still holds the earlier provisional identity snapshot.
            _ = router.ingest(.init(agentID: "A", callID: "telecom-A", replacesCallID: key.callID,
                state: .active, transport: .bluetooth, transportEpoch: 1,
                backendGeneration: 1, direction: "outgoing"), mode: .bluetooth)
        }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        XCTAssertEqual(context.registry.active, route.key)
        XCTAssertEqual(context.media.owner, route.key)
        XCTAssertEqual(context.registry.latestEvent(for: route.key)?.callID, "telecom-A")
        try await router.end(route.key, rejectIfRinging: false)
        XCTAssertEqual(backend.commands.last, "end:telecom-A")
    }
    func testWLANEventAfterProvisionalBLEAckWaitsForAuthenticatedAlias() async throws {
        let backend = DeviceBackendProbe(id: "A")
        backend.provisionalReply = true
        let context = DeviceCallContext()
        var wlanReady = false
        let router = DeviceCallActionRouter(context: context) { _, lane in
            lane == .bluetooth || wlanReady ? backend : nil
        }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .localDual)
        XCTAssertEqual(route.transport, .bluetooth)
        wlanReady = true
        _ = router.ingest(.init(agentID: "A", callID: "shared", state: .active, transport: .vowlan,
            transportEpoch: 1, direction: "outgoing", backendCallID: "wlan-backend"), mode: .localDual)
        XCTAssertNil(context.registry.key(agentID: "A", callID: "shared"), "WLAN is not proof of BLE operation alias")
        _ = router.ingest(.init(agentID: "A", callID: "shared", replacesCallID: route.key.callID,
            state: .active, transport: .bluetooth, transportEpoch: 1, backendGeneration: 1,
            direction: "outgoing"), mode: .localDual)
        XCTAssertEqual(context.registry.key(agentID: "A", callID: "shared"), route.key)
        XCTAssertEqual(context.registry.latestEvent(for: route.key)?.state, .active)
        XCTAssertEqual(context.media.owner, route.key)
        try await router.sendDTMF("1", for: route.key)
        XCTAssertEqual(backend.commands.last, "dtmf:shared:1")
    }
    func testLateLegacyWLANPollCannotSplitPendingBLECallIdentity() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.localDual)
        defer { ConnectionModePreference.set(old) }
        let backend = DeviceBackendProbe(id: "A"), gate = BackendReplyGate()
        let pending = expectation(description: "BLE command awaiting reply")
        backend.beforeDialReply = { pending.fulfill(); await gate.wait() }
        let controller = CallKitController(); controller.setEnabled(true)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, lane in lane == .bluetooth ? backend : nil }, callKitController: controller)
        try await controller.startOutgoingCall(number: "fixture", systemStart: { _ in })
        let uuid = try XCTUnwrap(controller.currentSystemCallUUID)
        model.deviceCallRouter.systemUUID = { uuid }
        let dial = Task { try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .localDual) }
        await fulfillment(of: [pending], timeout: 2)
        let now = Date()
        let late = CallRecord(id: "shared", index: 1, direction: "outgoing", state: "dialing",
            number: nil, startedAt: now, updatedAt: now, endedAt: nil, missed: false)
        // This is the consumer of a VoWLAN poll issued BEFORE the BLE dial.
        // Its legacy payload is not a proof of the pending operation's alias.
        XCTAssertFalse(model.applyAgentCallRecord(late, agentID: "A"))
        XCTAssertNil(model.deviceCalls.key(agentID: "A", callID: "shared"))
        await gate.release()
        let route = try await dial.value
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "shared", state: .active,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 1, direction: "outgoing"))
        XCTAssertEqual(model.deviceCalls.key(agentID: "A", callID: "shared"), route.key)
        XCTAssertEqual(model.deviceCallContext.media.owner, route.key)
        XCTAssertEqual(model.callLifecycleSnapshot.state, .active)
        XCTAssertEqual(model.remoteCall?.state, "active")
        await model.hangup()
    }
    func testWatchSourceSnapshotDoesNotUseAnotherDefaultDevice() throws {
        let credential = try VoWLANCredential(secret: Data(repeating: 0x41, count: 32))
        let endpoint = try VoWLANEndpoint(host: "10.0.0.2", controlPort: 7592, pcmPort: 7593)
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { id, lane in
            id == "A" && lane == .vowlan ? WLANDeviceCallBackend(api: api, epoch: 1) : nil
        }
        let route = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "telecom-A", state: .ringing,
            transport: .vowlan, transportEpoch: 1, backendCallID: "backend-A"), mode: .vowlan))
        let target = try XCTUnwrap(router.wlanTarget(for: route.systemUUID, agentID: "A"))
        XCTAssertEqual(target.backendID, "backend-A")
        XCTAssertEqual(target.route.key, route.key)
        XCTAssertEqual(target.api.route, api.route)
        XCTAssertNil(router.wlanTarget(for: route.systemUUID, agentID: "B"))
        XCTAssertNil(router.wlanTarget(for: UUID(), agentID: "A"))
    }

    func testRejectedOldEpochCannotRetargetDTMFBackendID() async throws {
        let service = DeviceBackendProbe(id: "A")
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        _ = router.ingest(.init(agentID: "A", callID: "shared", state: .active, transport: .bluetooth,
            transportEpoch: 1, backendGeneration: 1, backendCallID: "shared"), mode: .bluetooth)
        _ = router.ingest(.init(agentID: "A", callID: "shared", state: .active, transport: .bluetooth,
            transportEpoch: 0, backendGeneration: 1, backendCallID: "stale-target"), mode: .bluetooth)
        try await router.sendDTMF("1", for: route.key)
        XCTAssertEqual(service.commands, ["dial:fixture", "dtmf:shared:1"])
    }

    func testAuthoritativeEventBeforeDialReceiptDoesNotSplitTheCall() async throws {
        let context = DeviceCallContext(), service = DeviceBackendProbe(id: "A")
        let gate = BackendReplyGate(), started = expectation(description: "dial pending")
        service.beforeDialReply = { started.fulfill(); await gate.wait() }
        let router = DeviceCallActionRouter(context: context) { _, _ in service }
        let task = Task { try await router.dial(agentID: "A", number: "fixture", mode: .vowlan) }
        await fulfillment(of: [started], timeout: 2)
        _ = router.ingest(.init(agentID: "A", callID: "shared", state: .active, transport: .vowlan,
            transportEpoch: 1, number: "fixture", direction: "outgoing", backendCallID: "shared"), mode: .vowlan)
        await gate.release()
        let route = try await task.value
        XCTAssertEqual(context.registry.key(agentID: "A", callID: "shared"), route.key)
        XCTAssertEqual(context.registry.latestEvent(for: route.key)?.state, .active)
        XCTAssertEqual(context.media.owner, route.key)
    }

    func testProductionAppIngressKeepsAWhenBEndsAndUUIDActionTargetsB() async throws {
        let a = DeviceBackendProbe(id: "A"), b = DeviceBackendProbe(id: "B")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { id, _ in id == "A" ? a : b })
        let active = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        let before = model.callLifecycleSnapshot
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: .bluetooth, transportEpoch: 1))
        let key = try XCTUnwrap(model.deviceCalls.key(agentID: "B", callID: "shared"))
        let route = try XCTUnwrap(model.deviceCallRouter.route(for: key))
        try await model.callKitEnd(uuid: route.systemUUID)
        XCTAssertEqual(b.commands, ["reject:shared"])
        XCTAssertEqual(a.commands, ["dial:fixture"])
        XCTAssertEqual(model.deviceCallContext.media.owner, active.key)
        XCTAssertEqual(model.callLifecycleSnapshot, before)
    }

    func testWLANAndBLEIncomingForSameDeviceYieldSingleSystemCall() throws {
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in DeviceBackendProbe(id: "A") }
        let ble = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "telecom", state: .ringing,
            transport: .bluetooth, transportEpoch: 1), mode: .automatic))
        let wlan = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "telecom", state: .ringing,
            transport: .vowlan, transportEpoch: 1, backendCallID: "backend"), mode: .automatic))
        XCTAssertEqual(ble.systemUUID, wlan.systemUUID)
        XCTAssertEqual(wlan.transport, .vowlan, "prefer WLAN before explicit answer, never during active call")
    }

    func testRawCallIDCollisionOnTwoPhonesKeepsSeparateUUIDs() throws {
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in DeviceBackendProbe(id: "fixture") }
        let a = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "same", state: .ringing,
            transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
        let b = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "same", state: .ringing,
            transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
        XCTAssertNotEqual(a.systemUUID, b.systemUUID)
        XCTAssertNotEqual(a.key, b.key)
    }

    func testIdleIncomingSelectionChangesSystemPresentationWithoutRejectingOtherAndroid() throws {
        let service = DeviceBackendProbe(id: "fixture")
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        let a = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "same", state: .ringing,
            transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
        let b = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "same", state: .ringing,
            transport: .bluetooth, transportEpoch: 1), mode: .bluetooth))
        XCTAssertEqual(router.route(for: b.systemUUID), b)
        XCTAssertEqual(router.context.registry.latestEvent(for: a.key)?.state, .ringing)
        XCTAssertTrue(service.commands.isEmpty)
    }

    func testCloudPushReportFailureDoesNotEndLocalA() async throws {
        let context = DeviceCallContext(), a = DeviceBackendProbe(id: "A")
        let router = DeviceCallActionRouter(context: context) { _, _ in a }
        let active = try await router.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        XCTAssertNil(router.route(for: UUID()))
        XCTAssertEqual(context.registry.active, active.key)
        XCTAssertEqual(context.media.owner, active.key)
    }

    func testSelectingBAfterADialDoesNotMoveLateDialResult() async throws {
        let context = DeviceCallContext(), a = DeviceBackendProbe(id: "A"), b = DeviceBackendProbe(id: "B")
        var selected = "A"
        let started = expectation(description: "dial A suspended")
        let gate = BackendReplyGate()
        a.beforeDialReply = { started.fulfill(); await gate.wait() }
        let router = DeviceCallActionRouter(context: context) { agent, route in
            guard route == .bluetooth else { return nil }; return agent == "A" ? a : b
        }
        let request = Task { try await router.dial(agentID: selected, number: "test", mode: .bluetooth) }
        await fulfillment(of: [started], timeout: 1)
        selected = "B"
        await gate.release()
        let route = try await request.value
        XCTAssertEqual(route.key.agentID, "A")
        XCTAssertEqual(a.commands, ["dial:test"])
        XCTAssertTrue(b.commands.isEmpty)
        XCTAssertEqual(context.media.owner, route.key)
    }

    func testBHangupAndDisconnectCannotReleaseAMedia() async throws {
        let context = DeviceCallContext(), a = DeviceBackendProbe(id: "A"), b = DeviceBackendProbe(id: "B")
        let router = DeviceCallActionRouter(context: context) { id, _ in id == "A" ? a : b }
        let active = try await router.dial(agentID: "A", number: "test", mode: .bluetooth)
        let incoming = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 1), mode: .bluetooth))
        router.finished(incoming.key)
        XCTAssertEqual(context.media.owner, active.key)
        XCTAssertEqual(context.registry.active, active.key)
        XCTAssertEqual(a.commands, ["dial:test"])
    }

    func testCallKitActionForBDoesNotHangupCurrentA() async throws {
        let context = DeviceCallContext(), a = DeviceBackendProbe(id: "A"), b = DeviceBackendProbe(id: "B")
        let router = DeviceCallActionRouter(context: context) { id, _ in id == "A" ? a : b }
        let active = try await router.dial(agentID: "A", number: "test", mode: .bluetooth)
        let incoming = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 1), mode: .bluetooth))
        XCTAssertEqual(router.route(for: incoming.systemUUID)?.key, incoming.key)
        try await router.end(incoming.key, rejectIfRinging: true)
        XCTAssertEqual(b.commands, ["reject:shared"])
        XCTAssertEqual(a.commands, ["dial:test"])
        XCTAssertEqual(context.media.owner, active.key)
        XCTAssertNil(router.route(for: UUID()))
    }

    func testOfflineSelectedDeviceNeverDialsAnotherReadyDevice() async {
        let context = DeviceCallContext(), a = DeviceBackendProbe(id: "A")
        let router = DeviceCallActionRouter(context: context) { id, _ in id == "A" ? a : nil }
        do { _ = try await router.dial(agentID: "B", number: "test", mode: .automatic); XCTFail("offline B routed") } catch {}
        XCTAssertTrue(a.commands.isEmpty)
        XCTAssertNil(context.media.owner)
    }

    func testBusyAnswerDoesNotEndAOrAnswerB() async throws {
        let context = DeviceCallContext(), a = DeviceBackendProbe(id: "A"), b = DeviceBackendProbe(id: "B")
        let router = DeviceCallActionRouter(context: context) { id, _ in id == "A" ? a : b }
        let active = try await router.dial(agentID: "A", number: "test", mode: .bluetooth)
        let incoming = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 1), mode: .bluetooth))
        do { try await router.answer(incoming.key); XCTFail("busy answer must not interrupt A") } catch {}
        XCTAssertTrue(b.commands.isEmpty)
        XCTAssertEqual(context.media.owner, active.key)
    }
}

private actor BackendReplyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async { if !open { await withCheckedContinuation { continuation = $0 } } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class DeviceBackendProbe: DeviceCallBackend {
    let epoch: UInt64 = 1
    let id: String
    var commands: [String] = []
    var beforeDialReply: () async -> Void = {}
    var beforeEndReply: () async -> Void = {}
    var answerError: Error?
    var lastSimAccount: String?
    var provisionalReply = false
    init(id: String) { self.id = id }
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        commands.append("dial:\(number)"); await beforeDialReply()
        return DeviceBackendCall(callID: provisionalReply ? operationID : "shared",
            backendID: provisionalReply ? operationID : "shared", generation: 1)
    }
    func dial(number: String, operationID: String, systemUUID: UUID,
              simAccount: String?) async throws -> DeviceBackendCall {
        lastSimAccount = simAccount
        return try await dial(number: number, operationID: operationID, systemUUID: systemUUID)
    }
    func answer(callID: String, generation: UInt64?) async throws {
        commands.append("answer:\(callID)")
        if let answerError { throw answerError }
    }
    func end(callID: String, generation: UInt64?, reject: Bool) async throws {
        commands.append("\(reject ? "reject" : "end"):\(callID)")
        await beforeEndReply()
    }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws { commands.append("dtmf:\(callID):\(digits)") }
}
