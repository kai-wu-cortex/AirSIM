import Foundation
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
func sms(_ source: String?, _ delivery: String = "delivery-1", sim: String? = nil) -> SMSMessage {
    SMSMessage(sender: "fixture", content: "same text", code: nil, timestamp: Date(timeIntervalSince1970: 100),
        deliveryID: delivery, direction: .incoming, sourceAgentID: source, simSlot: sim)
}
func withStore(_ body: (LocalHistoryStore, URL) -> Void) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    body(LocalHistoryStore(directoryURL: url), url)
}
for order in [[sms("A", sim: "SIM 2"), sms("A")], [sms("A"), sms("A", sim: "SIM 2")]] {
    withStore { store, path in
        for message in order { check(store.saveMessages([message]), "write") }
        let reopened = LocalHistoryStore(directoryURL: path)
        check(reopened.loadMessages().count == 1, "delivery deduplicates")
        check(reopened.loadMessages().first?.simSlot == "SIM 2", "SIM survives either delivery order and restart")
        check(reopened.loadMessages().first?.sourceAgentID == "A", "preserve authenticated source")
    }
}
withStore { store, _ in
    check(store.saveMessages([sms("A"), sms("B"), sms(nil), sms("A", "different-delivery")]), "write distinct sources")
    check(store.loadMessages().count == 4, "same body and delivery ID must not merge different producers")
    check(store.deleteMessages(ids: [sms("A").id], from: store.loadMessages()), "delete A")
    check(store.saveMessages([sms("A"), sms("B")]), "redelivery")
    check(store.loadMessages().count == 3, "tombstone stays scoped to A")
}
print("SMS identity checks passed: \(checks)")
