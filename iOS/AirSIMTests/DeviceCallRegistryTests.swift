import XCTest
@testable import AirSIM

final class DeviceCallRegistryTests: XCTestCase {
    private func event(_ agent: String, _ state: CallLifecycleState,
                       _ transport: CallTransport = .bluetooth, epoch: UInt64 = 1,
                       direction: String = "incoming") -> DeviceCallEvent {
        event(agent, "shared", state, transport, epoch: epoch, direction: direction)
    }
    private func event(_ agent: String, _ id: String = "shared", _ state: CallLifecycleState,
                       _ transport: CallTransport = .bluetooth, epoch: UInt64 = 1,
                       replaces: String? = nil, direction: String = "incoming") -> DeviceCallEvent {
        DeviceCallEvent(agentID: agent, callID: id, replacesCallID: replaces,
            state: state, transport: transport, transportEpoch: epoch,
            backendGeneration: transport == .bluetooth ? 1 : nil, direction: direction)
    }

    func testSameRawCallIDOnTwoAgentsDoesNotCollide() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("A", .ringing))
        let a = try XCTUnwrap(registry.ringing.first)
        XCTAssertTrue(registry.activate(a))
        _ = registry.apply(event("A", .active))
        let effects = registry.apply(event("B", .ringing))
        let b = try XCTUnwrap(registry.key(agentID: "B", callID: "shared"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(effects, [.remind(b)])
        XCTAssertEqual(registry.active, a)
        _ = registry.apply(event("B", .ended))
        XCTAssertEqual(registry.active, a)
    }

    func testTwoTransportsForSameBackendCallRemindOnce() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("A", .connecting, direction: "outgoing"))
        let a = try XCTUnwrap(registry.key(agentID: "A", callID: "shared"))
        XCTAssertTrue(registry.activate(a))
        let first = registry.apply(event("B", .ringing, .vowlan, epoch: 100))
        let b = try XCTUnwrap(registry.ringing.first)
        XCTAssertEqual(first, [.remind(b)])
        XCTAssertEqual(registry.apply(event("B", .ringing, .bluetooth, epoch: 2)), [])
        XCTAssertEqual(registry.ringing, [b])
    }

    func testEndedTombstoneRejectsLateRinging() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("A", .ringing))
        let a = try XCTUnwrap(registry.ringing.first)
        _ = registry.apply(event("A", .ended))
        XCTAssertEqual(registry.apply(event("A", .ringing, .vowlan, epoch: 999)), [])
        XCTAssertTrue(registry.ringing.isEmpty)
        XCTAssertFalse(registry.activate(a))
    }

    func testTerminalMappingKeepsLaneWatermarksAndDoesNotReopenOrEndTwice() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(.init(agentID: "A", callID: "telecom-A", state: .ringing,
            transport: .vowlan, transportEpoch: 9, backendCallID: "backend-A"))
        _ = registry.apply(.init(agentID: "A", callID: "telecom-A", state: .ringing,
            transport: .bluetooth, transportEpoch: 2, backendGeneration: 11))
        let key = try XCTUnwrap(registry.key(agentID: "A", callID: "telecom-A"))
        let first = registry.apply(.init(agentID: "A", callID: "telecom-A", state: .ended,
            transport: .bluetooth, transportEpoch: 2, backendGeneration: 11))
        XCTAssertEqual(first, [.dismiss(key), .ended(key)])
        _ = registry.apply(.init(agentID: "A", callID: "telecom-A", state: .ended,
            transport: .vowlan, transportEpoch: 8, backendCallID: "stale-backend"))
        XCTAssertNil(registry.latestEvent(for: key)?.backendCallID)
        let mapped = DeviceCallEvent(agentID: "A", callID: "telecom-A", state: .ended,
            transport: .vowlan, transportEpoch: 9, backendCallID: "backend-A")
        XCTAssertEqual(registry.apply(mapped), [], "The second terminal must not repeat lifecycle effects")
        XCTAssertEqual(registry.latestEvent(for: key)?.backendCallID, "backend-A")
        _ = registry.apply(.init(agentID: "A", callID: "telecom-A", state: .ended,
            transport: .bluetooth, transportEpoch: 2, backendGeneration: 10))
        XCTAssertEqual(registry.latestEvent(for: key)?.backendCallID, "backend-A")
        _ = registry.apply(.init(agentID: "A", callID: "telecom-A", state: .active,
            transport: .bluetooth, transportEpoch: 99, backendGeneration: 99))
        XCTAssertEqual(registry.latestEvent(for: key)?.state, .ended)
        XCTAssertFalse(registry.activate(key))
        XCTAssertTrue(registry.ringing.isEmpty)
    }

    func testProvisionalAliasCannotAdoptAnotherAgentsCall() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("A", "temporary", .connecting, direction: "outgoing"))
        let a = try XCTUnwrap(registry.key(agentID: "A", callID: "temporary"))
        XCTAssertTrue(registry.activate(a))
        XCTAssertEqual(registry.apply(event("B", "telecom", .active,
            replaces: "temporary", direction: "outgoing")), [])
        XCTAssertEqual(registry.latestEvent(for: a)?.callID, "temporary")
        _ = registry.apply(event("A", "telecom", .active,
            replaces: "temporary", direction: "outgoing"))
        XCTAssertEqual(registry.key(agentID: "A", callID: "telecom"), a)
        XCTAssertEqual(registry.latestEvent(for: a)?.callID, "telecom")
    }

    func testAndroidLocalAnswerDoesNotAcquireRemoteMediaOwnership() {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("B", .active))
        XCTAssertNil(registry.active)
    }

    func testAuthoritativeAliasWhileStillDialingPublishesUpdate() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("A", "temporary", .connecting, direction: "outgoing"))
        let a = try XCTUnwrap(registry.key(agentID: "A", callID: "temporary"))
        XCTAssertTrue(registry.activate(a))
        XCTAssertEqual(registry.apply(event("A", "telecom", .connecting,
            replaces: "temporary", direction: "outgoing")), [.update(a)])
    }

    func testOldTransportEpochAndRingingCannotRegressActiveCall() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("A", .ringing, epoch: 5))
        let a = try XCTUnwrap(registry.ringing.first)
        XCTAssertTrue(registry.activate(a))
        _ = registry.apply(event("A", .active, epoch: 5))
        XCTAssertEqual(registry.apply(event("A", .ended, epoch: 4)), [])
        XCTAssertEqual(registry.apply(event("A", .ringing, .vowlan, epoch: 999)), [])
        XCTAssertEqual(registry.latestEvent(for: a)?.state, .active)
    }

    func testDeactivateReleasesOnlyOptimisticAnswer() throws {
        var registry = DeviceCallRegistry()
        _ = registry.apply(event("A", .ringing))
        let a = try XCTUnwrap(registry.ringing.first)
        XCTAssertTrue(registry.activate(a))
        registry.deactivate(a)
        XCTAssertNil(registry.active)
        XCTAssertEqual(registry.latestEvent(for: a)?.state, .ringing)
        XCTAssertTrue(registry.ringing.contains(a))
        XCTAssertTrue(registry.activate(a))
    }

    @MainActor
    func testLegacyIngressDoesNotEndAnotherSourceOnLateResult() throws {
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()))
        let uuid = UUID()
        _ = model.receiveDeviceCallEvent(event("A", .connecting, direction: "outgoing"),
            presentation: CallLifecycleEvent(callID: "shared", callUUID: uuid, generation: 1,
                state: .connecting, source: .agent, timestamp: Date(), traceID: nil, failure: nil))
        let a = try XCTUnwrap(model.deviceCalls.key(agentID: "A", callID: "shared"))
        XCTAssertTrue(model.activateDeviceCall(a))
        _ = model.receiveDeviceCallEvent(event("B", .ended),
            presentation: CallLifecycleEvent(callID: "shared", callUUID: UUID(), generation: 1,
                state: .ended, source: .agent, timestamp: Date(), traceID: nil, failure: nil))
        XCTAssertEqual(model.deviceCalls.active, a)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, uuid)
        XCTAssertEqual(model.callLifecycleSnapshot.state, .connecting)
    }
}
