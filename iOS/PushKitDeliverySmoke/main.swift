import Foundation

@main
struct PushKitDeliverySmoke {
    @MainActor static func main() throws {
        let current = UUID()
        let valid: [AnyHashable: Any] = ["event": "incoming_call", "call_id": "watch-call", "call_uuid": current.uuidString]
        var expired = valid; expired["expires_at"] = 1
        var badUUID = valid; badUUID["call_uuid"] = "bad"
        var missingID = valid; missingID.removeValue(forKey: "call_id")
        var badMedia = valid; badMedia["media_route"] = "vowlan"
        var badSecret = valid; badSecret["call_secret"] = "short"
        for payload in [[:], expired, badUUID, missingID, badMedia, badSecret, ["event": "sms"]] {
            for fails in [false, true] {
                var events = [String](), callback: ((Error?) -> Void)?, reported: UUID?
                let parsed = VoIPPushDelivery.receive(payload: payload,
                    parse: { try WatchVoIPCall(userInfo: $0) },
                    report: { _, _ in fatalError("Invalid push admitted to Watch media/UI") },
                    reportRejected: { uuid, done in reported = uuid; events.append("report"); callback = done },
                    endRejected: { uuid in precondition(uuid == reported && uuid != current); events.append("end") },
                    rejected: { _ in }, completion: { events.append("completion") })
                precondition(parsed == nil && events == ["report"])
                let error: Error? = fails ? NSError(domain: "CallKitFixture", code: 1) : nil
                callback?(error); callback?(nil)
                precondition(events == (fails ? ["report", "completion"] : ["report", "end", "completion"]))
            }
        }
        var events = [String](), finish: (() -> Void)?
        let incoming = VoIPPushDelivery.receive(payload: valid,
            parse: { try WatchVoIPCall(userInfo: $0) },
            report: { call, done in precondition(call.uuid == current); events.append("report"); finish = done },
            reportRejected: { _, _ in fatalError("Valid Watch push rejected") },
            endRejected: { _ in fatalError("Valid Watch call ended") },
            rejected: { _ in fatalError("Valid parse failed") }, completion: { events.append("completion") })
        precondition(incoming?.uuid == current && events == ["report"])
        finish?(); finish?()
        precondition(events == ["report", "completion"])
        var badVirtual = valid; badVirtual["virtual_call"] = true
        for payload in [[:], expired, badUUID, missingID, badVirtual, ["event": "sms"]] {
            for fails in [false, true] {
                var events = [String](), callback: ((Error?) -> Void)?
                let parsed = VoIPPushDelivery.receive(payload: payload,
                    parse: { try IncomingVoIPCall(userInfo: $0) },
                    report: { _, _ in fatalError("Invalid iPhone push admitted") },
                    reportRejected: { uuid, done in precondition(uuid != current); events.append("report"); callback = done },
                    endRejected: { uuid in precondition(uuid != current); events.append("end") },
                    rejected: { _ in }, completion: { events.append("completion") })
                precondition(parsed == nil && events == ["report"])
                callback?(fails ? NSError(domain: "CallKitFixture", code: 1) : nil); callback?(nil)
                precondition(events == (fails ? ["report", "completion"] : ["report", "end", "completion"]))
            }
        }
        let phone = VoIPPushDelivery.receive(payload: valid,
            parse: { try IncomingVoIPCall(userInfo: $0) },
            report: { call, done in precondition(call.uuid == current); done() },
            reportRejected: { _, _ in fatalError("Valid phone push rejected") },
            endRejected: { _ in fatalError("Valid phone call ended") },
            rejected: { _ in fatalError("Valid phone parse failed") }, completion: {})
        precondition(phone?.uuid == current)
        print("PushKit delivery passed: 26 phone/Watch rejection/error cases, synchronous admission, once-only completion, UUID isolation")
    }
}
