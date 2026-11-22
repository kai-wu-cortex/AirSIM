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

for order in [[sms(nil), sms("A", sim: "SIM 2")], [sms("A", sim: "SIM 2"), sms(nil)]] {
    withStore { store, path in
        let first = store.ingestMessages([order[0]], legacySourceAgentID: "A")!
        check(first.newMessages.count == 1, "first delivery notifies once")
        let second = LocalHistoryStore(directoryURL: path).ingestMessages([order[1]], legacySourceAgentID: "A")!
        check(second.messages.count == 1, "legacy alias merges either arrival order")
        check(second.messages[0].sourceAgentID == "A", "alias upgrades rather than erases producer")
        check(second.messages[0].simSlot == "SIM 2", "metadata enrichment")
        check(second.newMessages.isEmpty, "migration does not notify twice")
        check(WatchSMSPolicy.permits(sourceAgentID: second.messages[0].sourceAgentID,
                                    selectedAgentID: "A", pairedIDs: ["A"]), "Watch remains visible and device scoped")
        check(store.unreadMessageIDs(in: second.messages).count == 1, "no duplicate unread badge")
        let again = store.ingestMessages(order, legacySourceAgentID: "A")!
        check(again.messages.count == 1 && again.newMessages.isEmpty, "repeated deliveries stay idempotent")
    }
}
withStore { store, path in
    _ = store.saveMessages([sms(nil)])
    check(store.markMessagesRead([sms(nil)]), "read legacy")
    let migrated = store.ingestMessages([sms("A")], legacySourceAgentID: "A")!
    let reopened = LocalHistoryStore(directoryURL: path)
    check(reopened.unreadMessageIDs(in: migrated.messages).isEmpty, "read state persists through scoped migration and restart")
    check(reopened.deleteMessages(ids: [sms("A").id], from: migrated.messages), "delete migrated SMS")
    let redelivery = reopened.ingestMessages([sms("A"), sms(nil)], legacySourceAgentID: "A")!
    check(redelivery.messages.isEmpty, "canonical deletion also suppresses alias in same transaction")
    check(reopened.ingestMessages([sms(nil)], legacySourceAgentID: "A")!.messages.isEmpty,
          "late legacy-only push does not resurrect a deleted canonical record")
    check(redelivery.acceptedMessageIDs.contains(sms("A").id), "deleted wire delivery may ACK after tombstone is durable")
}
withStore { store, path in
    _ = store.saveMessages([sms(nil)])
    check(store.deleteMessages(ids: [sms(nil).id], from: store.loadMessages()), "delete old legacy SMS")
    let outcome = LocalHistoryStore(directoryURL: path).ingestMessages([sms("A")], legacySourceAgentID: "A")!
    check(outcome.messages.isEmpty && outcome.newMessages.isEmpty, "deleted legacy is not resurrected by scoped sync")
    check(outcome.acceptedMessageIDs == [sms("A").id], "ACK exact scoped wire result")
    check(store.ingestMessages([sms("B")])!.messages.count == 1, "deletion never spreads to another device")
}
withStore { store, _ in
    _ = store.ingestMessages([sms("A"), sms("B")])
    check(store.ingestMessages([sms(nil)], legacySourceAgentID: "A")!.messages.count == 3,
          "historical second producer prevents legacy inference")
}
withStore { store, _ in
    _ = store.saveMessages([sms(nil)])
    check(store.ingestMessages([sms("A")])!.messages.count == 2, "no uniqueness proof means isolation")
}
withStore { store, _ in
    let noID = SMSMessage(sender: "fixture", content: "same text", code: nil, timestamp: Date(timeIntervalSince1970: 100))
    _ = store.ingestMessages([noID])
    check(store.ingestMessages([sms("A")], legacySourceAgentID: "A")!.messages.count == 2,
          "never infer cross-source identity by body or time")
}
let suite = "AirSIM.sms-batch2.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
PairedAndroidDeviceStore.remember(.init(id: "A", deviceName: "A", agentKind: nil), defaults: defaults)
let before = PairedAndroidDeviceStore.smsIdentitySnapshot(defaults: defaults)
check(before.uniqueAgentID == "A", "one producer")
PairedAndroidDeviceStore.remember(.init(id: "B", deviceName: "B", agentKind: nil), defaults: defaults)
let after = PairedAndroidDeviceStore.smsIdentitySnapshot(defaults: defaults)
check(before.legacySource(comparedTo: after) == nil, "in-flight addition invalidates legacy proof")
withStore { store, _ in
    _ = store.saveMessages([sms(nil)]) // old push from B while A fetch is suspended
    let outcome = store.ingestMessages([sms("A")], legacySourceAgentID: before.legacySource(comparedTo: after))!
    check(outcome.messages.count == 2, "pairing race keeps both deliveries")
}
PairedAndroidDeviceStore.forget("B", defaults: defaults)
check(PairedAndroidDeviceStore.smsIdentitySnapshot(defaults: defaults).uniqueAgentID == nil, "forgotten producer prevents guesses")
PairedAndroidDeviceStore.allowPairing("B", defaults: defaults)
let returned = PairedAndroidDeviceStore.smsIdentitySnapshot(defaults: defaults)
check(returned.knownAgentIDs == before.knownAgentIDs, "directory returned to same IDs")
check(before.legacySource(comparedTo: returned) == nil, "ABA directory change remains detected")
PairedAndroidDeviceStore.allowPairing("A", defaults: defaults)
check(returned.legacySource(comparedTo: PairedAndroidDeviceStore.smsIdentitySnapshot(defaults: defaults)) == nil,
      "same-agent re-pair invalidates in-flight proof")
withStore { _, path in
    let group = DispatchGroup()
    for message in [sms(nil), sms("A", sim: "SIM 2")] {
        group.enter()
        DispatchQueue.global().async {
            _ = LocalHistoryStore(directoryURL: path).ingestMessages([message], legacySourceAgentID: "A")
            group.leave()
        }
    }
    group.wait()
    let reopened = LocalHistoryStore(directoryURL: path)
    check(reopened.loadMessages().count == 1 && reopened.loadMessages()[0].sourceAgentID == "A",
          "concurrent push and pull use one storage transaction")
}
withStore { store, path in
    try! Data("corrupt".utf8).write(to: path.appendingPathComponent("messages.json"))
    check(store.ingestMessages([sms("A")], legacySourceAgentID: "A") == nil, "failed persistence cannot authorize ACK")
}

withStore { store, _ in
    _ = store.saveMessages([sms(nil)])
    _ = store.ingestMessages([sms("A")], legacySourceAgentID: "A")
    check(store.markMessagesRead([sms(nil)]), "read from a stale UI row")
    check(store.unreadMessageIDs(in: store.loadMessages()).isEmpty, "stale UI read follows proven migration")
    check(store.deleteMessages(ids: [sms(nil).id], from: [sms(nil)]), "delete from stale UI row")
    check(store.loadMessages().isEmpty, "stale UI deletion removes canonical row")
}
withStore { store, _ in
    _ = store.ingestMessages([sms(nil), sms("A")], legacySourceAgentID: "A")
    _ = store.ingestMessages([sms(nil)]) // ambiguous new legacy push, no uniqueness proof
    check(store.deleteMessages(ids: [sms(nil).id], from: [sms(nil)]), "delete ambiguous row")
    check(store.loadMessages().map(\.sourceAgentID) == ["A"], "visible unknown row never deletes another scoped producer")
    check(store.deleteMessages(ids: [sms(nil).id], from: [sms(nil)]), "repeat stale ambiguous deletion")
    check(store.loadMessages().map(\.sourceAgentID) == ["A"], "repeated unknown deletion still cannot delete A")
}


withStore { store, path in
    _ = store.ingestMessages([sms("A")], legacySourceAgentID: "A")
    _ = store.ingestMessages([sms(nil)]) // another producer may have sent this
    let afterShrink = LocalHistoryStore(directoryURL: path).ingestMessages([sms("A")], legacySourceAgentID: "A")!
    check(afterShrink.messages.count == 2, "ambiguous legacy remains separate after directory shrinks and app restarts")
}
print("SMS identity checks passed: \(checks)")
