import Foundation
import XCTest
import UIKit
@testable import AirSIM

final class MinimalSMSAndHangupTests: XCTestCase {
    func testMissingOptionalAPIsAreNotRetriedOnEveryPoll() async throws {
        let transport = MissingOptionalAPIBoundary()
        let api = AirSIMAPI(route: .vowlan(endpoint: try VoWLANEndpoint(host: "10.0.0.19", controlPort: 15992, pcmPort: 15993),
            credential: try VoWLANCredential(secret: Data(repeating: 3, count: 32))), transport: transport)
        for _ in 0..<3 {
            try await api.acknowledgeCallHistory(ids: ["fixture"])
            do { _ = try await api.setCallRecording(true); XCTFail("unsupported recording succeeded") }
            catch APIError.unsupportedFeature { }
        }
        let paths = await transport.paths
        XCTAssertEqual(paths.filter { $0.hasSuffix("history/ack") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("audio/record") }.count, 1)
    }

    func testSMSLineSelectionIsPerConversationAndFallsBackWhenSIMRemoved() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let slots = try JSONDecoder().decode([AndroidSIMSlot].self, from: Data("""
        [{"id":"one","label":"SIM 1"},{"id":"two","label":"SIM 2","is_default_sms":true}]
        """.utf8))
        SMSSIMPreference.select("one", agentID: "A", recipient: "202-555-0100", defaults: defaults)
        XCTAssertEqual(SMSSIMPreference.selectedID(agentID: "A", slots: slots, recipient: "2025550100", defaults: defaults), "one")
        XCTAssertEqual(SMSSIMPreference.selectedID(agentID: "A", slots: slots, recipient: "2025550101", defaults: defaults), "two")
        XCTAssertEqual(SMSSIMPreference.selectedID(agentID: "A", slots: slots, recipient: "2025550101", suggestedID: "one", defaults: defaults), "one")
        XCTAssertEqual(SMSSIMPreference.selectedID(agentID: "A", slots: slots, recipient: "2025550100", suggestedID: "two", defaults: defaults), "one")
        XCTAssertEqual(SMSSIMPreference.selectedID(agentID: "B", slots: slots, recipient: "2025550100", defaults: defaults), "two")
        XCTAssertEqual(SMSSIMPreference.selectedID(agentID: "A", slots: [slots[1]], recipient: "2025550100", defaults: defaults), "two")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("2025550100"))
        SMSSIMPreference.forget(agentID: "A", defaults: defaults)
        XCTAssertEqual(SMSSIMPreference.selectedID(agentID: "A", slots: slots, recipient: "2025550100", defaults: defaults), "two")
    }

    func testSentSMSRetainsSelectedLineAndDeviceAfterPersistence() throws {
        let sent = try XCTUnwrap(SMSHistoryPolicy.appendingSentMessage(
            recipient: "10086", content: "synthetic", at: Date(), to: [], limit: 20,
            sourceAgentID: "android-A", simSlot: "SIM 2").first)
        let restored = try JSONDecoder().decode(SMSMessage.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(restored.simDeliveryLabel, "通过 SIM 2")
        XCTAssertEqual(restored.sourceAgentID, "android-A")
    }

    private func api(_ boundary: HangupHTTPBoundary) throws -> AirSIMAPI {
        AirSIMAPI(route: .vowlan(endpoint: try VoWLANEndpoint(host: "10.0.0.7", controlPort: 7592, pcmPort: 7593),
            credential: try VoWLANCredential(secret: Data(repeating: 7, count: 32))), transport: boundary)
    }

    func testLostHangupResponseIsConfirmedWithoutDuplicateCommand() async throws {
        let boundary = HangupHTTPBoundary(scenario: .ended)
        try await api(boundary).hangupCall(callID: "original")
        let sent = await boundary.targets
        XCTAssertEqual(sent, ["original"])
    }

    func testTransientHangupFailureRetriesOnlyCapturedIdentity() async throws {
        let boundary = HangupHTTPBoundary(scenario: .retry)
        try await api(boundary).hangupCall()
        let sent = await boundary.targets
        XCTAssertEqual(sent, ["original", "original"])
    }

    func testHangupNeverRetriesOnReplacementOrUncertainStatus() async throws {
        for scenario in [HangupHTTPBoundary.Scenario.replacement, .pollError, .unauthorized] {
            let boundary = HangupHTTPBoundary(scenario: scenario)
            do { try await api(boundary).hangupCall(callID: "original"); XCTFail("unconfirmed end was accepted") } catch {}
            let sent = await boundary.targets
            XCTAssertEqual(sent, ["original"])
        }
    }

    func testSMSPushRetainsReceivingSIMAndLegacyStaysUnknown() throws {
        for slot in ["SIM 1", "SIM 2"] {
            let incoming = try IncomingRemoteSMS(userInfo: ["event": "incoming_sms", "delivery_id": "fixture",
                "sender": "fixture", "content": "synthetic", "timestamp": "2026-11-03T09:00:00Z", "sim_slot": slot])
            XCTAssertEqual(incoming.message.simSlot, slot)
            XCTAssertEqual(incoming.message.simDeliveryLabel, "接收于 \(slot)")
            let data = try JSONEncoder().encode(incoming.message)
            XCTAssertEqual(try JSONDecoder().decode(SMSMessage.self, from: data).simSlot, slot)
        }
        let legacy = try IncomingRemoteSMS(userInfo: ["event": "incoming_sms", "delivery_id": "legacy",
            "sender": "fixture", "content": "synthetic", "timestamp": "2026-11-03T09:00:00Z"])
        XCTAssertNil(legacy.message.simSlot)
        XCTAssertEqual(legacy.message.simDeliveryLabel, "接收于 SIM 未知")
    }
}

private actor HangupHTTPBoundary: AirSIMHTTPTransport {
    enum Scenario { case ended, retry, replacement, pollError, unauthorized }
    let scenario: Scenario
    private(set) var targets: [String] = []
    init(scenario: Scenario) { self.scenario = scenario }
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        if request.url?.path == "/api/calls/hangup" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            targets.append(body?["call_id"] ?? "UNSCOPED")
            let code = scenario == .unauthorized ? 401 : (scenario == .retry && targets.count == 2 ? 200 : 502)
            return WiredHTTPResponse(statusCode: code, body: Data("{}".utf8))
        }
        let id: String? = targets.isEmpty || scenario != .ended ? (scenario == .replacement ? "replacement" : "original") : nil
        let call = id.map { CallRecord(id: $0, index: 1, direction: "incoming", state: "active", number: nil,
            startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false) }
        let status = CallStatus(active: call, history: [], polling: true, eventDriven: true, pollIntervalSeconds: 2,
            lastPollError: scenario == .pollError ? "stale" : "", revision: 1)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return WiredHTTPResponse(statusCode: 200, body: try encoder.encode(status))
    }
}

private actor MissingOptionalAPIBoundary: AirSIMHTTPTransport {
    private(set) var paths: [String] = []
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse {
        paths.append(request.url!.path)
        return WiredHTTPResponse(statusCode: 404, body: Data("{}".utf8))
    }
}

final class RecentCallGroupingUpgradeTests: XCTestCase {
    private func record(_ id: String, _ number: String?, _ time: Double) -> CallRecord {
        CallRecord(id: id, index: 0, direction: "incoming", state: "ended", number: number,
            startedAt: Date(timeIntervalSince1970: time), updatedAt: Date(timeIntervalSince1970: time + 30),
            endedAt: Date(timeIntervalSince1970: time + 30), missed: false)
    }
    func testGroupingPreservesEveryRecordAndSortsLatest() {
        let records = [record("a", "+86 138-0013-8000", 1), record("b", "13800138000", 3),
            record("c", "+1 3800138000", 2), record("d", nil, 4), record("e", nil, 5)]
        let groups = RecentCallGroup.grouped(records)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first?.latest.id, "e")
        XCTAssertEqual(groups.first { $0.id == "13800138000" }?.records.map(\.id), ["b", "a"])
        XCTAssertEqual(Set(groups.flatMap { $0.records.map(\.id) }), Set(records.map(\.id)))
    }
    func testCountryPrefixesAndServiceNumbersAreNeverSuffixMerged() {
        XCTAssertNotEqual(RecentCallGroup.normalizedNumber("+44 20 1234 5678"), RecentCallGroup.normalizedNumber("02012345678"))
        XCTAssertEqual(RecentCallGroup.normalizedNumber("+86 13800138000"), "13800138000")
        XCTAssertNotEqual(RecentCallGroup.normalizedNumber("12345678"), RecentCallGroup.normalizedNumber("87654321"))
        XCTAssertEqual(RecentCallGroup.normalizedNumber("10086#1"), "10086#1")
    }
    @MainActor func testGroupDeletionPersistsWithoutDeletingOtherNumbers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let calls = [record("a", "+86 13800138000", 1), record("b", "13800138000", 2), record("c", "10086", 3)]
        XCTAssertTrue(store.saveCallHistory(calls))
        let model = AppModel(historyStore: store)
        model.callHistory = calls
        let group = try XCTUnwrap(RecentCallGroup.grouped(calls).first { $0.records.count == 2 })
        model.deleteCallHistory(ids: group.recordIDs)
        XCTAssertEqual(model.callHistory.map(\.id), ["c"])
        XCTAssertEqual(LocalHistoryStore(directoryURL: directory).loadCallHistory().map(\.id), ["c"])
    }
    func testScopedHistoryPreservesReliableConnectionTime() {
        var call = record("a", "10086", 1)
        call.connectedAt = Date(timeIntervalSince1970: 11)
        XCTAssertEqual(call.scopedHistory(to: "fixture-agent").connectedDuration, 20)
    }
    func testMissedAndLegacyRecordsNeverInventDuration() {
        var call = record("a", "10086", 1)
        XCTAssertNil(call.connectedDuration)
        call.connectedAt = Date(timeIntervalSince1970: 11)
        XCTAssertEqual(call.connectedDuration, 20)
        let missed = CallRecord(id: "m", index: 0, direction: "incoming", state: "ended", number: nil,
            startedAt: call.startedAt, updatedAt: call.updatedAt, endedAt: call.endedAt, missed: true, connectedAt: call.connectedAt)
        XCTAssertNil(missed.connectedDuration)
    }
}


final class CallbackSIMDialChoiceTests: XCTestCase {
    private var slots: [AndroidSIMSlot] {
        try! JSONDecoder().decode([AndroidSIMSlot].self, from: Data("""
        [{"id":"voice-one","label":"SIM 1","slot_index":0},{"id":"voice-two","label":"SIM 2","slot_index":1}]
        """.utf8))
    }
    func testBothExplicitSlotsKeepOriginalCallbackNumber() {
        let request = CallbackSIMDialRequest(agentID: "A", number: "+8613800138000", slots: slots)
        for slot in slots { XCTAssertTrue(request.permits(agentID: "A", liveSlots: slots, slotID: slot.id, callInProgress: false)) }
        XCTAssertEqual(request.number, "+8613800138000")
    }
    func testRemovedSIMAndDeviceSwitchCannotDialAnotherCard() {
        let request = CallbackSIMDialRequest(agentID: "A", number: "10086", slots: slots)
        XCTAssertFalse(request.permits(agentID: "B", liveSlots: slots, slotID: "voice-two", callInProgress: false))
        XCTAssertFalse(request.permits(agentID: "A", liveSlots: [slots[0]], slotID: "voice-two", callInProgress: false))
        XCTAssertFalse(request.permits(agentID: "A", liveSlots: slots, slotID: "unknown", callInProgress: false))
    }
    func testIncomingCallBlocksPendingCallback() {
        let request = CallbackSIMDialRequest(agentID: "A", number: "10086", slots: slots)
        XCTAssertFalse(request.permits(agentID: "A", liveSlots: slots, slotID: "voice-one", callInProgress: true))
    }
}


final class SMSCodeHighlightTests: XCTestCase {
    func testMissingBackendCodeStillHighlightsContextualCode() {
        for text in ["您的验证码：123456，请勿泄露", "动态码为123456", "确认码 123456", "Your security code: 123456", "123456 是您的验证码", "Your OTP is 123456"] {
            XCTAssertEqual(SMSCodeHighlight.match(in: text)?.code, "123456", text)
        }
    }
    func testOrdersPhonesAndLongNumbersAreNotCodes() {
        for text in ["订单号 123456", "物流单号12345678", "致电13800138000", "验证码12345678901", "Your barcode is 123456", "验证码已发送至13800138000", "code for order 123456"] {
            XCTAssertNil(SMSCodeHighlight.match(in: text), text)
        }
        XCTAssertEqual(SMSCodeHighlight.match(in: "订单20261104，验证码123456")?.code, "123456")
    }
    @MainActor func testRenderedCodeHasHighlightAndCopyLinkWithoutChangingBody() throws {
        let original = "【测试】验证码：123456，请勿泄露"
        let result = try XCTUnwrap(SMSCodeHighlight.renderedBody(in: original, outgoing: false))
        let range = try XCTUnwrap(SMSCodeHighlight.match(in: original)?.range)
        XCTAssertEqual(result.text.string, original)
        XCTAssertNotNil(result.text.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        XCTAssertEqual((result.text.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.absoluteString, "airsim-code://copy/123456")
        XCTAssertNil(SMSCodeHighlight.renderedBody(in: "订单号123456", outgoing: false))
    }
    func testUnicodeRangePointsToOnlyTheCode() {
        let text = "📩【测试】验证码：654321。链接 https://example.com"
        let match = SMSCodeHighlight.match(in: text)
        XCTAssertEqual(match.map { (text as NSString).substring(with: $0.range) }, "654321")
    }
}


final class PhoneContentSearchTests: XCTestCase {
    func testSMSMatchesContactNumberAndOlderBody() {
        let messages = [SMSMessage(sender: "+8613800138000", content: "较早的快递取件码", code: nil, timestamp: Date(timeIntervalSince1970: 1)),
            SMSMessage(sender: "+8613800138000", content: "最新短信", code: nil, timestamp: Date(timeIntervalSince1970: 2))]
        for query in ["小王", "138 0013", "快递", ""] {
            XCTAssertTrue(PhoneContentSearch.smsMatches(sender: "+8613800138000", contactName: "小王", messages: messages, query: query))
        }
        XCTAssertFalse(PhoneContentSearch.smsMatches(sender: "+8613800138000", contactName: "小王", messages: messages, query: "不存在"))
    }
    func testNumberFormattingAndSearchDoNotMutateRecords() {
        XCTAssertTrue(PhoneContentSearch.numberMatches("13800138000", query: "+86 138-0013"))
        XCTAssertTrue(PhoneContentSearch.numberMatches("+86 138 0013 8000", query: "0013"))
        XCTAssertFalse(PhoneContentSearch.numberMatches("13800138000", query: "订单138"))
        XCTAssertFalse(PhoneContentSearch.numberMatches(nil, query: "138"))
        XCTAssertTrue(PhoneContentSearch.numberMatches(nil, query: "  "))
    }
}


final class PhoneRegionLookupTests: XCTestCase {
    func testBundledOfflineDataAndFormatting() {
        XCTAssertNotNil(PhoneRegionLookup.table, "Offline data must be shipped in the app")
        for number in ["13800138000", "+86 138-0013-8000", "008613800138000", "8613800138000"] {
            XCTAssertEqual(PhoneRegionLookup.region(for: number), "北京市", number)
        }
        XCTAssertEqual(PhoneRegionLookup.region(for: "01062503000"), "北京市")
        XCTAssertEqual(PhoneRegionLookup.region(for: "+86 21 68123456"), "上海市")
    }
    func testServicesInternationalAndMalformedNumbersRemainUnknown() {
        for number in ["10086", "110", "4001234567", "+864001234567", "+14155552671", "+85221234567", "138001380001234", "13800138000#", "private"] {
            XCTAssertNil(PhoneRegionLookup.region(for: number), number)
        }
        XCTAssertNil(PhoneRegionLookup.region(for: nil))
        XCTAssertNil(PhoneRegionLookup.Table(data: Data("bad".utf8)))
    }
    func testCStyleKeepsUnknownSIMUnknown() {
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "13800138000", slotIndex: 1), "SIM 2 · 北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "13800138000", slotIndex: nil), "北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "10086", slotIndex: 0), "SIM 1")
        XCTAssertNil(PhoneRegionLookup.infoLine(number: "10086", slotIndex: nil))
    }
}

final class PhoneRegion178RegressionTests: XCTestCase {
    func testMissingMobilePrefixAndServiceCategories() {
        XCTAssertEqual(PhoneRegionLookup.region(for: "17800159951"), "北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "17800159951", slotIndex: nil), "北京市")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "+86 95588", slotIndex: 0), "SIM 1 · 国内 95 服务号码")
        XCTAssertEqual(PhoneRegionLookup.serviceDescription(for: "008696110"), "国内 96 服务号码")
        for value in ["911", "999", "912345", "+9595588", "009695588", "955881234567", "95abc"] {
            XCTAssertNil(PhoneRegionLookup.serviceDescription(for: value), value)
        }
    }
}

final class History181Tests: XCTestCase {
    func testHistoryEvidenceSurvivesLegacyRefreshAndSIMScoping() {
        let date = Date(timeIntervalSince1970: 100)
        var observed = CallRecord(id: "a", index: 0, direction: "incoming", state: "ended", number: "10086", startedAt: date, updatedAt: date, endedAt: date, missed: true)
        observed.slotIndex = 1
        let scoped = observed.scopedHistory(to: "device")
        XCTAssertEqual(scoped.slotIndex, 1)
        var legacy = observed; legacy.missed = false; legacy.slotIndex = nil
        let merged = legacy.preservingHistoryEvidence(from: observed)
        XCTAssertTrue(merged.missed); XCTAssertEqual(merged.slotIndex, 1)
        legacy.connectedAt = date
        XCTAssertFalse(legacy.preservingHistoryEvidence(from: observed).missed)
        let store = LocalHistoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertTrue(store.saveCallHistory([merged]))
        XCTAssertEqual(store.unseenMissedCallIDs(in: [merged]), [merged.id])
        XCTAssertTrue(store.markMissedCallsSeen([merged]))
        XCTAssertTrue(store.unseenMissedCallIDs(in: [merged]).isEmpty)
        XCTAssertTrue(store.loadCallHistory().first!.missed)
    }
}

final class IncomingSIM183Tests: XCTestCase {
    func testLateSIMMetadataUpdatesSameSessionWithoutSecondRing() throws {
        var registry = DeviceCallRegistry()
        var event = DeviceCallEvent(agentID: "A", callID: "call", state: .ringing, transport: .vowlan, transportEpoch: 1)
        _ = registry.apply(event)
        let key = try XCTUnwrap(registry.key(agentID: "A", callID: "call"))
        event.slotIndex = 1
        XCTAssertEqual(registry.apply(event), [.update(key)])
        XCTAssertEqual(registry.latestEvent(for: key)?.slotIndex, 1)
        XCTAssertEqual(registry.ringing, [key])
        XCTAssertTrue(registry.apply(event).isEmpty)
        event.slotIndex = -1
        XCTAssertTrue(registry.apply(event).isEmpty)
        XCTAssertEqual(registry.latestEvent(for: key)?.slotIndex, 1)
    }
}

final class PresentationSIM184Tests: XCTestCase {
    func testFinalPresentationPreservesBothSIMsAndDevice() throws {
        for slot in [0, 1] {
            var store = CallLifecycleStore()
            let date = Date(), uuid = UUID()
            _ = store.apply(.init(callID: "call", callUUID: uuid, generation: 1, state: .ringing, source: .agent, timestamp: date, traceID: nil, failure: nil))
            var record = CallRecord(id: "call", index: 0, direction: "incoming", state: "incoming", number: nil, startedAt: date, updatedAt: date, endedAt: nil, missed: false)
            record.slotIndex = slot; record.slotID = slot; record.sourceAgentID = "actual-device"
            let rendered = try XCTUnwrap(store.presentationRecord(from: record))
            XCTAssertEqual(rendered.slotIndex, slot)
            XCTAssertEqual(rendered.slotID, slot)
            XCTAssertEqual(rendered.sourceAgentID, "actual-device")
        }
    }
}
