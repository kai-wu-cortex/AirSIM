import XCTest
@testable import AirSIM

@MainActor
final class DeviceCallActionRouterTests: XCTestCase {
    // The same safety assertions run over the transport enabled in this build.
    private var fixtureMode: AirSIMConnectionMode { DedicatedCallPolicy.vowlanOnly ? .vowlan : .bluetooth }
    private var fixtureTransport: CallTransport { DedicatedCallPolicy.vowlanOnly ? .vowlan : .bluetooth }

    func testWLANLossChecksAndroidTerminalBeforeEndingWatchCall() async throws {
        let backend = DeviceBackendProbe(id: "A")
        let context = DeviceCallContext()
        let router = DeviceCallActionRouter(context: context) { _, _ in backend }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .vowlan)
        backend.endedEvidence = true
        var authoritative = false
        router.onFinish = { _, value in authoritative = value }
        let alert = await router.resolveWLANLoss(route.key, stillLost: { true })
        XCTAssertFalse(alert)
        XCTAssertTrue(authoritative)
        XCTAssertNil(context.registry.active)
        XCTAssertEqual(backend.commands, ["dial:fixture"], "Already ended Watch call needs no extra hangup")
    }

    func testWLANLossRechecksRecoveryAfterStatusReply() async throws {
        let backend = DeviceBackendProbe(id: "A")
        let context = DeviceCallContext()
        let router = DeviceCallActionRouter(context: context) { _, _ in backend }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .vowlan)
        var lost = true
        backend.beforeEvidenceReply = { lost = false }
        let alert = await router.resolveWLANLoss(route.key, stillLost: { lost })
        XCTAssertFalse(alert)
        XCTAssertEqual(context.registry.active, route.key)
        XCTAssertEqual(backend.commands, ["dial:fixture"])
    }

    func testWatchEndDuringLossProbeCannotProduceStaleAlert() async throws {
        let backend = DeviceBackendProbe(id: "A")
        let context = DeviceCallContext()
        let router = DeviceCallActionRouter(context: context) { _, _ in backend }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .vowlan)
        backend.beforeEvidenceReply = { router.finished(route.key, authoritative: true) }
        let alert = await router.resolveWLANLoss(route.key, stillLost: { true })
        XCTAssertFalse(alert)
        XCTAssertEqual(backend.commands, ["dial:fixture"])
    }

    func testRealWLANLossStillEndsLiveCallAndReportsIt() async throws {
        let backend = DeviceBackendProbe(id: "A")
        let context = DeviceCallContext()
        let router = DeviceCallActionRouter(context: context) { _, _ in backend }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .vowlan)
        let alert = await router.resolveWLANLoss(route.key, stillLost: { true })
        XCTAssertTrue(alert)
        XCTAssertNil(context.registry.active)
        XCTAssertEqual(backend.commands, ["dial:fixture", "end:shared"])
    }

    func testMirrorEndIsIdempotentAndCannotEndNewPhoneCall() async throws {
        let backend = DeviceBackendProbe(id: "A")
        let controller = CallKitController(observesSystemCallbacks: false); controller.setEnabled(false)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend }, callKitController: controller)
        defer { model.stop() }
        let coordinator = WatchCallCoordinator(); coordinator.configure(model: model)
        let a = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        let identity: [String: Any] = ["call_id": "shared", "call_uuid": a.systemUUID.uuidString]
        var reply: [String: Any] = [:]
        await coordinator.endPhoneMirror(identity) { reply = $0 }
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertNil(model.deviceCalls.active)
        backend.replyCallID = "second-call"
        let b = try await model.deviceCallRouter.dial(agentID: "A", number: "second", mode: .vowlan)
        await coordinator.endPhoneMirror(identity) { reply = $0 }
        XCTAssertEqual(reply["ok"] as? Bool, true, "An ended phone mirror needs no native Watch CallKit transaction")
        XCTAssertEqual(model.deviceCalls.active, b.key)
        let wrong = ["call_id": "wrong", "call_uuid": b.systemUUID.uuidString]
        await coordinator.endPhoneMirror(wrong) { reply = $0 }
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(model.deviceCalls.active, b.key)
        XCTAssertEqual(backend.commands, ["dial:fixture", "end:shared", "dial:second"])
    }

    func testDedicatedBuildConstrainsRequestsToVoWLANWithoutBLEFallback() async throws {
        try XCTSkipUnless(DedicatedCallPolicy.vowlanOnly, "Only applies to the dedicated build")
        let backend = DeviceBackendProbe(id: "A")
        let availableBLE = DeviceBackendProbe(id: "A")
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, transport in
            transport == .vowlan ? backend : availableBLE
        }
        let route = try await router.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        XCTAssertEqual(route.transport, .vowlan, "A stale BLE preference is constrained to WLAN")
        XCTAssertTrue(availableBLE.commands.isEmpty, "Availability checks must never invoke BLE call control")
        XCTAssertEqual(backend.commands, ["dial:fixture"])
        let ble = DeviceBackendProbe(id: "A")
        let offlineWLAN = DeviceCallActionRouter(context: DeviceCallContext()) { _, transport in
            transport == .bluetooth ? ble : nil
        }
        do {
            _ = try await offlineWLAN.dial(agentID: "A", number: "fixture", mode: .automatic)
            XCTFail("An offline WLAN must not fall back to Bluetooth")
        } catch { XCTAssertEqual(error as? DeviceCallRoutingError, .unavailable) }
        XCTAssertTrue(ble.commands.isEmpty)
    }

    func testPushFirstAdoptionKeepsUUIDAndLifecycleThroughAnswerAndEnd() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.vowlan)
        defer { ConnectionModePreference.set(old) }
        let controller = CallKitController(observesSystemCallbacks: false); controller.setEnabled(false)
        let service = DeviceBackendProbe(id: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in service }, callKitController: controller)
        defer { model.stop() }
        let uuid = UUID()
        model.callKitDidReceiveIncoming(.init(bluetoothCallID: "backend", uuid: uuid,
            generation: 7, number: nil, agentID: "A"))
        let route = try model.deviceCallRouter.adoptIncoming(.init(agentID: "A", callID: "canonical",
            state: .ringing, transport: .vowlan, transportEpoch: 1, backendCallID: "backend"),
            systemUUID: uuid, service: service, presentationCallID: "backend", presentationGeneration: 7)
        service.beforeAnswerReply = {
            XCTAssertEqual(model.deviceCalls.latestEvent(for: route.key)?.state, .connecting)
            _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "canonical", state: .ringing,
                transport: .vowlan, transportEpoch: 1, backendCallID: "backend"))
            XCTAssertTrue(model.otherDeviceCallReminders.isEmpty)
            try? await model.deviceCallRouter.answer(route.key, source: "duplicate")
        }
        try await model.callKitAnswer(uuid: uuid, origin: .system)
        XCTAssertEqual(model.deviceCalls.active, route.key)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, "backend")
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, uuid)
        XCTAssertEqual(model.callLifecycleSnapshot.generation, 7)
        XCTAssertEqual(model.callLifecycleSnapshot.state, .connecting)
        XCTAssertNil(model.callConnectedAt, "An answer ACK is not carrier connection evidence")
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "canonical", state: .active,
            transport: .vowlan, transportEpoch: 1, backendCallID: "backend"))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .active)
        try await model.callKitAnswer(uuid: uuid, origin: .system)
        XCTAssertEqual(service.commands, ["answer:backend"])
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "unrelated-history", state: .ended,
            transport: .vowlan, transportEpoch: 1))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .active)
        try await model.callKitEnd(uuid: uuid)
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertNil(model.deviceCallContext.media.owner)
        XCTAssertEqual(service.commands, ["answer:backend", "end:backend"])
    }

    func testDuplicateAnswerIsIdempotentAndOldTerminalCannotEndNewCall() async throws {
        let service = DeviceBackendProbe(id: "A")
        let context = DeviceCallContext()
        let router = DeviceCallActionRouter(context: context) { _, _ in service }
        let first = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "one",
            state: .ringing, transport: .vowlan, transportEpoch: 1), mode: .vowlan))
        try await router.answer(first.key)
        try await router.answer(first.key)
        XCTAssertEqual(service.commands, ["answer:one"])
        XCTAssertTrue(context.registry.ringing.isEmpty)
        try await router.end(first.key, rejectIfRinging: false)
        let second = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "two",
            state: .ringing, transport: .vowlan, transportEpoch: 1), mode: .vowlan))
        try await router.answer(second.key)
        _ = router.ingest(.init(agentID: "A", callID: "one", state: .ended,
            transport: .vowlan, transportEpoch: 1), mode: .vowlan)
        XCTAssertEqual(context.registry.active, second.key)
        XCTAssertEqual(context.media.owner, second.key)
    }

    func testPreconnectPresentationNeverStartsConnectedClock() async throws {
        let service = DeviceBackendProbe(id: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in service })
        defer { model.stop() }
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        XCTAssertNil(model.callConnectedAt)
        XCTAssertFalse(model.callAudioIsActive)
        model.callKitAudioSessionDidDeactivate()
        await model.callKitAudioSessionDidActivate()
        XCTAssertEqual(model.callLifecycleSnapshot.state, .connecting)
        XCTAssertNil(model.callConnectedAt)
        XCTAssertEqual(service.commands, ["dial:fixture"])
        for state in ["dialing", "alerting", "connecting"] {
            let content = CallSurfaceContent(state: state)
            XCTAssertEqual(content.phase, .outgoing)
            XCTAssertFalse(content.showsDuration)
            XCTAssertEqual(content.secondaryActions, [.speaker])
        }
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "shared", state: .active,
            transport: .vowlan, transportEpoch: 1, backendGeneration: 1, direction: "outgoing"))
        let connectedAt = try XCTUnwrap(model.callConnectedAt)
        XCTAssertTrue(CallSurfaceContent(state: "active").showsDuration)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "shared", state: .active,
            transport: .vowlan, transportEpoch: 1, backendGeneration: 1, direction: "outgoing"))
        XCTAssertEqual(model.callConnectedAt, connectedAt)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "shared", state: .ended,
            transport: .vowlan, transportEpoch: 1, backendGeneration: 1, direction: "outgoing"))
        XCTAssertNil(model.callConnectedAt)
        XCTAssertEqual(service.commands, ["dial:fixture"])
    }

    func testAuthenticatedTerminalSurvivesUnavailableDiscoveryMetadata() async throws {
        let tone = FixtureToneOutput(), service = DeviceBackendProbe(id: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: tone), deviceBackend: { _, _ in service })
        defer { model.stop() }
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        // No directory metadata: models the interval while health is reverified.
        let ended = CallRecord(id: "shared", index: 0, direction: "outgoing", state: "ended",
            number: nil, startedAt: Date(), updatedAt: Date(), endedAt: Date(), missed: false, androidID: "shared")
        XCTAssertTrue(model.applyAgentCallRecord(ended, agentID: "A"))
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, route.systemUUID)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertNil(model.deviceCallContext.media.owner)
        XCTAssertNil(model.inAppPresentedCall)
        let beforeCue = tone.plays
        await Task.yield()
        XCTAssertEqual(tone.plays, beforeCue + 1)
        let plays = tone.plays
        _ = model.applyAgentCallRecord(ended, agentID: "A")
        await Task.yield()
        XCTAssertEqual(tone.plays, plays)
        XCTAssertEqual(service.commands, ["dial:fixture"])
        let next = try await model.deviceCallRouter.dial(agentID: "B", number: "fixture", mode: .vowlan)
        _ = model.applyAgentCallRecord(ended, agentID: "A")
        XCTAssertEqual(model.deviceCalls.active, next.key)
    }

    func testReceiptTerminalRequiresBothIDsAndAgentAndWLANOwnership() async throws {
        let modes: [AirSIMConnectionMode] = DedicatedCallPolicy.vowlanOnly ? [.vowlan] : [.vowlan, .bluetooth]
        for transport in modes {
            let service = DeviceBackendProbe(id: "A")
            let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
                deviceBackend: { _, _ in service })
            let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: transport)
            for (agent, backend, canonical) in [("B", "shared", "shared"), ("A", "wrong", "shared"), ("A", "shared", "wrong")] {
                let record = CallRecord(id: backend, index: 0, direction: "outgoing", state: "ended",
                    number: nil, startedAt: Date(), updatedAt: Date(), endedAt: Date(), missed: false, androidID: canonical)
                XCTAssertFalse(model.deviceCallRouter.ingestOwnedWLANClosure(record, agentID: agent, mode: transport))
                XCTAssertEqual(model.deviceCalls.active, route.key)
            }
            let active = CallRecord(id: "shared", index: 0, direction: "outgoing", state: "active",
                number: nil, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false, androidID: "shared")
            XCTAssertFalse(model.deviceCallRouter.ingestOwnedWLANClosure(active, agentID: "A", mode: transport))
            let terminal = CallRecord(id: "shared", index: 0, direction: "outgoing", state: "ended",
                number: nil, startedAt: Date(), updatedAt: Date(), endedAt: Date(), missed: false, androidID: "shared")
            XCTAssertEqual(model.deviceCallRouter.ingestOwnedWLANClosure(terminal, agentID: "A", mode: transport), transport == .vowlan)
            if transport == .bluetooth { XCTAssertEqual(model.deviceCalls.active, route.key) }
            XCTAssertEqual(service.commands, ["dial:fixture"])
            model.stop()
        }
    }

    func testConnectedWLANClosureReleasesMediaWithoutFailureCue() async throws {
        let tone = FixtureToneOutput(), service = DeviceBackendProbe(id: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: tone), deviceBackend: { _, _ in service })
        defer { model.stop() }
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "shared", state: .active,
            transport: .vowlan, transportEpoch: 1, backendGeneration: 1, direction: "outgoing", backendCallID: "shared"))
        let before = tone.plays
        let ended = CallRecord(id: "shared", index: 0, direction: "outgoing", state: "ended",
            number: nil, startedAt: Date(), updatedAt: Date(), endedAt: Date(), missed: false, androidID: "shared")
        XCTAssertTrue(model.applyAgentCallRecord(ended, agentID: "A"))
        await Task.yield()
        XCTAssertEqual(tone.plays, before)
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertNil(model.deviceCallContext.media.owner)
    }

    func testOwnedPollSourceRequiresExactCapturedCredentialAndRoute() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.2.90", controlPort: 18080, pcmPort: 18081)
        let credential = try VoWLANCredential(secret: Data(repeating: 1, count: 32))
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
        let backend = WLANDeviceCallBackend(api: api, epoch: 1, agentID: "A")
        let context = DeviceCallContext()
        let router = DeviceCallActionRouter(context: context) { _, _ in backend }
        let route = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "fixture",
            state: .ringing, transport: .vowlan, transportEpoch: 1), mode: .vowlan))
        XCTAssertNil(router.ownedAgentID(for: api))
        XCTAssertTrue(context.registry.activate(route.key))
        XCTAssertEqual(router.ownedAgentID(for: api), "A")
        let otherCredential = try VoWLANCredential(secret: Data(repeating: 2, count: 32))
        XCTAssertNil(router.ownedAgentID(for: AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: otherCredential))))
        let otherEndpoint = try VoWLANEndpoint(host: "192.168.2.91", controlPort: 18080, pcmPort: 18081)
        XCTAssertNil(router.ownedAgentID(for: AirSIMAPI(route: .vowlan(endpoint: otherEndpoint, credential: credential))))
        router.finished(route.key)
        XCTAssertNil(router.ownedAgentID(for: api))
    }

    func testRecoveredEndedReceiptRetiresExactRouteWithoutAnotherBackendAction() async throws {
        let tone = FixtureToneOutput(), service = DeviceBackendProbe(id: "A")
        service.recoveredState = .ended
        let model = AppModel(audioController: AudioSessionController(toneOutput: tone), deviceBackend: { _, _ in service })
        defer { model.stop() }
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        await Task.yield()
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, route.systemUUID)
        XCTAssertEqual(service.commands, ["dial:fixture"])
        XCTAssertEqual(model.errorMessage, "呼叫未接通，通话已结束。")
    }
    func testUnknownSubmissionCleanupDoesNotClaimRemoteEnd() async throws {
        let tone = FixtureToneOutput(), service = DeviceBackendProbe(id: "A")
        service.dialError = DialOperationRecoveryError.unknown
        let model = AppModel(audioController: AudioSessionController(toneOutput: tone), deviceBackend: { _, _ in service })
        defer { model.stop() }
        let historyBefore = model.callHistory
        do { _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth); XCTFail("unknown") }
        catch {}
        let before = tone.plays
        await Task.yield()
        XCTAssertEqual(tone.plays, before)
        XCTAssertNotEqual(model.errorMessage, "呼叫未接通，通话已结束。")
        XCTAssertEqual(model.callLifecycleSnapshot.source, .app)
        XCTAssertEqual(model.callHistory, historyBefore)
    }

    func testR18RemotePreconnectEndStopsPresentationAndCuesOnlyOnce() async throws {
        let tone = FixtureToneOutput(), service = DeviceBackendProbe(id: "A")
        let audio = AudioSessionController(toneOutput: tone)
        let model = AppModel(audioController: audio, deviceBackend: { _, _ in service })
        defer { model.stop() }
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: fixtureMode,
                                                         operationID: "explicit-intent")
        XCTAssertEqual(service.lastOperationID, "explicit-intent")
        let before = tone.plays
        let terminal = DeviceCallEvent(agentID: "A", callID: "shared", state: .ended,
            transport: fixtureTransport, transportEpoch: 1, backendGeneration: 1, direction: "outgoing")
        _ = model.receiveOwnedCallEvent(terminal)
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertNil(model.deviceCallContext.media.owner)
        XCTAssertFalse(audio.active)
        await Task.yield()
        XCTAssertEqual(tone.plays, before + 1)
        XCTAssertEqual(model.errorMessage, "呼叫未接通，通话已结束。")
        _ = model.receiveOwnedCallEvent(terminal)
        await Task.yield()
        XCTAssertEqual(tone.plays, before + 1)
        XCTAssertEqual(service.commands, ["dial:fixture"], "No second backend dial or unsolicited hangup")
        let replacement = try await model.deviceCallRouter.dial(agentID: "B", number: "fixture2", mode: fixtureMode)
        _ = model.receiveOwnedCallEvent(terminal)
        XCTAssertEqual(model.deviceCalls.active, replacement.key)
        XCTAssertNotEqual(route.key, replacement.key)
    }

    func testR18LocalCancelDoesNotPlayFailureCue() async throws {
        let tone = FixtureToneOutput(), service = DeviceBackendProbe(id: "A")
        let model = AppModel(audioController: AudioSessionController(toneOutput: tone), deviceBackend: { _, _ in service })
        defer { model.stop() }
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        let before = tone.plays
        try await model.callKitEnd(uuid: route.systemUUID)
        await Task.yield()
        XCTAssertEqual(tone.plays, before)
        XCTAssertEqual(service.commands, ["dial:fixture", "end:shared"])
    }

    func testTerminalCleanupKeepsCapturedHangupBackendUntilReply() async throws {
        let gate = BackendReplyGate(), started = expectation(description: "end awaiting reply")
        var service: DeviceBackendProbe? = DeviceBackendProbe(id: "A")
        service?.beforeEndReply = { started.fulfill(); await gate.wait() }
        weak var retained = service
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        let route = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "end-in-flight",
            state: .ringing, transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
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
            state: .ringing, transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
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
                callID: "ended-\(index)", state: .ringing, transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
            if oldest == nil { oldest = route.systemUUID }
            model.deviceCallRouter.finished(route.key)
        }
        let active = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: fixtureMode)
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
                state: .ringing, transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
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
            transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
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
            transport: fixtureTransport, transportEpoch: 1, backendGeneration: 3))
        let key = try XCTUnwrap(model.deviceCalls.key(agentID: "A", callID: "same-call"))
        let route = try XCTUnwrap(model.deviceCallRouter.route(for: key))
        let localID = model.callLifecycleSnapshot.callID
        model.callKitDidReceiveIncoming(.init(bluetoothCallID: "same-call", uuid: UUID(),
            generation: 3, number: nil, agentID: "A"))
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, route.systemUUID)
        try await model.callKitAnswer(uuid: route.systemUUID, origin: .system)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same-call", state: .active,
            transport: fixtureTransport, transportEpoch: 1, backendGeneration: 3))
        XCTAssertEqual(model.deviceCallContext.media.owner, key)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same-call", state: .ended,
            transport: fixtureTransport, transportEpoch: 1, backendGeneration: 3))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, localID)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, route.systemUUID)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertNil(model.deviceCallContext.media.owner)
        XCTAssertEqual(backend.commands, ["answer:same-call"])
    }

    func testOtherLaneEventCannotInvalidateProvenBLEAliasBeforeACK() async throws {
        try XCTSkipIf(DedicatedCallPolicy.vowlanOnly, "Requires VoBLE aliases; this build intentionally permits VoWLAN calls only")
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
        try XCTSkipIf(DedicatedCallPolicy.vowlanOnly, "Requires VoBLE aliases; this build intentionally permits VoWLAN calls only")
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
        try XCTSkipIf(DedicatedCallPolicy.vowlanOnly, "Requires VoBLE aliases; this build intentionally permits VoWLAN calls only")
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
        try XCTSkipIf(DedicatedCallPolicy.vowlanOnly, "Requires VoBLE aliases; this build intentionally permits VoWLAN calls only")
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
        let active = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: fixtureMode)
        let before = model.callLifecycleSnapshot
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: fixtureTransport, transportEpoch: 1))
        let key = try XCTUnwrap(model.deviceCalls.key(agentID: "B", callID: "shared"))
        let route = try XCTUnwrap(model.deviceCallRouter.route(for: key))
        try await model.callKitEnd(uuid: route.systemUUID)
        XCTAssertEqual(b.commands, ["reject:shared"])
        XCTAssertEqual(a.commands, ["dial:fixture"])
        XCTAssertEqual(model.deviceCallContext.media.owner, active.key)
        XCTAssertEqual(model.callLifecycleSnapshot, before)
    }

    func testWLANAndBLEIncomingForSameDeviceYieldSingleSystemCall() throws {
        try XCTSkipIf(DedicatedCallPolicy.vowlanOnly, "Requires VoBLE aliases; this build intentionally permits VoWLAN calls only")
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
            transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
        let b = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "same", state: .ringing,
            transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
        XCTAssertNotEqual(a.systemUUID, b.systemUUID)
        XCTAssertNotEqual(a.key, b.key)
    }

    func testIdleIncomingSelectionChangesSystemPresentationWithoutRejectingOtherAndroid() throws {
        let service = DeviceBackendProbe(id: "fixture")
        let router = DeviceCallActionRouter(context: DeviceCallContext()) { _, _ in service }
        let a = try XCTUnwrap(router.registerIncoming(.init(agentID: "A", callID: "same", state: .ringing,
            transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
        let b = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "same", state: .ringing,
            transport: fixtureTransport, transportEpoch: 1), mode: fixtureMode))
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
        let enabledTransport = fixtureTransport
        let router = DeviceCallActionRouter(context: context) { agent, route in
            guard route == enabledTransport else { return nil }; return agent == "A" ? a : b
        }
        let request = Task { try await router.dial(agentID: selected, number: "test", mode: fixtureMode) }
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
        let active = try await router.dial(agentID: "A", number: "test", mode: fixtureMode)
        let incoming = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: fixtureTransport, transportEpoch: 1, backendGeneration: 1), mode: fixtureMode))
        router.finished(incoming.key)
        XCTAssertEqual(context.media.owner, active.key)
        XCTAssertEqual(context.registry.active, active.key)
        XCTAssertEqual(a.commands, ["dial:test"])
    }

    func testCallKitActionForBDoesNotHangupCurrentA() async throws {
        let context = DeviceCallContext(), a = DeviceBackendProbe(id: "A"), b = DeviceBackendProbe(id: "B")
        let router = DeviceCallActionRouter(context: context) { id, _ in id == "A" ? a : b }
        let active = try await router.dial(agentID: "A", number: "test", mode: fixtureMode)
        let incoming = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: fixtureTransport, transportEpoch: 1, backendGeneration: 1), mode: fixtureMode))
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
        let active = try await router.dial(agentID: "A", number: "test", mode: fixtureMode)
        let incoming = try XCTUnwrap(router.registerIncoming(.init(agentID: "B", callID: "shared", state: .ringing,
            transport: fixtureTransport, transportEpoch: 1, backendGeneration: 1), mode: fixtureMode))
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
    var endedEvidence = false
    var beforeEvidenceReply: () async -> Void = {}
    func confirmsEnded(callID: String) async throws -> Bool {
        await beforeEvidenceReply()
        return endedEvidence
    }
    var beforeDialReply: () async -> Void = {}
    var beforeEndReply: () async -> Void = {}
    var beforeAnswerReply: () async -> Void = {}
    var answerError: Error?
    var lastSimAccount: String?
    var lastOperationID: String?
    var provisionalReply = false
    var replyCallID = "shared"
    var recoveredState: CallLifecycleState?
    var dialError: Error?
    init(id: String) { self.id = id }
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        lastOperationID = operationID
        commands.append("dial:\(number)"); await beforeDialReply()
        if let dialError { throw dialError }
        return DeviceBackendCall(callID: provisionalReply ? operationID : replyCallID,
            backendID: provisionalReply ? operationID : replyCallID, generation: 1, recoveredState: recoveredState)
    }
    func dial(number: String, operationID: String, systemUUID: UUID,
              simAccount: String?) async throws -> DeviceBackendCall {
        lastSimAccount = simAccount
        return try await dial(number: number, operationID: operationID, systemUUID: systemUUID)
    }
    func answer(callID: String, generation: UInt64?) async throws {
        commands.append("answer:\(callID)")
        await beforeAnswerReply()
        if let answerError { throw answerError }
    }
    func end(callID: String, generation: UInt64?, reject: Bool) async throws {
        commands.append("\(reject ? "reject" : "end"):\(callID)")
        await beforeEndReply()
    }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws { commands.append("dtmf:\(callID):\(digits)") }
}


@MainActor
final class WatchCompanionSMSProtocolTests: XCTestCase {
    private func withFixture(_ body: (AppModel, WatchCallCoordinator) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = ["airsim.paired-android-devices.v1", "airsim.forgotten-android-devices.v1", AndroidAgentBindingPreference.key]
        let old = keys.map { defaults.object(forKey: $0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("watch-sms-test-" + UUID().uuidString)
        defer {
            for (index, key) in keys.enumerated() {
                if let value = old[index] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        PairedAndroidDeviceStore.remember(.init(id: "A", deviceName: "Fixture A", agentKind: "standalone"))
        PairedAndroidDeviceStore.remember(.init(id: "B", deviceName: "Fixture B", agentKind: "standalone"))
        let controller = CallKitController(observesSystemCallbacks: false); controller.setEnabled(false)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
                             callKitController: controller, historyStore: LocalHistoryStore(directoryURL: directory))
        defer { model.stop() }
        let coordinator = WatchCallCoordinator(); coordinator.configure(model: model)
        try body(model, coordinator)
    }
    private func request(_ coordinator: WatchCallCoordinator, _ payload: [String: Any]) -> [String: Any] {
        var response: [String: Any] = [:]
        coordinator.handleWatchSMS(payload) { response = $0 }
        return response
    }
    func testSMSReloadDoesNotMergeCallHistoryOrTouchCallState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-background-sms-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalHistoryStore(directoryURL: dir)
        let old = CallRecord(id: "old", index: 1, direction: "outgoing", state: "ended", number: nil,
            startedAt: Date(), updatedAt: Date(), endedAt: Date(), missed: false)
        XCTAssertTrue(store.saveCallHistory([old]))
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), historyStore: store)
        defer { model.stop() }
        model.callHistory = []
        model.reloadMessagesFromLocalStore()
        XCTAssertTrue(model.callHistory.isEmpty, "A background SMS read must not trigger call-history reconciliation")
        XCTAssertNil(model.deviceCalls.active)
    }

    func testWatchConversationCombinesDirectionsAndKeepsDeviceScope() throws {
        try withFixture { model, coordinator in
            let now = Date()
            let incoming = SMSMessage(sender: "+86 13800138000", content: "received", code: nil, timestamp: now,
                deliveryID: "in", sourceAgentID: "A", simSlot: "SIM 1")
            let outgoing = SMSMessage(sender: "13800138000", content: "sent", code: nil, timestamp: now.addingTimeInterval(1),
                deliveryID: "out", direction: .outgoing, sourceAgentID: "A", simSlot: "SIM 2")
            let other = SMSMessage(sender: "13800138000", content: "other device", code: nil, timestamp: now,
                deliveryID: "other", sourceAgentID: "B", simSlot: "SIM 1")
            model.messages = [incoming, outgoing, other]
            let reply = request(coordinator, ["action": "watch_sms_thread", "agent_id": "A", "peer": WatchSMSConversationPolicy.peer(incoming.sender)])
            let page = try JSONDecoder().decode(WatchSMSPage.self, from: XCTUnwrap(reply["sms_data"] as? Data))
            XCTAssertEqual(page.rows.count, 2)
            XCTAssertEqual(Set(page.rows.map(\.agentID)), ["A"])
            XCTAssertEqual(Set(page.rows.map(\.outgoing)), [true, false])
            XCTAssertEqual(Set(page.rows.compactMap(\.sim)), ["SIM 1", "SIM 2"])
            let conversations = WatchSMSConversationPolicy.groups(page.rows)
            XCTAssertEqual(conversations.count, 1)
            XCTAssertEqual(conversations[0].rows.map(\.preview), ["received", "sent"])
            XCTAssertTrue(model.unreadMessageIDs.contains(incoming.id), "Conversation previews must not mark messages read")
        }
    }

    func testSourceIsolationDetailAndReadAcknowledgement() throws {
        try withFixture { model, coordinator in
            let a = SMSMessage(sender: "fixture", content: "body A", code: nil, timestamp: Date(), deliveryID: "one", sourceAgentID: "A", simSlot: "SIM 2")
            let b = SMSMessage(sender: "fixture", content: "body B", code: nil, timestamp: Date(), deliveryID: "one", sourceAgentID: "B", simSlot: "SIM 1")
            let legacy = SMSMessage(sender: "fixture", content: "unscoped", code: nil, timestamp: Date(), deliveryID: "legacy")
            model.messages = [a, b, legacy]
            let response = request(coordinator, ["action": "watch_sms_list", "agent_id": "A"])
            XCTAssertEqual(response["ok"] as? Bool, true)
            let page = try JSONDecoder().decode(WatchSMSPage.self, from: XCTUnwrap(response["sms_data"] as? Data))
            XCTAssertEqual(page.rows.count, 1)
            let row = try XCTUnwrap(page.rows.first)
            XCTAssertEqual(row.agentID, "A"); XCTAssertEqual(row.sim, "SIM 2")
            XCTAssertTrue(model.unreadMessageIDs.contains(a.id), "Listing must not mark read")
            let detailReply = request(coordinator, ["action": "watch_sms_detail", "agent_id": "A", "message_id": row.id])
            let detail = try JSONDecoder().decode(WatchSMSDetail.self, from: XCTUnwrap(detailReply["sms_data"] as? Data))
            XCTAssertEqual(detail.body, "body A")
            XCTAssertTrue(model.unreadMessageIDs.contains(a.id), "Fetch is not a read acknowledgement")
            let wrong = request(coordinator, ["action": "watch_sms_detail", "agent_id": "B", "message_id": row.id])
            XCTAssertEqual(wrong["ok"] as? Bool, false)
            let unpaired = request(coordinator, ["action": "watch_sms_list", "agent_id": "foreign"])
            XCTAssertEqual(unpaired["ok"] as? Bool, false)
            let read = request(coordinator, ["action": "watch_sms_read", "agent_id": "A", "message_id": row.id])
            XCTAssertEqual(read["ok"] as? Bool, true)
            XCTAssertFalse(model.unreadMessageIDs.contains(a.id))
            XCTAssertTrue(model.unreadMessageIDs.contains(b.id), "Read cannot clear another device")
        }
    }
    func testMultipleDevicesRequireSelectionAndUnknownReadDoesNotMutate() throws {
        try withFixture { model, coordinator in
            let record = SMSMessage(sender: "fixture", content: "body", code: nil, timestamp: Date(), deliveryID: "one", sourceAgentID: "A")
            model.messages = [record]
            let response = request(coordinator, ["action": "watch_sms_list"])
            let page = try JSONDecoder().decode(WatchSMSPage.self, from: XCTUnwrap(response["sms_data"] as? Data))
            XCTAssertNil(page.selectedAgentID); XCTAssertTrue(page.rows.isEmpty)
            XCTAssertEqual(page.devices.count, 2)
            let read = request(coordinator, ["action": "watch_sms_read", "agent_id": "A", "message_id": "unknown"])
            XCTAssertEqual(read["ok"] as? Bool, false)
            XCTAssertTrue(model.unreadMessageIDs.contains(record.id))
        }
    }
    func testOversizedEscapedBodyIsBoundedAndMarked() throws {
        try withFixture { model, coordinator in
            let body = String(repeating: "\u{0000}\\\n", count: 20_000)
            model.messages = [SMSMessage(sender: "fixture", content: body, code: nil, timestamp: Date(), deliveryID: "one", sourceAgentID: "A")]
            let response = request(coordinator, ["action": "watch_sms_list", "agent_id": "A"])
            let page = try JSONDecoder().decode(WatchSMSPage.self, from: XCTUnwrap(response["sms_data"] as? Data))
            let row = try XCTUnwrap(page.rows.first)
            let reply = request(coordinator, ["action": "watch_sms_detail", "agent_id": "A", "message_id": row.id])
            let data = try XCTUnwrap(reply["sms_data"] as? Data)
            XCTAssertLessThanOrEqual(data.count, WatchSMSPolicy.payloadBudget)
            let detail = try JSONDecoder().decode(WatchSMSDetail.self, from: data)
            XCTAssertTrue(detail.truncated); XCTAssertTrue(body.hasPrefix(detail.body))
        }
    }
}


@MainActor
final class WatchCompanionCallRaceTests: XCTestCase {
    func testWatchDTMFRequiresConnectedExactCallAndNeverTargetsDefault() async throws {
        let started = expectation(description: "Watch answer pending")
        let wire = WatchAnswerHTTPFixture(id: "native-A", onAnswer: { started.fulfill() })
        let credential = try VoWLANCredential(secret: Data(repeating: 0x42, count: 32))
        let endpoint = try VoWLANEndpoint(host: "192.168.77.1", controlPort: 8787, pcmPort: 8790)
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential), transport: wire)
        let backend = WLANDeviceCallBackend(api: api, epoch: 1, agentID: "A")
        let controller = CallKitController(observesSystemCallbacks: false); controller.setEnabled(false)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend }, callKitController: controller)
        defer { model.stop() }
        let coordinator = WatchCallCoordinator(); coordinator.configure(model: model)
        let route = try XCTUnwrap(model.deviceCallRouter.registerIncoming(.init(agentID: "A", callID: "native-A",
            state: .ringing, transport: .vowlan, transportEpoch: 1, backendCallID: "native-A"), mode: .vowlan))
        let presentation = "local:\(Data("A".utf8).base64EncodedString()):\(route.key.generation):\(route.systemUUID.uuidString)"
        let identity: [String: Any] = ["call_id": presentation, "call_uuid": route.systemUUID.uuidString, "agent_id": "A"]
        let answering = Task { await coordinator.answerLocallyFromWatch(identity) { _ in } }
        await fulfillment(of: [started], timeout: 3)
        var early: [String: Any] = [:]
        await coordinator.sendWatchDTMF(identity.merging(["digit": "1"]) { _, new in new }) { early = $0 }
        XCTAssertEqual(early["ok"] as? Bool, false, "Carrier answer confirmation is required")
        await wire.releaseAnswer(); await answering.value
        for digit in ["1", "*", "#"] {
            var reply: [String: Any] = [:]
            await coordinator.sendWatchDTMF(identity.merging(["digit": digit]) { _, new in new }) { reply = $0 }
            XCTAssertEqual(reply["ok"] as? Bool, true)
        }
        for digit in ["12", "A", "１", ""] {
            var reply: [String: Any] = [:]
            await coordinator.sendWatchDTMF(identity.merging(["digit": digit]) { _, new in new }) { reply = $0 }
            XCTAssertEqual(reply["ok"] as? Bool, false)
        }
        let wrong = identity.merging(["digit": "9", "call_uuid": UUID().uuidString]) { _, new in new }
        var stale: [String: Any] = [:]
        await coordinator.sendWatchDTMF(wrong) { stale = $0 }
        XCTAssertEqual(stale["ok"] as? Bool, false)
        let ownerEnd = identity.merging(["event": "watch_call_owner", "phase": "ended"]) { _, new in new }
        let consumed = await coordinator.consumeWatchOwnership(ownerEnd)
        XCTAssertTrue(consumed)
        XCTAssertNil(model.deviceCalls.active, "Durable Watch owner-end must retire the phone call even if live end RPC was lost")
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        var duplicate: [String: Any] = [:]
        await coordinator.endLocalWatchCall(identity) { duplicate = $0 }
        XCTAssertEqual(duplicate["ok"] as? Bool, true, "A confirmed terminal call acknowledges a late backup without another hangup")
        await coordinator.sendWatchDTMF(identity.merging(["digit": "0"]) { _, new in new }) { stale = $0 }
        XCTAssertEqual(stale["ok"] as? Bool, false)
        let sent = await wire.dtmfTargets
        XCTAssertEqual(sent.map(\.0), ["1", "*", "#"])
        XCTAssertEqual(sent.map(\.1), ["native-A", "native-A", "native-A"])
        let ends = await wire.endedTargets
        XCTAssertEqual(ends, ["native-A"], "Live and durable end delivery must not repeat the backend hangup")
        coordinator.recordAndroidEnd(uuid: route.systemUUID, agentID: "A", callIDs: ["native-A"])
        let restarted = WatchCallCoordinator()
        var receipt: [String: Any] = [:]
        await restarted.checkWatchEnd(identity) { receipt = $0 }
        XCTAssertEqual(receipt["confirmed"] as? Bool, true, "Verified end survives restarting the companion")
        await restarted.checkWatchEnd(identity.merging(["call_id": "other"]) { _, value in value }) { receipt = $0 }
        XCTAssertNil(receipt["confirmed"], "A persisted receipt cannot confirm a different call")

    }

    func testWatchHandoffFailureDoesNotSendHangup() async throws {
        let started = expectation(description: "Android answer pending")
        let wire = WatchAnswerHTTPFixture(id: "native-A", onAnswer: { started.fulfill() })
        let credential = try VoWLANCredential(secret: Data(repeating: 0x42, count: 32))
        let endpoint = try VoWLANEndpoint(host: "192.168.77.1", controlPort: 8787, pcmPort: 8790)
        let api = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential), transport: wire)
        let backend = WLANDeviceCallBackend(api: api, epoch: 1, agentID: "A")
        let controller = CallKitController(observesSystemCallbacks: false); controller.setEnabled(false)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend }, callKitController: controller)
        defer { model.stop() }
        let coordinator = WatchCallCoordinator(); coordinator.configure(model: model)
        let route = try XCTUnwrap(model.deviceCallRouter.registerIncoming(.init(agentID: "A", callID: "native-A",
            state: .ringing, transport: .vowlan, transportEpoch: 1, backendCallID: "native-A"), mode: .vowlan))
        let identity: [String: Any] = ["call_id": "native-A", "call_uuid": route.systemUUID.uuidString, "agent_id": "A"]
        let task = Task { await coordinator.answerLocallyFromWatch(identity) { _ in } }
        await fulfillment(of: [started], timeout: 3)
        _ = await coordinator.consumeWatchOwnership(identity.merging(["event": "watch_call_owner", "phase": "handoff_failed"]) { _, new in new })
        await wire.releaseAnswer(); await task.value
        let commands = await wire.endedTargets
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(model.deviceCalls.active, route.key)
        XCTAssertFalse(coordinator.ownsMedia(callID: "native-A"))
    }

    func testAnswerThenImmediateHangupAndLateReplyCannotClearNextWatchCall() async throws {
        let startedA = expectation(description: "A answer suspended"), startedB = expectation(description: "B answer suspended")
        let wireA = WatchAnswerHTTPFixture(id: "native-A", onAnswer: { startedA.fulfill() })
        let wireB = WatchAnswerHTTPFixture(id: "native-B", onAnswer: { startedB.fulfill() })
        let credential = try VoWLANCredential(secret: Data(repeating: 0x42, count: 32))
        let endpoint = try VoWLANEndpoint(host: "192.168.77.1", controlPort: 8787, pcmPort: 8790)
        let apiA = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential), transport: wireA)
        let apiB = AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential), transport: wireB)
        let backendA = WLANDeviceCallBackend(api: apiA, epoch: 1, agentID: "A")
        let backendB = WLANDeviceCallBackend(api: apiB, epoch: 1, agentID: "B")
        let controller = CallKitController(observesSystemCallbacks: false); controller.setEnabled(false)
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { id, _ in id == "A" ? backendA : backendB }, callKitController: controller)
        defer { model.stop() }
        let coordinator = WatchCallCoordinator(); coordinator.configure(model: model)
        func incoming(_ agent: String, _ id: String) throws -> (LockedDeviceCallRoute, [String: Any]) {
            let route = try XCTUnwrap(model.deviceCallRouter.registerIncoming(.init(agentID: agent, callID: id,
                state: .ringing, transport: .vowlan, transportEpoch: 1, backendCallID: id), mode: .vowlan))
            let presentation = "local:\(Data(agent.utf8).base64EncodedString()):\(route.key.generation):\(route.systemUUID.uuidString)"
            return (route, ["call_id": presentation, "call_uuid": route.systemUUID.uuidString, "agent_id": agent])
        }
        let (a, messageA) = try incoming("A", "native-A")
        var answerA: [String: Any] = [:]
        let taskA = Task { await coordinator.answerLocallyFromWatch(messageA) { answerA = $0 } }
        await fulfillment(of: [startedA], timeout: 3)
        var endA: [String: Any] = [:]
        await coordinator.rejectLocalWatchCall(messageA) { endA = $0 }
        XCTAssertEqual(endA["ok"] as? Bool, true, "Hangup during answer must target the claimed call")
        XCTAssertTrue(model.deviceCalls.latestEvent(for: a.key)?.state.isTerminal == true)
        let (b, messageB) = try incoming("B", "native-B")
        var answerB: [String: Any] = [:]
        let taskB = Task { await coordinator.answerLocallyFromWatch(messageB) { answerB = $0 } }
        await fulfillment(of: [startedB], timeout: 3)
        var sms: [String: Any] = [:]
        coordinator.handleWatchSMS(["action": "watch_sms_list"]) { sms = $0 }
        XCTAssertEqual(sms["ok"] as? Bool, false, "Call setup takes priority over inbox work")
        await wireA.releaseAnswer(); await taskA.value
        XCTAssertEqual(answerA["ok"] as? Bool, false)
        XCTAssertEqual(model.deviceCallContext.media.owner, b.key, "Old answer cannot release new media owner")
        let oldOwnerEnd = messageA.merging(["event": "watch_call_owner", "phase": "ended"]) { _, new in new }
        _ = await coordinator.consumeWatchOwnership(oldOwnerEnd)
        XCTAssertEqual(model.deviceCallContext.media.owner, b.key, "Delayed old owner-end cannot terminate the new Watch call")
        var endB: [String: Any] = [:]
        await coordinator.endLocalWatchCall(messageB) { endB = $0 }
        XCTAssertEqual(endB["ok"] as? Bool, true, "Old answer failure must not clear the new Watch claim")
        await wireB.releaseAnswer(); await taskB.value
        XCTAssertEqual(answerB["ok"] as? Bool, false)
        let targetsA = await wireA.endedTargets, targetsB = await wireB.endedTargets
        XCTAssertEqual(targetsA, ["native-A"]); XCTAssertEqual(targetsB, ["native-B"])
        var confirmed: [String: Any] = [:]
        await coordinator.checkWatchEnd(messageB) { confirmed = $0 }
        XCTAssertEqual(confirmed["confirmed"] as? Bool, true)
    }
}
private actor WatchAnswerHTTPFixture: AirSIMHTTPTransport {
    let id: String
    let onAnswer: @Sendable () -> Void
    private var pending: CheckedContinuation<Void, Never>?
    private var ended = false
    private var connected = false
    private(set) var dtmfTargets: [(String, String)] = []
    private(set) var endedTargets: [String] = []
    init(id: String, onAnswer: @escaping @Sendable () -> Void) { self.id = id; self.onAnswer = onAnswer }
    func releaseAnswer() { connected = true; pending?.resume(); pending = nil }
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        switch request.url?.path {
        case "/api/calls/answer":
            await withCheckedContinuation { continuation in pending = continuation; onAnswer() }
            return WiredHTTPResponse(statusCode: 200, body: Data("{}".utf8))
        case "/api/calls/hangup", "/api/calls/reject":
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            endedTargets.append(body?["call_id"] ?? "UNSCOPED"); ended = true
            return WiredHTTPResponse(statusCode: 200, body: Data("{\"ok\":true}".utf8))
        case "/api/calls/dtmf":
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            dtmfTargets.append((body?["digit"] ?? "", body?["call_id"] ?? "UNSCOPED"))
            return WiredHTTPResponse(statusCode: 200, body: Data("{}".utf8))
        case "/api/calls/status":
            let record = CallRecord(id: id, index: 1, direction: "incoming", state: ended ? "ended" : connected ? "active" : "incoming", number: nil,
                startedAt: Date(), updatedAt: Date(), endedAt: ended ? Date() : nil, missed: false)
            let status = CallStatus(active: ended ? nil : record, history: ended ? [record] : [], polling: true,
                eventDriven: true, pollIntervalSeconds: 2, lastPollError: "", revision: 1)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return WiredHTTPResponse(statusCode: 200, body: try encoder.encode(status))
        default: return WiredHTTPResponse(statusCode: 200, body: Data("{}".utf8))
        }
    }
}
