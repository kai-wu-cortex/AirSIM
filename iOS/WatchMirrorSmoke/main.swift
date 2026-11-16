import Foundation

// Test doubles for CallKit, AppModel and WatchConnectivity; never access a device.
enum EndReason { case answeredElsewhere }
@MainActor final class CallKitController {
    static let shared = CallKitController()
    var uuid: UUID?
    var id: String?
    var globalEnds = 0
    var withdrawals = 0
    func matchesCurrentCall(callID: String?, uuid: UUID?) -> Bool { self.uuid == uuid && id == callID }
    func reportCurrentCallEnded(reason: EndReason) { globalEnds += 1 }
    func withdrawLocalPresentation(uuid: UUID, reason: EndReason) { withdrawals += 1 }
}
struct CallReference { var callID: String; var uuid: UUID; var requestID: UUID? }
@MainActor final class FakeModel {
    let callKit = CallKitController()
    var deviceCallContext: FakeModel { self }
    func releaseAdmission(_ id: UUID) {}
    func resumeAfterWatchHandoffFailure(uuid: UUID) async {}
}
enum CloudModePreference { static func isEnabled() -> Bool { false } }
@MainActor final class Coordinator {
    var model: FakeModel? = FakeModel()
    var localWatchCall: CallReference?
    var watchOutgoingCall: (requestID: UUID, call: CallReference)?
    var abandonedAnswers = [UUID]()
    var lastPayload: WatchCallPayload?
    var lastCloudMediaAllowed: Bool?
    var sent = [WatchCallPayload]()
    func send(_ payload: WatchCallPayload) { sent.append(payload) }
    func endLocalWatchCall(_ message: [String: Any], replyHandler: ([String: Any]) -> Void) async { replyHandler([:]) }
    // PRODUCTION_METHODS
}

@main struct Checks {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        let coordinator = Coordinator(), a = UUID(), b = UUID()
        func payload(_ id: String, _ uuid: UUID, _ phase: WatchCallPhase) -> WatchCallPayload {
            .init(callID: id, callUUID: uuid, phase: phase, number: nil, callerName: nil, updatedAt: Date())
        }
        coordinator.publish(payload("A", a, .active))
        coordinator.publish(payload("B", b, .incoming))
        coordinator.publish(payload("A", a, .ended))
        check(coordinator.lastPayload?.callUUID == b, "Old A terminal must not replace B's reconnect snapshot")
        check(coordinator.lastPayload?.phase == .incoming, "B remains ringing")
        check(coordinator.sent.last?.callUUID == a && coordinator.sent.last?.phase == .ended, "A still receives its terminal")
        coordinator.publish(payload("B", b, .ended))
        check(coordinator.lastPayload?.phase == .ended, "B ends only with its matching terminal")
        let total = coordinator.sent.count
        coordinator.publish(payload("B", b, .ended))
        check(coordinator.sent.count == total, "Duplicate terminal does not queue again")
        let controller = coordinator.model!.callKit
        controller.uuid = a; controller.id = "A"
        func ownership(_ id: String, _ uuid: UUID) -> [String: Any] {
            ["event": "watch_call_owner", "phase": "active", "call_id": id, "call_uuid": uuid.uuidString]
        }
        _ = await coordinator.consumeWatchOwnership(ownership("A", a))
        check(controller.withdrawals == 1 && controller.globalEnds == 0, "Direct Watch answer cannot invoke iPhone global-ended callback")
        _ = await coordinator.consumeWatchOwnership(ownership("B", b))
        _ = await coordinator.consumeWatchOwnership(ownership("B", a))
        check(controller.withdrawals == 1 && controller.globalEnds == 0, "Other call/UUID cannot retire current presentation")
        coordinator.localWatchCall = .init(callID: "A", uuid: a)
        _ = await coordinator.consumeWatchOwnership(ownership("A", a))
        check(controller.globalEnds == 1, "Existing companion handoff retains its owned cleanup path")
        print("Watch mirror production checks passed: \(count) assertions (platform boundaries mocked)")
    }
}
