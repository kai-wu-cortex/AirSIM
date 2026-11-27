import CryptoKit
import Network
import XCTest
@testable import AirSIM

final class SMSNotificationReadTests: XCTestCase {
    private func withHistory(_ body: (LocalHistoryStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(LocalHistoryStore(directoryURL: directory), directory)
    }

    private func localMessage(agent: String = "android-A", delivery: String = "one") -> SMSMessage {
        SMSMessage(sender: "10086", content: "通知测试", code: nil,
                   timestamp: Date(timeIntervalSince1970: 1_793_692_800),
                   deliveryID: delivery, direction: .incoming, sourceAgentID: agent)
    }

    func testLocalNotificationOpensExactStoredMessageAndPersistsReadAcrossRestart() throws {
        try withHistory { store, directory in
            let opened = localMessage()
            let otherDevice = localMessage(agent: "android-B")
            let newer = localMessage(delivery: "two")
            XCTAssertTrue(store.saveMessages([opened, otherDevice, newer]))
            let info = IncomingSMSNotificationTarget.localUserInfo(for: opened)
            XCTAssertNil(info["content"], "Metadata references history rather than duplicating SMS bodies")
            let target = try XCTUnwrap(IncomingSMSNotificationTarget.resolve(
                userInfo: info, requestIdentifier: "local", isRemote: false,
                storedMessages: store.loadMessages(), keyStore: E2ESMSFixture.store()))
            XCTAssertEqual(target.message.id, opened.id)
            XCTAssertNil(target.remoteSMS, "Local notifications must not downgrade E2E push validation")
            XCTAssertTrue(target.recordOpened(in: store, legacySourceAgentID: nil))
            let reopened = LocalHistoryStore(directoryURL: directory)
            XCTAssertEqual(reopened.unreadMessageIDs(in: reopened.loadMessages()), [otherDevice.id, newer.id])
        }
    }

    func testPreviouslyDeliveredLocalNotificationWithoutMetadataResolvesByScopedIdentifier() throws {
        let a = localMessage()
        let b = localMessage(agent: "android-B")
        let identifier = SMSNotificationCoordinator.localIdentifier(agentID: a.sourceAgentID, deliveryID: a.deliveryID)
        let target = IncomingSMSNotificationTarget.resolve(userInfo: [:], requestIdentifier: identifier,
            isRemote: false, storedMessages: [a, b], keyStore: MemoryE2EKeyStore())
        XCTAssertEqual(target?.message.id, a.id)
        XCTAssertNil(IncomingSMSNotificationTarget.resolve(userInfo: [:], requestIdentifier: "unrelated",
            isRemote: false, storedMessages: [a, b], keyStore: MemoryE2EKeyStore()))
    }

    func testDeletedLocalMessageDoesNotOpenAnotherMessageWithSameSender() {
        let deleted = localMessage()
        XCTAssertNil(IncomingSMSNotificationTarget.resolve(
            userInfo: IncomingSMSNotificationTarget.localUserInfo(for: deleted), requestIdentifier: "local",
            isRemote: false, storedMessages: [localMessage(delivery: "new")], keyStore: MemoryE2EKeyStore()))
    }

    func testEncryptedPushOpenedOnColdLaunchStaysReadAfterAgentSync() throws {
        try withHistory { store, directory in
            let target = try XCTUnwrap(IncomingSMSNotificationTarget.resolve(
                userInfo: E2ESMSFixture.push(), requestIdentifier: "apns", isRemote: true,
                storedMessages: [], keyStore: E2ESMSFixture.store()))
            XCTAssertTrue(target.recordOpened(in: store, legacySourceAgentID: nil))
            XCTAssertEqual(store.loadMessages().map(\.id), [target.message.id])
            var synced = target.message; synced.simSlot = "SIM 2"
            XCTAssertNotNil(store.ingestMessages([synced], legacySourceAgentID: nil))
            let reopened = LocalHistoryStore(directoryURL: directory)
            XCTAssertTrue(reopened.unreadMessageIDs(in: reopened.loadMessages()).isEmpty)
            XCTAssertEqual(reopened.loadMessages().first?.simSlot, "SIM 2")
        }
    }

    func testTruncatedPushReadBeforeFullBodyArrivesDoesNotStorePreviewOrMarkOtherDeviceRead() throws {
        try withHistory { store, _ in
            let info = try E2ESMSFixture.sealedPush(#"{"sender":"95588","content":"通知预览…","timestamp":"2026-11-03T08:00:00Z","truncated":true}"#)
            let target = try XCTUnwrap(IncomingSMSNotificationTarget.resolve(userInfo: info,
                requestIdentifier: "apns", isRemote: true, storedMessages: [], keyStore: E2ESMSFixture.store()))
            XCTAssertTrue(target.recordOpened(in: store, legacySourceAgentID: nil))
            XCTAssertTrue(store.loadMessages().isEmpty)
            let complete = SMSMessage(sender: target.message.sender, content: "完整正文", code: nil,
                timestamp: target.message.timestamp, deliveryID: target.message.deliveryID,
                direction: .incoming, sourceAgentID: target.message.sourceAgentID)
            var otherDevice = complete; otherDevice.sourceAgentID = "android-B"
            XCTAssertNotNil(store.ingestMessages([complete, otherDevice], legacySourceAgentID: nil))
            XCTAssertEqual(store.unreadMessageIDs(in: store.loadMessages()), [otherDevice.id])
            XCTAssertFalse(store.loadMessages().contains { $0.content == "通知预览…" })
        }
    }

    func testLegacyCloudPushReadSurvivesUniqueDeviceScoping() throws {
        try withHistory { store, _ in
            let target = try XCTUnwrap(IncomingSMSNotificationTarget.resolve(
                userInfo: E2ESMSFixture.plaintextPush(agentID: nil), requestIdentifier: "apns", isRemote: true,
                storedMessages: [], keyStore: MemoryE2EKeyStore()))
            XCTAssertTrue(target.recordOpened(in: store, legacySourceAgentID: "android-A"))
            XCTAssertNil(store.loadMessages().first?.sourceAgentID)
            var authenticated = target.message; authenticated.sourceAgentID = "android-A"
            XCTAssertNotNil(store.ingestMessages([authenticated], legacySourceAgentID: "android-A"))
            XCTAssertEqual(store.loadMessages().first?.sourceAgentID, "android-A")
            XCTAssertTrue(store.unreadMessageIDs(in: store.loadMessages()).isEmpty)
        }
    }

    func testAmbiguousLegacyNotificationDoesNotMarkEitherDeviceCopyRead() throws {
        try withHistory { store, _ in
            let target = try XCTUnwrap(IncomingSMSNotificationTarget.resolve(
                userInfo: E2ESMSFixture.plaintextPush(agentID: nil), requestIdentifier: "apns", isRemote: true,
                storedMessages: [], keyStore: MemoryE2EKeyStore()))
            XCTAssertTrue(target.recordOpened(in: store, legacySourceAgentID: nil))
            var a = target.message; a.sourceAgentID = "android-A"
            var b = target.message; b.sourceAgentID = "android-B"
            XCTAssertNotNil(store.ingestMessages([a, b], legacySourceAgentID: nil))
            XCTAssertEqual(store.unreadMessageIDs(in: store.loadMessages()), [a.id, b.id])
        }
    }

    func testUntrustedCloudPushCannotUseLocalReferenceOrPlaintextFallback() throws {
        let stored = localMessage()
        var forged = E2ESMSFixture.plaintextPush(agentID: "android-A")
        forged[IncomingSMSNotificationTarget.localMessageIDKey] = stored.id
        XCTAssertNil(IncomingSMSNotificationTarget.resolve(userInfo: forged, requestIdentifier: "apns",
            isRemote: true, storedMessages: [stored], keyStore: E2ESMSFixture.store()))
        XCTAssertNil(try IncomingSMSNotificationTarget.resolve(userInfo: E2ESMSFixture.push(), requestIdentifier: "apns",
            isRemote: true, storedMessages: [stored], keyStore: MemoryE2EKeyStore(failure: .locked)))
    }
}

/// App-side end-to-end encrypted SMS (issue #24): pairing negotiation and SMS push handling.
final class E2ESMSAppTests: XCTestCase {
    func testTXTAdvertisesE2E() throws {
        let endpoint = NWEndpoint.hostPort(host: "192.168.49.1", port: 38000)
        let base = ["v": "1", "session": "fixture-session",
                    "key": Data(repeating: 1, count: 32).base64EncodedString(),
                    "expires": String(Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000))]
        func service(_ extra: [String: String]) -> SamsungPairingService? {
            SamsungPairingBrowser.service(endpoint: endpoint, record: NWTXTRecord(base.merging(extra) { $1 }))
        }
        XCTAssertTrue(try XCTUnwrap(service(["e2e": "1"])).supportsE2ESMS)
        XCTAssertFalse(try XCTUnwrap(service([:])).supportsE2ESMS)
        XCTAssertFalse(try XCTUnwrap(service(["e2e": "0"])).supportsE2ESMS)
        XCTAssertNil(service(["v": "2", "e2e": "1"]))
    }

    func testRelayHealthCapabilities() {
        func body(_ capabilities: String?, service: String = "airsim-push-relay") -> Data {
            var json = #"{"ok":true,"service":""# + service + #"","version":"0.2.1""#
            if let capabilities { json += #","capabilities":"# + capabilities }
            return Data((json + "}").utf8)
        }
        let merged = #"{"agent_command_routing":1,"e2e_sms":1}"#
        XCTAssertTrue(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(merged)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(nil)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(#"{"e2e_sms":0}"#)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(#"{"e2e_sms":"1"}"#)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(merged, service: "djonehub")))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 503, data: body(merged)))
        // An odd capabilities value must not break the existing Relay identity check.
        XCTAssertEqual(RelayHealthValidation.version(statusCode: 200, data: body("[1]")), "0.2.1")
    }

    func testOfferNeedsCloudRelayAndKeychain() {
        for localOnly in [false, true] {
            for relay in [false, true] {
                for keychain in [false, true] {
                    XCTAssertEqual(E2EPairingPolicy.offer(localOnly: localOnly, relaySupports: relay, keychainReady: keychain),
                                   (localOnly, relay, keychain) == (false, true, true), "\(localOnly) \(relay) \(keychain)")
                }
            }
        }
    }

    func testKeyChangeAfterPairing() {
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        XCTAssertNil(E2EPairingKeyChange.after(localOnly: true, sentKey: key, deviceID: "iphone-air"))
        XCTAssertNil(E2EPairingKeyChange.after(localOnly: true, sentKey: nil, deviceID: "iphone-air"))
        XCTAssertEqual(E2EPairingKeyChange.after(localOnly: false, sentKey: key, deviceID: "iphone-air"),
                       .save(E2EKeyRecord(key: Data(repeating: 9, count: 32), deviceID: "iphone-air")))
        XCTAssertEqual(E2EPairingKeyChange.after(localOnly: false, sentKey: nil, deviceID: "iphone-air"), .remove)
    }

    func testResultSuffixReportsCommittedKeyChanges() {
        let record = E2EKeyRecord(key: Data(repeating: 9, count: 32), deviceID: "iphone-air")
        let stored = MemoryE2EKeyStore(["android-A": record])
        XCTAssertEqual(E2EPairingKeyChange.save(record).resultSuffix(agentID: "android-A", hadKey: false, store: stored),
                       "，云端短信已加密")
        XCTAssertEqual(E2EPairingKeyChange.save(record).resultSuffix(agentID: "android-B", hadKey: false, store: stored), "")
        let other = E2EKeyRecord(key: Data(repeating: 8, count: 32), deviceID: "iphone-air")
        XCTAssertEqual(E2EPairingKeyChange.save(other).resultSuffix(agentID: "android-A", hadKey: false, store: stored), "")
        // A cloud pairing that dropped an existing key says so instead of turning encryption off silently.
        let empty = MemoryE2EKeyStore()
        XCTAssertEqual(E2EPairingKeyChange.remove.resultSuffix(agentID: "android-A", hadKey: true, store: empty),
                       "，云端短信加密已关闭")
        XCTAssertEqual(E2EPairingKeyChange.remove.resultSuffix(agentID: "android-A", hadKey: false, store: empty), "")
        // Not committed yet (identity still unproven): say nothing.
        XCTAssertEqual(E2EPairingKeyChange.remove.resultSuffix(agentID: "android-A", hadKey: true, store: stored), "")
    }

    func testWaitingMessageWarnsThatTheKeyIsNotSavedYet() {
        let waiting = "加密配对已写入安卓，正在等待通话网关身份验证；暂未建立可用路由。"
        XCTAssertEqual(E2EPairingKeyChange.waitingMessage(keySent: false), waiting)
        XCTAssertEqual(E2EPairingKeyChange.waitingMessage(keySent: true),
                       waiting + "短信钥匙会在验证通过后保存，期间请保持 AirSIM 打开。")
    }

    func testRelayChangeClearsE2EKeys() {
        // Android keeps one key per (iPhone, Relay) and sends plaintext through a new Relay, which a
        // kept key would refuse as forged; the next pairing on the new Relay turns encryption back on.
        let keys = E2ESMSFixture.store()
        E2EPairingPolicy.relayChanged(from: "https://relay.example", to: "https://relay.example", store: keys)
        XCTAssertEqual(keys.all.count, 1)
        E2EPairingPolicy.relayChanged(from: "https://relay.example", to: "https://other.example", store: keys)
        XCTAssertEqual(keys.all, [:])
    }

    func testRelayProbeRetriesTransientFailures() async {
        let url = URL(string: "https://relay.example/healthz")!
        func reply(_ status: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let supported = reply(200, #"{"ok":true,"service":"airsim-push-relay","version":"0.2.1","capabilities":{"e2e_sms":1}}"#)
        let flaky = ScriptedRelay([nil, reply(503, "{}"), supported])
        let offered = await VoIPPushController.relaySupportsE2ESMS(relayURL: "https://relay.example") { try await flaky.send($0) }
        XCTAssertTrue(offered)
        XCTAssertEqual(flaky.calls, 3)
        let down = ScriptedRelay([nil, nil, nil, supported])
        let unreachable = await VoIPPushController.relaySupportsE2ESMS(relayURL: "https://relay.example") { try await down.send($0) }
        XCTAssertFalse(unreachable)
        XCTAssertEqual(down.calls, 3)
        // A Relay that answers without the capability is not asked again.
        let old = ScriptedRelay([reply(200, #"{"ok":true,"service":"airsim-push-relay","version":"0.2.0"}"#), supported])
        let unsupported = await VoIPPushController.relaySupportsE2ESMS(relayURL: "https://relay.example") { try await old.send($0) }
        XCTAssertFalse(unsupported)
        XCTAssertEqual(old.calls, 1)
    }

    // MARK: - SMS pushes in the app

    func testPushDecryptsVector() throws {
        let pushed = try IncomingRemoteSMS(userInfo: E2ESMSFixture.push(), keyStore: E2ESMSFixture.store())
        XCTAssertEqual(pushed.message.sender, "95588")
        XCTAssertEqual(pushed.message.content, "【银行】验证码 123456")
        XCTAssertEqual(pushed.message.sourceAgentID, "android-A")
        XCTAssertEqual(pushed.message.deliveryID, E2ESMSFixture.delivery)
        XCTAssertNil(pushed.message.code)
        XCTAssertFalse(pushed.contentTruncated)
        // The push's 2026-11-03T08:00:00Z (the Relay's arrival rule), not the sealed carrier time.
        XCTAssertEqual(pushed.message.timestamp, Date(timeIntervalSince1970: 1_793_692_800))
    }

    func testPlaintextFromKeyedAgentRejected() {
        XCTAssertThrowsError(try IncomingRemoteSMS(userInfo: E2ESMSFixture.plaintextPush(agentID: "android-A"),
                                                   keyStore: E2ESMSFixture.store())) {
            XCTAssertEqual($0 as? RemoteSMSPushError, .unencryptedFromEncryptedAgent)
        }
    }

    func testPlaintextWithoutKeyUnchanged() throws {
        let pushed = try IncomingRemoteSMS(userInfo: E2ESMSFixture.plaintextPush(agentID: "android-B"),
                                           keyStore: E2ESMSFixture.store())
        XCTAssertEqual(pushed.sender, "95588")
        XCTAssertEqual(pushed.content, "【银行】验证码 123456")
        XCTAssertEqual(pushed.agentID, "android-B")
        XCTAssertEqual(pushed.deliveryID, "android-sms-plain")
        XCTAssertFalse(pushed.contentTruncated)
    }

    func testUndecryptablePushRejected() throws {
        XCTAssertThrowsError(try IncomingRemoteSMS(userInfo: E2ESMSFixture.push(), keyStore: MemoryE2EKeyStore())) {
            XCTAssertEqual($0 as? RemoteSMSPushError, .undecryptable)
        }
    }

    func testLockedPushRejected() throws {
        let locked = MemoryE2EKeyStore(failure: .locked)
        XCTAssertThrowsError(try IncomingRemoteSMS(userInfo: E2ESMSFixture.push(), keyStore: locked)) {
            XCTAssertEqual($0 as? RemoteSMSPushError, .locked)
        }
        // Before the first unlock it is unknown whether the agent has a key, so plaintext is not stored either.
        XCTAssertThrowsError(try IncomingRemoteSMS(userInfo: E2ESMSFixture.plaintextPush(agentID: "android-A"),
                                                   keyStore: locked)) {
            XCTAssertEqual($0 as? RemoteSMSPushError, .locked)
        }
    }

    func testTruncatedFlagFromPlaintext() throws {
        let push = try E2ESMSFixture.sealedPush(#"{"sender":"95588","content":"很长的短信…","timestamp":"2026-11-03T08:00:00Z","truncated":true}"#)
        let pushed = try IncomingRemoteSMS(userInfo: push, keyStore: E2ESMSFixture.store())
        XCTAssertTrue(pushed.contentTruncated)
        XCTAssertEqual(pushed.content, "很长的短信…")
    }

    func testEmptyDecryptedContentIncomplete() throws {
        let push = try E2ESMSFixture.sealedPush(#"{"sender":"95588","content":" ","timestamp":"2026-11-03T08:00:00Z","truncated":false}"#)
        XCTAssertThrowsError(try IncomingRemoteSMS(userInfo: push, keyStore: E2ESMSFixture.store())) {
            XCTAssertEqual($0 as? RemoteSMSPushError, .incomplete)
        }
    }

    func testDecryptedEmptySenderIsUnknown() throws {
        let push = try E2ESMSFixture.sealedPush(#"{"sender":"","content":"正文","timestamp":"2026-11-03T08:00:00Z","truncated":false}"#)
        XCTAssertEqual(try IncomingRemoteSMS(userInfo: push, keyStore: E2ESMSFixture.store()).sender, "未知号码")
    }

    func testDecryptedSIMSlotComesOnlyFromTheSealedText() throws {
        // Replies use the SIM that received the conversation, so a clear sim_slot added by the
        // Relay must not steer them.
        var sealed = try E2ESMSFixture.sealedPush(#"{"sender":"95588","content":"正文","timestamp":"2026-11-03T08:00:00Z","truncated":false,"sim_slot":"SIM 2"}"#)
        sealed["sim_slot"] = "SIM 1"
        let pushed = try IncomingRemoteSMS(userInfo: sealed, keyStore: E2ESMSFixture.store())
        XCTAssertEqual(pushed.simSlot, "SIM 2")
        XCTAssertEqual(pushed.message.simSlot, "SIM 2")
        var unsealed = try E2ESMSFixture.sealedPush(#"{"sender":"95588","content":"正文","timestamp":"2026-11-03T08:00:00Z","truncated":false}"#)
        unsealed["sim_slot"] = "SIM 1"
        XCTAssertNil(try IncomingRemoteSMS(userInfo: unsealed, keyStore: E2ESMSFixture.store()).simSlot)
        // A plaintext push keeps the Relay's clear field.
        var plain = E2ESMSFixture.plaintextPush(agentID: "android-B")
        plain["sim_slot"] = "SIM 1"
        XCTAssertEqual(try IncomingRemoteSMS(userInfo: plain, keyStore: E2ESMSFixture.store()).simSlot, "SIM 1")
    }

    func testRegistrationNeverEncodesE2EKey() throws {
        // The same registration is later sent unsealed to /api/push/register and the Relay.
        let cloud = AgentPushRegistration(cloudModeEnabled: true, deviceID: "iphone-air", deviceSecret: "device-secret",
            token: "voip", alertToken: "alert", watchVoIPToken: "", watchBundleID: "",
            liveActivityPushToStartToken: "", bundleID: "com.example.airsim", environment: "sandbox",
            relayURL: "https://relay.example", vowlanSecret: "vowlan")
        for registration in [cloud, AgentPushRegistration.local(vowlanSecret: "vowlan")] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any])
            XCTAssertNil(object["e2e_key"])
        }
    }
}

/// Answers each request with the next scripted reply; nil throws like a dropped connection.
private final class ScriptedRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Data, URLResponse)?]
    private var count = 0
    init(_ replies: [(Data, URLResponse)?]) { self.replies = replies }
    var calls: Int { lock.withLock { count } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: (Data, URLResponse)? = lock.withLock {
            count += 1
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else { throw URLError(.networkConnectionLost) }
        return reply
    }
}
