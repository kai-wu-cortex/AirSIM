import Foundation
import XCTest
import UIKit
import AVFoundation
@testable import AirSIM

final class MinimalSMSAndHangupTests: XCTestCase {
    @MainActor
    func testEarlyMediaEngineRestartsAfterOutputChangeAndStaysStoppedAfterHangup() async throws {
        let engine = AVAudioEngine()
        let audio = AudioSessionController(toneOutput: FixtureToneOutput(), makeEngine: { engine })
        defer { audio.deactivate() }
        let owner = UUID()
        let credential = try VoWLANCredential(secret: Data(repeating: 7, count: 32))
        let endpoint = try VoWLANEndpoint(host: "10.0.0.7", controlPort: 17592, pcmPort: 17593)
        let grant = EarlyMediaGrant(version: 1, agentID: "fixture", callID: "call",
            sessionID: "session", expiresAt: Int64(Date().timeIntervalSince1970) + 25,
            state: "early_media", direction: "recvonly", format: "s16le-8000-mono", proof: "fixture")
        let started = await audio.activateForCall(route: .vowlan(endpoint: endpoint, credential: credential),
            owner: owner, earlyMedia: grant)
        XCTAssertTrue(started, audio.errorMessage ?? "Early playback did not start")
        for _ in 0..<2 {
            engine.stop()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
            for _ in 0..<40 {
                if engine.isRunning { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(engine.isRunning, "Speaker and receiver transitions must restart playback")
            XCTAssertEqual(audio.sessionOwner, owner)
            XCTAssertTrue(audio.receiveOnly)
        }
        audio.deactivate()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(audio.sessionOwner)
    }

    @MainActor
    func testRejectedOutputRouteDoesNotSilenceOutgoingWaitingTone() throws {
        let tone = FixtureToneOutput()
        let audio = AudioSessionController(toneOutput: tone, overrideSpeakerRoute: { _ in
            throw NSError(domain: NSOSStatusErrorDomain, code: -50)
        })
        defer { audio.deactivate() }
        audio.updateCallTone(for: CallRecord(id: "route-not-ready", index: 0, direction: "outgoing",
            state: "dialing", number: nil, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false))
        XCTAssertTrue(tone.isPlaying, "A transient route failure must not stop waiting audio")
        XCTAssertTrue(audio.hasCallTone)
        XCTAssertNil(audio.errorMessage)
    }

    @MainActor
    func testOutgoingWaitingAudioSupportsReceiverRoutingBeforeConnection() throws {
        let tone = FixtureToneOutput()
        let audio = AudioSessionController(toneOutput: tone)
        defer { audio.deactivate() }
        audio.updateCallTone(for: CallRecord(id: "outgoing", index: 0, direction: "outgoing",
            state: "dialing", number: nil, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false))
        XCTAssertTrue(tone.isPlaying)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord,
            "Playback-only audio cannot switch back to the built-in receiver")
        XCTAssertFalse(audio.active, "Waiting audio must not open a two-way PCM session")
    }

    @MainActor
    func testUnreachablePhoneDoesNotKeepLocalCallPresentedAfterHangup() async throws {
        let controller = CallKitController()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
                             callKitController: controller)
        defer { model.stop() }
        let uuid = UUID()
        model.callKitDidReceiveIncoming(.init(bluetoothCallID: "offline-call", uuid: uuid,
            generation: 1, number: nil, agentID: "offline-phone"))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ringing)
        do {
            try await model.callKitEnd()
            XCTFail("No backend exists to confirm the remote hangup")
        } catch CallKitBridgeError.noReachableTransport { }
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertNil(model.activeCall)
        XCTAssertNil(model.remoteCall)
        XCTAssertFalse(model.callAudioIsActive)
        // A delayed snapshot for this call must not revive its presentation.
        model.callKitDidReceiveIncoming(.init(bluetoothCallID: "offline-call", uuid: uuid,
            generation: 1, number: nil, agentID: "offline-phone"))
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
    }

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
    func testKnownSIMIsNeverReplacedByUnknownFallback() {
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: nil, slotIndex: 1, fallbackSIM: "SIM 未记录"), "SIM 2")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "1234", slotIndex: 0, fallbackSIM: "SIM 未记录"), "SIM 1")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: nil, slotIndex: nil, fallbackSIM: "SIM 未记录"), "SIM 未记录")
    }

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
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "10086", slotIndex: 0), "SIM 1 · 中国移动客服")
        XCTAssertEqual(PhoneRegionLookup.infoLine(number: "10086", slotIndex: nil), "中国移动客服")
    }

    func testAndroidRegionSurvivesRecordCopiesAndHistoryMerge() throws {
        let date = Date()
        var old = CallRecord(id: "region-call", index: 0, direction: "incoming", state: "incoming", number: "13800138000", startedAt: date, updatedAt: date, endedAt: nil, missed: false)
        old.numberRegion = "浙江 杭州"
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(CallRecord.self, from: data)
        XCTAssertEqual(decoded.numberRegion, "浙江 杭州")
        var refreshed = old
        refreshed.numberRegion = nil
        XCTAssertEqual(refreshed.preservingHistoryEvidence(from: old).numberRegion, "浙江 杭州")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("number_region"))
    }

    func testAndroidRegionWinsAndMalformedValuesFallback() {
        XCTAssertEqual(PhoneRegionLookup.resolvedRegion(number: "13800138000", androidRegion: "浙江 杭州"), "浙江 杭州")
        XCTAssertEqual(PhoneRegionLookup.resolvedRegion(number: "13800138000", androidRegion: "  "), "北京市")
        XCTAssertEqual(PhoneRegionLookup.resolvedRegion(number: "13800138000", androidRegion: "bad\nlabel"), "北京市")
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "13800138000", callerName: "张三", slotIndex: 1, numberRegion: "浙江 杭州"), "张三 · SIM 2 · 浙江 杭州")
    }

    func testSystemIncomingSIMKeepsContactAndRegion() throws {
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "13800138000", callerName: "张三", slotIndex: 1), "张三 · SIM 2 · 北京市")
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "10086", callerName: nil, slotIndex: 0), "10086 · SIM 1 · 中国移动客服")
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "10000", callerName: "我的客服", slotIndex: 1), "我的客服 · SIM 2 · 中国电信客服")
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "13800138000", callerName: nil, slotIndex: -1), "13800138000 · 北京市")
        let push = try IncomingVoIPCall(userInfo: ["event": "incoming_call", "call_id": "sim-fixture",
            "call_uuid": UUID().uuidString, "slot_index": 1])
        XCTAssertEqual(push.slotIndex, 1)
        XCTAssertEqual(IncomingVoIPCall.simSlot(from: 1), 1)
        XCTAssertEqual(IncomingVoIPCall.simSlot(from: "0"), 0)
        XCTAssertNil(IncomingVoIPCall.simSlot(from: -1))
        XCTAssertNil(IncomingVoIPCall.simSlot(from: true))
        XCTAssertNil(IncomingVoIPCall.simSlot(from: 1.5))
    }

    func testSystemIncomingTitleUsesOfflineRegionAndKnownServiceNumbers() {
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "13800138000", callerName: "测试联系人"), "测试联系人 · 北京市")
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "13800138000", callerName: "+8613800138000"), "13800138000 · 北京市")
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "10086", callerName: nil), "中国移动客服 · 10086")
        XCTAssertEqual(PhoneRegionLookup.systemIncomingTitle(number: "10010", callerName: "+8610010"), "中国联通客服 · 10010")
        XCTAssertNil(PhoneRegionLookup.systemIncomingTitle(number: "10000", callerName: "我的客服"))
        XCTAssertNil(PhoneRegionLookup.systemIncomingTitle(number: "95588", callerName: nil))
        XCTAssertNil(PhoneRegionLookup.systemIncomingTitle(number: nil, callerName: nil))
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

/// 运营商原始等待音（方案 A，184 底子）单测。
/// 只覆盖纯逻辑：开关默认值/显式值、VoWLAN 可听判定。
/// 184 只有 VoWLAN 具备接通前 early media；云端与蓝牙接通后才开始媒体，
/// 接通前恒不可听，各自接通后的音频判定不受本开关影响。
final class CarrierRingbackPreferenceTests: XCTestCase {
    private let suiteName = "com.example.airsim.tests.carrier-ringback"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultIsEnabledWhenKeyAbsent() {
        XCTAssertNil(defaults.object(forKey: CarrierRingbackPreference.key))
        XCTAssertTrue(CarrierRingbackPreference.isEnabled(defaults: defaults))
    }

    func testExplicitValuesAreRespected() {
        CarrierRingbackPreference.setEnabled(false, defaults: defaults)
        XCTAssertFalse(CarrierRingbackPreference.isEnabled(defaults: defaults))
        CarrierRingbackPreference.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CarrierRingbackPreference.isEnabled(defaults: defaults))
    }

    func testVoWLANAudibleOnlyAfterFirstPCMFrame() {
        // grant 到达、会话已是 receiveOnly，但首帧 PCM 未到：不算听到。
        XCTAssertFalse(CarrierEarlyMediaAudibility.isAudible(
            transport: .vowlan, receiveOnly: true, hasReceivedEarlyMedia: false, enabled: true))
        // 首帧 PCM 到达：算听到。
        XCTAssertTrue(CarrierEarlyMediaAudibility.isAudible(
            transport: .vowlan, receiveOnly: true, hasReceivedEarlyMedia: true, enabled: true))
        // 非 receiveOnly 会话（接通后双向音频）不算接通前运营商语音。
        XCTAssertFalse(CarrierEarlyMediaAudibility.isAudible(
            transport: .vowlan, receiveOnly: false, hasReceivedEarlyMedia: true, enabled: true))
    }

    func testDisabledSwitchMakesAllTransportsInaudible() {
        for transport: CallTransport in [.vowlan, .bluetooth, .cloud] {
            XCTAssertFalse(CarrierEarlyMediaAudibility.isAudible(
                transport: transport, receiveOnly: true, hasReceivedEarlyMedia: true, enabled: false))
        }
        XCTAssertFalse(CarrierEarlyMediaAudibility.isAudible(
            transport: nil, receiveOnly: true, hasReceivedEarlyMedia: true, enabled: false))
    }

    func testBluetoothAndCloudHaveNoPreAnswerCarrierAudio() {
        // 184 的蓝牙与云端在接通后才开始媒体，接通前没有运营商语音；
        // 各自接通后的音频判定（bluetoothPCMConnected / cloudCallAudioState）
        // 不受本开关影响，这里只断言接通前可听恒为 false。
        for transport: CallTransport in [.bluetooth, .cloud] {
            XCTAssertFalse(CarrierEarlyMediaAudibility.isAudible(
                transport: transport, receiveOnly: true, hasReceivedEarlyMedia: true, enabled: true))
            XCTAssertFalse(CarrierEarlyMediaAudibility.isAudible(
                transport: transport, receiveOnly: false, hasReceivedEarlyMedia: false, enabled: true))
        }
    }
}

final class VoWLANOnly184ContractTests: XCTestCase {
    func testPersonalBuildPinsLegacyModesWithoutDisablingPush() {
        XCTAssertTrue(DedicatedCallPolicy.vowlanOnly, "Run with AIRSIM_VOWLAN_CALLS_ONLY=YES")
        let name = "airsim.tests.vowlan-only." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for mode in AirSIMConnectionMode.allCases {
            defaults.set(mode.rawValue, forKey: ConnectionModePreference.key)
            defaults.set(true, forKey: CloudModePreference.key)
            XCTAssertEqual(ConnectionModePreference.selected(defaults: defaults), .vowlan)
            XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
            XCTAssertTrue(CloudSignalingPreference.isEnabled(defaults: defaults))
            let policy = ConnectionModeRuntimePolicy(mode: mode)
            XCTAssertTrue(policy.startsVoWLAN)
            XCTAssertFalse(policy.startsCloud)
            XCTAssertFalse(policy.startsBluetooth)
            XCTAssertTrue(policy.usesCallKit)
            XCTAssertFalse(policy.allowsCrossModeFallback)
            XCTAssertEqual(DialRouteSelector.preferred(mode: mode, vowlanReady: true,
                bluetoothReady: true, cloudReady: true), .vowlan)
            XCTAssertNil(DialRouteSelector.preferred(mode: mode, vowlanReady: false,
                bluetoothReady: true, cloudReady: true))
            XCTAssertNil(CallTransportPolicy.preferred(mode: mode, vowlanReady: false,
                cloudMediaAvailable: true, cloudMediaEnabled: true))
            XCTAssertEqual(WidgetConnectionModeCycle.next(after: mode, pureLocal: false), .vowlan)
        }
        XCTAssertEqual(DedicatedCallPolicy.selectableModes, [.vowlan])
        CloudSignalingPreference.set(false, defaults: defaults)
        XCTAssertFalse(CloudSignalingPreference.isEnabled(defaults: defaults))
    }

    @MainActor func testCloudAudioEntryPointsRejectBeforeMediaStarts() async {
        let session = IPhoneCloudCallSession.shared
        XCTAssertThrowsError(try session.prepareAudioForCallKit())
        XCTAssertThrowsError(try session.startAudio())
        let call = IncomingVoIPCall(bluetoothCallID: "fixture", uuid: UUID(), generation: 1, number: nil)
        do {
            try await session.answer(call)
            XCTFail("Cloud answer must be refused before preparing audio or sending commands")
        } catch { XCTAssertTrue(error is IPhoneCloudCallError) }
        do {
            try await session.reject(call)
            XCTFail("Relay cannot send call rejection commands in the push-only build")
        } catch { XCTAssertTrue(error is IPhoneCloudCallError) }
        XCTAssertNil(VoIPPushController.shared.cloudCallControlCredentials())
        XCTAssertFalse(session.isPrepared)
    }

    func testBothSIMsDurationRegionAndMissedReadStateSurvivePersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalHistoryStore(directoryURL: directory)
        let start = Date(timeIntervalSince1970: 100)
        var records: [CallRecord] = []
        for slot in [0, 1] {
            var answered = CallRecord(id: "answered-\(slot)", index: 0, direction: "incoming",
                state: "ended", number: "13800138000", startedAt: start,
                updatedAt: start.addingTimeInterval(80), endedAt: start.addingTimeInterval(80),
                missed: false, connectedAt: start.addingTimeInterval(20))
            answered.slotIndex = slot
            records.append(answered.scopedHistory(to: "fixture-device"))
            var missed = CallRecord(id: "missed-\(slot)", index: 0, direction: "incoming",
                state: "ended", number: answered.number, startedAt: start,
                updatedAt: start.addingTimeInterval(80), endedAt: start.addingTimeInterval(80),
                missed: true)
            missed.slotIndex = slot
            records.append(missed.scopedHistory(to: "fixture-device"))
        }
        XCTAssertTrue(store.saveCallHistory(records))
        let loaded = store.loadCallHistory()
        XCTAssertEqual(loaded.count, 4)
        for call in loaded {
            XCTAssertNotNil(call.slotIndex)
            XCTAssertTrue(PhoneRegionLookup.infoLine(number: call.number, slotIndex: call.slotIndex)!
                .contains("SIM \(call.slotIndex! + 1)"))
            if call.missed { XCTAssertNil(call.connectedDuration) }
            else { XCTAssertEqual(call.connectedDuration, 60) }
        }
        XCTAssertEqual(loaded.filter(\.missed).count, 2)
        XCTAssertTrue(store.markMissedCallsSeen(loaded))
        XCTAssertTrue(store.unseenMissedCallIDs(in: loaded).isEmpty)
        XCTAssertEqual(store.loadCallHistory().filter(\.missed).count, 2)
    }
}


final class SMSCarrierBrandTests: XCTestCase {
    func testCarrierAssetsAreBundled() {
        for brand in SMSCarrierBrand.allCases { XCTAssertNotNil(UIImage(named: brand.rawValue), brand.rawValue) }
    }

    func testMinshengAndCMBOfficialSMSPorts() {
        XCTAssertEqual(SMSCarrierBrand.match("95555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1065795555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106941995555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106807695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("10694395555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106913595555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106903695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106918195555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069170795555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069329095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069411095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068338795555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068078595555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068775395555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068486095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068039095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106946895555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069208795555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069220695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106934095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106934795555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069210395555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069232695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069101695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106904095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106903395555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106929395555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068116095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106575595555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069118895555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068015195555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106910095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1068455695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106935295555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069109695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069057295555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069449695555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069249395555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069352995555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106930095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106920095555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069100995555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("1069001995555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("106900795555"), .cmb)
        XCTAssertEqual(SMSCarrierBrand.match("95568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("106980095568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("10680195568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("10685095568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("106857695568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("106835195568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("1068071895568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("1069120695568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("106935595568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("1069161795568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("10691895568"), .minsheng)
        XCTAssertEqual(SMSCarrierBrand.match("106901195568"), .minsheng)
        for sender in ["955550", "955680", "10612395555", "10612395568", "+1 95568"] {
            XCTAssertNil(SMSCarrierBrand.match(sender), sender)
        }
    }

    func testBankAndCourierNumbersAreExact() {
        XCTAssertEqual(SMSCarrierBrand.match("95588"), .icbc)
        XCTAssertEqual(SMSCarrierBrand.match("95533"), .ccb)
        XCTAssertEqual(SMSCarrierBrand.match("95599"), .abc)
        XCTAssertEqual(SMSCarrierBrand.match("95566"), .boc)
        XCTAssertEqual(SMSCarrierBrand.match("95559"), .bocom)
        XCTAssertEqual(SMSCarrierBrand.match("95338"), .sf)
        XCTAssertEqual(SMSCarrierBrand.match("950616"), .jd)
        XCTAssertEqual(SMSCarrierBrand.match("95311"), .zto)
        XCTAssertEqual(SMSCarrierBrand.match("95554"), .yto)
        XCTAssertEqual(SMSCarrierBrand.match("10690955998"), .abc)
        XCTAssertEqual(SMSCarrierBrand.match("106980095533"), .ccb)
        for sender in ["955880", "10612395588", "953380001", "快递95338", "+1 95533", "13800138000"] {
            XCTAssertNil(SMSCarrierBrand.match(sender), sender)
        }
    }

    func testExactCarrierNumbersAndCountryPrefixes() {
        XCTAssertEqual(SMSCarrierBrand.match("10086"), .mobile)
        XCTAssertEqual(SMSCarrierBrand.match("+86 10010"), .unicom)
        XCTAssertEqual(SMSCarrierBrand.match("0086 10000"), .telecom)
        for sender in ["1008611", "10610086", "+1 10086", "移动10086", "13800138000", "", "10086+", "8610086"] {
            XCTAssertNil(SMSCarrierBrand.match(sender), sender)
        }
    }
}


final class DeliveryTimelineTests: XCTestCase {
    func testMissingStagesStayUnknownAndClockSkewIsNotLatency() {
        var snapshot = AirSIMHealthStore.Snapshot()
        snapshot.lastCallDelivery = ["iphone_received": Date(timeIntervalSince1970: 100), "android_received_at": Date(timeIntervalSince1970: 102)]
        let report = AirSIMHealthStore.deliveryReport(snapshot: snapshot)
        XCTAssertTrue(report.contains("安卓上传：暂无时间记录"))
        XCTAssertTrue(report.contains("设备时钟存在偏差"))
        XCTAssertFalse(report.contains("-2.00 秒"))
    }
}
