import CryptoKit
import XCTest
@testable import AirSIM

/// End-to-end encrypted SMS (issue #24): crypto, key store and push classification, i.e. the
/// sources the Notification Service Extension compiles too. App-side behavior is in E2ESMSAppTests.
final class E2ESMSTests: XCTestCase {
    private let failureCopy = E2ESMSPush.Notification(
        title: "AirSIM", body: "收到一条加密短信，但无法解密，请在同一 Wi-Fi 下重新配对", threadIdentifier: nil)

    func testSubkeyAndKidMatchNode() {
        let smsIn = E2ESMS.subkey(E2ESMSFixture.key, purpose: "sms-in").withUnsafeBytes { Data($0) }
        XCTAssertEqual(smsIn.map { String(format: "%02x", $0) }.joined(),
                       "51df33def69dff3879fd25f082b96f4c53edbf4bf66ca06d9c29da22d0bddd59")
        XCTAssertEqual(E2ESMS.kid(of: E2ESMSFixture.key), "3946e215")
    }

    func testOpensNodeVector() throws {
        XCTAssertEqual(try open(vectorEnvelope()), E2ESMSFixture.plaintext)
    }

    func testAADBindsDeviceAgentAndDelivery() throws {
        let envelope = try vectorEnvelope()
        let delivery = E2ESMSFixture.delivery
        let others = [("iphone-b", "android-A", delivery),
                      ("iphone-air", "android-B", delivery),
                      ("iphone-air", "android-A", delivery + "0")]
        for (device, agent, delivery) in others {
            XCTAssertThrowsError(try open(envelope, deviceID: device, agentID: agent, deliveryID: delivery)) {
                XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable)
            }
        }
    }

    func testKidMismatch() throws {
        let otherKid = try envelope(E2ESMSFixture.envelopeJSON(kid: "00000000"))
        XCTAssertThrowsError(try open(otherKid)) { XCTAssertEqual($0 as? E2ESMS.Failure, .keyMismatch) }
        // After a re-pair on one side only, the iPhone's key no longer matches the envelope's kid.
        XCTAssertThrowsError(try E2ESMS.open(vectorEnvelope(), key: SymmetricKey(data: Data(1...32)),
                                             deviceID: "iphone-air", agentID: "android-A",
                                             deliveryID: E2ESMSFixture.delivery)) {
            XCTAssertEqual($0 as? E2ESMS.Failure, .keyMismatch)
        }
    }

    func testFlippedCiphertextUndecryptable() throws {
        // "G" → "H" flips one bit of the first ciphertext byte; the encoding stays canonical.
        let flipped = try envelope(E2ESMSFixture.envelopeJSON(ct: "H" + String(E2ESMSFixture.ct.dropFirst())))
        XCTAssertThrowsError(try open(flipped)) { XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable) }
    }

    func testShortenedCiphertextUndecryptable() throws {
        // Four characters are exactly three bytes, so the shorter text is still canonical.
        let shortened = try envelope(E2ESMSFixture.envelopeJSON(ct: String(E2ESMSFixture.ct.dropFirst(4))))
        XCTAssertThrowsError(try open(shortened)) { XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable) }
    }

    func testNonJSONPlaintextUndecryptable() throws {
        let sealed = try envelope(E2ESMSFixture.sealedEnvelopeJSON("not json", deliveryID: E2ESMSFixture.delivery))
        XCTAssertThrowsError(try open(sealed)) { XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable) }
    }

    func testMalformedEnvelopeRejected() throws {
        let rejected = [
            "null", #""x""#, "{}",
            E2ESMSFixture.envelopeJSON(v: "true"), E2ESMSFixture.envelopeJSON(v: "2"), E2ESMSFixture.envelopeJSON(v: #""1""#),
            E2ESMSFixture.envelopeJSON(kid: "3946E215"), E2ESMSFixture.envelopeJSON(kid: "3946e21"),
            E2ESMSFixture.envelopeJSON(n: "oKGio6Slpqeoqaq"), E2ESMSFixture.envelopeJSON(n: "oKGio6Slpqeoqaqrs"),
            E2ESMSFixture.envelopeJSON(n: "oKGio6Sl+qeoqaqr"),
            E2ESMSFixture.envelopeJSON(ct: String(repeating: "A", count: 22)),
            // 4n+1 characters cannot encode whole bytes.
            E2ESMSFixture.envelopeJSON(ct: String(repeating: "A", count: 25)),
            // "B" leaves a nonzero unused bit, so this is not the canonical encoding of its bytes.
            E2ESMSFixture.envelopeJSON(ct: String(repeating: "A", count: 22) + "B"),
            E2ESMSFixture.envelopeJSON(ct: String(repeating: "A", count: 8193)),
        ]
        for text in rejected {
            XCTAssertNil(E2ESMS.Envelope(try E2ESMSFixture.json(text)), String(text.prefix(80)))
        }
        XCTAssertNotNil(E2ESMS.Envelope(try E2ESMSFixture.json(E2ESMSFixture.envelopeJSON(ct: String(repeating: "A", count: 23)))))
        XCTAssertNotNil(E2ESMS.Envelope(try E2ESMSFixture.json(E2ESMSFixture.envelopeJSON(ct: String(repeating: "A", count: 8192)))))
    }

    func testNewKeyIs32BytesAndBase64URLRoundTrips() {
        let first = E2ESMS.newKey(), second = E2ESMS.newKey()
        XCTAssertEqual(first.bitCount, 256)
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
        XCTAssertEqual(E2ESMS.base64URL(Data(0..<32)), "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertEqual(E2ESMS.base64URL(Data([0xfb, 0xff, 0xbf])), "-_-_")
        XCTAssertEqual(E2ESMS.data(base64URL: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"), Data(0..<32))
        XCTAssertEqual(E2ESMS.data(base64URL: "-_-_"), Data([0xfb, 0xff, 0xbf]))
        for invalid in ["A", "AB", "AA==", "+/+/", "AA A"] {
            XCTAssertNil(E2ESMS.data(base64URL: invalid), invalid)
        }
    }

    // MARK: - Push classification and notification text

    func testOpenDecryptsVectorPush() throws {
        let outcome = E2ESMSPush.open(try E2ESMSFixture.push(), store: E2ESMSFixture.store())
        XCTAssertEqual(outcome, .decrypted(E2ESMSFixture.plaintext))
        // The vector predates sim_slot, so the subtitle is the Relay's "SIM 未知".
        XCTAssertEqual(E2ESMSPush.notification(for: outcome),
                       E2ESMSPush.Notification(title: "95588", subtitle: "SIM 未知", body: "【银行】验证码 123456",
                                               threadIdentifier: "airsim-sms-95588"))
    }

    func testEmptySenderShowsUnknown() throws {
        for sender in ["", "  "] {
            let push = try E2ESMSFixture.sealedPush(#"{"sender":"\#(sender)","content":"正文","timestamp":"2026-11-03T08:00:00Z","truncated":false}"#)
            XCTAssertEqual(E2ESMSPush.notification(for: E2ESMSPush.open(push, store: E2ESMSFixture.store())),
                           E2ESMSPush.Notification(title: "未知号码", subtitle: "SIM 未知", body: "正文",
                                                   threadIdentifier: "airsim-sms-未知号码"))
        }
    }

    func testSealedSIMSlotBecomesTheSubtitle() throws {
        let push = try E2ESMSFixture.sealedPush(#"{"sender":"95588","content":"正文","timestamp":"2026-11-03T08:00:00Z","truncated":false,"sim_slot":"SIM 2"}"#)
        let outcome = E2ESMSPush.open(push, store: E2ESMSFixture.store())
        guard case .decrypted(let sms) = outcome else { return XCTFail("not decrypted: \(outcome)") }
        XCTAssertEqual(sms.simSlot, "SIM 2")
        XCTAssertEqual(E2ESMSPush.notification(for: outcome)?.subtitle, "接收于 SIM 2")
        // The Relay's rule for plaintext pushes: "SIM 1"…"SIM 99", anything else is unknown.
        let cases: [(String?, String?)] = [(" SIM 12 ", "SIM 12"), ("SIM 0", nil), ("SIM 100", nil),
                                           ("卡 1", nil), ("", nil), (nil, nil)]
        for (raw, slot) in cases {
            XCTAssertEqual(E2ESMSPush.simSlot(raw), slot, raw ?? "nil")
        }
        let odd = try E2ESMSFixture.sealedPush(#"{"sender":"95588","content":"正文","timestamp":"2026-11-03T08:00:00Z","truncated":false,"sim_slot":"SIM 100"}"#)
        XCTAssertEqual(E2ESMSPush.notification(for: E2ESMSPush.open(odd, store: E2ESMSFixture.store()))?.subtitle,
                       "SIM 未知")
    }

    func testThreadIdentifierCutsAt64UTF16Units() throws {
        // The Relay cuts "airsim-sms-<sender>" to 64 UTF-16 units for plaintext pushes.
        let cases = [(String(repeating: "9", count: 60), "airsim-sms-" + String(repeating: "9", count: 53)),
                     (String(repeating: "中", count: 60), "airsim-sms-" + String(repeating: "中", count: 53))]
        for (sender, thread) in cases {
            let push = try E2ESMSFixture.sealedPush(#"{"sender":"\#(sender)","content":"x","timestamp":"2026-11-03T08:00:00Z","truncated":false}"#)
            let notification = E2ESMSPush.notification(for: E2ESMSPush.open(push, store: E2ESMSFixture.store()))
            XCTAssertEqual(notification?.threadIdentifier, thread)
            XCTAssertEqual(notification?.title, sender)
        }
    }

    func testLockedStoreOutcomes() throws {
        let locked = MemoryE2EKeyStore(failure: .locked)
        let encrypted = E2ESMSPush.open(try E2ESMSFixture.push(), store: locked)
        XCTAssertEqual(encrypted, .locked(encrypted: true))
        XCTAssertEqual(E2ESMSPush.notification(for: encrypted),
                       E2ESMSPush.Notification(title: "AirSIM", body: "解锁 iPhone 后，在 AirSIM 中查看这条短信",
                                               threadIdentifier: nil))
        let plaintext = E2ESMSPush.open(E2ESMSFixture.plaintextPush(agentID: "android-A"), store: locked)
        XCTAssertEqual(plaintext, .locked(encrypted: false))
        XCTAssertNil(E2ESMSPush.notification(for: plaintext))
    }

    func testUndecryptableOutcomes() throws {
        var malformed = try E2ESMSFixture.push()
        malformed["e2e"] = ["v": 1]
        var noAgent = try E2ESMSFixture.push()
        noAgent["agent_id"] = nil
        var noDelivery = try E2ESMSFixture.push()
        noDelivery["delivery_id"] = ""
        let otherDevice = MemoryE2EKeyStore(["android-A": E2EKeyRecord(key: Data(0..<32), deviceID: "iphone-other")])
        let cases: [(String, [AnyHashable: Any], MemoryE2EKeyStore)] = [
            ("no record", try E2ESMSFixture.push(), MemoryE2EKeyStore()),
            ("other device_id", try E2ESMSFixture.push(), otherDevice),
            ("malformed envelope", malformed, E2ESMSFixture.store()),
            ("missing agent_id", noAgent, E2ESMSFixture.store()),
            ("empty delivery_id", noDelivery, E2ESMSFixture.store()),
            ("keychain unavailable", try E2ESMSFixture.push(), MemoryE2EKeyStore(failure: .unavailable)),
        ]
        for (name, push, store) in cases {
            let outcome = E2ESMSPush.open(push, store: store)
            XCTAssertEqual(outcome, .undecryptable, name)
            XCTAssertEqual(E2ESMSPush.notification(for: outcome), failureCopy, name)
        }
    }

    func testPlaintextFromKeyedAgentIsForged() {
        let outcome = E2ESMSPush.open(E2ESMSFixture.plaintextPush(agentID: "android-A"), store: E2ESMSFixture.store())
        XCTAssertEqual(outcome, .unencryptedFromEncryptedAgent)
        XCTAssertEqual(E2ESMSPush.notification(for: outcome),
                       E2ESMSPush.Notification(title: "AirSIM", body: "收到一条未加密的短信推送，已忽略",
                                               threadIdentifier: nil))
    }

    func testUnconfiguredKeychainKeepsPlaintextPath() {
        // Builds without the shared group never sent a key, so their plaintext stays as today.
        let outcome = E2ESMSPush.open(E2ESMSFixture.plaintextPush(agentID: "android-A"),
                                      store: MemoryE2EKeyStore(failure: .unconfigured))
        XCTAssertEqual(outcome, .plaintext)
        XCTAssertNil(E2ESMSPush.notification(for: outcome))
    }

    func testUnreadableKeyDoesNotAcceptPlaintext() {
        XCTAssertEqual(E2ESMSPush.open(E2ESMSFixture.plaintextPush(agentID: "android-A"),
            store: MemoryE2EKeyStore(failure: .unavailable)), .undecryptable)
    }

    func testPlaintextWithoutAgentOrKeyIsLegacy() {
        XCTAssertEqual(E2ESMSPush.open(E2ESMSFixture.plaintextPush(agentID: nil), store: E2ESMSFixture.store()), .plaintext)
        XCTAssertEqual(E2ESMSPush.open(E2ESMSFixture.plaintextPush(agentID: "android-B"), store: E2ESMSFixture.store()),
                       .plaintext)
    }

    func testOtherEventsIgnored() throws {
        var call = try E2ESMSFixture.push()
        call["event"] = "incoming_call"
        XCTAssertEqual(E2ESMSPush.open(call, store: E2ESMSFixture.store()), .notSMS)
        XCTAssertEqual(E2ESMSPush.open([:], store: E2ESMSFixture.store()), .notSMS)
        XCTAssertNil(E2ESMSPush.notification(for: .notSMS))
    }

    func testKeyRecordJSONRoundTrip() throws {
        // Stored in the keychain, so the format must survive app updates.
        let record = E2EKeyRecord(key: Data(0..<32), deviceID: "iphone-air")
        let encoded = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["device_id"] as? String, "iphone-air")
        XCTAssertEqual(object["key"] as? String, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        XCTAssertEqual(try JSONDecoder().decode(E2EKeyRecord.self, from: encoded), record)
    }

    func testKeychainStoreWithoutGroupIsUnavailable() {
        // Unsigned or re-signed builds without Keychain Sharing: never offer a key.
        for group in [nil, ""] as [String?] {
            let store = KeychainE2EKeyStore(accessGroup: group)
            XCTAssertFalse(store.canStore())
            XCTAssertThrowsError(try store.record(agentID: "android-A")) {
                XCTAssertEqual($0 as? E2EKeyStoreError, .unconfigured)
            }
            XCTAssertThrowsError(try store.save(E2EKeyRecord(key: Data(0..<32), deviceID: "iphone-air"),
                                                agentID: "android-A")) {
                XCTAssertEqual($0 as? E2EKeyStoreError, .unconfigured)
            }
        }
    }

    // MARK: - Helpers

    private func envelope(_ text: String) throws -> E2ESMS.Envelope {
        try XCTUnwrap(E2ESMS.Envelope(E2ESMSFixture.json(text)))
    }

    private func vectorEnvelope() throws -> E2ESMS.Envelope {
        try envelope(E2ESMSFixture.envelopeJSON())
    }

    private func open(_ envelope: E2ESMS.Envelope, deviceID: String = "iphone-air",
                      agentID: String = "android-A", deliveryID: String? = nil) throws -> E2ESMS.Plaintext {
        try E2ESMS.open(envelope, key: E2ESMSFixture.key, deviceID: deviceID, agentID: agentID,
                        deliveryID: deliveryID ?? E2ESMSFixture.delivery)
    }
}

/// The issue #24 Node vector and Relay-shaped pushes (13f0c41 `push-relay-worker/src/index.mjs`),
/// shared by the E2E SMS test classes.
enum E2ESMSFixture {
    static let key = SymmetricKey(data: Data(0..<32))
    static let ct = "G1bqIzAQqg49db6t2KX7AlFUmc4-J3ZRnP7zb16Y_jFW4Cr0qQSX_TCq8X4GU6j4XMzwmOCjBcJ5K1JRWBhrTEZXOH73vi8utyUL4PvZeT18QcVa6VhqzCsLIG94qPMrIVx_7zyWui8P6JZ2uWzOwJznSOxpekWaZ8mRet4v9oo"
    static let delivery = "android-sms-ff317720dfc84a7be3125b7af8e2f3f5a0351aba73f515b48d111eb126fc0394"
    static let plaintext = E2ESMS.Plaintext(sender: "95588", content: "【银行】验证码 123456",
                                            timestamp: "2024-10-27T03:33:20Z", truncated: false)

    /// A store holding the vector key for android-A, bound to iphone-air.
    static func store() -> MemoryE2EKeyStore {
        MemoryE2EKeyStore(["android-A": E2EKeyRecord(key: Data(0..<32), deviceID: "iphone-air")])
    }

    /// Raw JSON text of an envelope; `v` is inserted as JSON, the other fields as string contents.
    static func envelopeJSON(v: String = "1", kid: String = "3946e215", n: String = "oKGio6Slpqeoqaqr",
                             ct: String? = nil) -> String {
        #"{"v":\#(v),"kid":"\#(kid)","n":"\#(n)","ct":"\#(ct ?? Self.ct)"}"#
    }

    /// The Relay's encrypted SMS push (`encryptedSMSPayload`) carrying the Node vector.
    static func push() throws -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["title": "AirSIM", "body": "新短信"], "sound": "default",
                    "thread-id": "airsim-sms-agent-android-A", "content-available": 1, "mutable-content": 1],
            "event": "incoming_sms", "delivery_id": delivery, "agent_id": "android-A",
            "timestamp": "2026-11-03T08:00:00Z", "e2e": try json(envelopeJSON()),
        ]
    }

    /// An encrypted push for `plaintextJSON`, sealed with the vector key for iphone-air / android-A.
    static func sealedPush(_ plaintextJSON: String) throws -> [AnyHashable: Any] {
        var sealed = try Self.push()
        sealed["delivery_id"] = "android-sms-test"
        sealed["e2e"] = try json(sealedEnvelopeJSON(plaintextJSON, deliveryID: "android-sms-test"))
        return sealed
    }

    /// The Relay's plaintext SMS push; `agentID` nil leaves the field out like old agents.
    static func plaintextPush(agentID: String?) -> [AnyHashable: Any] {
        var push: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "95588", "body": "【银行】验证码 123456"], "sound": "default",
                    "thread-id": "airsim-sms-95588", "content-available": 1],
            "event": "incoming_sms", "delivery_id": "android-sms-plain", "sender": "95588",
            "content": "【银行】验证码 123456", "content_truncated": false, "code": "",
            "timestamp": "2026-11-03T08:00:00Z",
        ]
        push["agent_id"] = agentID
        return push
    }

    /// Seals `plaintext` with the vector key the way Android does, for cases the vector does not cover.
    static func sealedEnvelopeJSON(_ plaintext: String, deliveryID: String) throws -> String {
        let aad = Data("AirSIM-E2E/v1|incoming_sms|iphone-air|android-A|\(deliveryID)".utf8)
        let nonce = Data(repeating: 7, count: 12)
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: E2ESMS.subkey(key, purpose: "sms-in"),
                                   nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        func url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return #"{"v":1,"kid":"\#(E2ESMS.kid(of: key))","n":"\#(url(nonce))","ct":"\#(url(box.ciphertext + box.tag))"}"#
    }

    static func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }
}

/// In-memory `E2EKeyStoring`. `failure` makes every call throw, like a keychain that is locked
/// before the first unlock or has no shared group.
final class MemoryE2EKeyStore: E2EKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: E2EKeyRecord]
    private let failure: E2EKeyStoreError?

    init(_ records: [String: E2EKeyRecord] = [:], failure: E2EKeyStoreError? = nil) {
        self.records = records
        self.failure = failure
    }

    var all: [String: E2EKeyRecord] { lock.withLock { records } }

    func record(agentID: String) throws -> E2EKeyRecord? {
        if let failure { throw failure }
        return lock.withLock { records[agentID] }
    }

    func save(_ record: E2EKeyRecord, agentID: String) throws {
        if let failure { throw failure }
        lock.withLock { records[agentID] = record }
    }

    func remove(agentID: String) {
        lock.withLock { records[agentID] = nil }
    }

    func removeAll() {
        lock.withLock { records.removeAll() }
    }

    func canStore() -> Bool { failure == nil }
}

final class BackportedScopedNotificationTests: XCTestCase {
 func testMissingDeviceNeverMatchesOtherDevice() {
  let a: [AnyHashable: Any] = ["call_id":"same"]
  let b: [AnyHashable: Any] = ["agent_id":"B", "call_id":"same"]
  XCTAssertFalse(CallNotificationTruth.matches(a,b))
 }
 func testDeviceAndGenerationAreIsolated() {
  let a: [AnyHashable: Any] = ["agent_id":"A", "call_id":"same", "generation":1]
  var b = a; b["agent_id"] = "B"; XCTAssertFalse(CallNotificationTruth.matches(a,b))
  b = a; b["generation"] = 2; XCTAssertFalse(CallNotificationTruth.matches(a,b))
  XCTAssertTrue(CallNotificationTruth.matches(a,a))
 }
 func testTerminalCannotBeResurrected() {
  var store = CallLifecycleStore(); let uuid = UUID()
  let first = CallLifecycleEvent(callID:"A",callUUID:uuid,generation:1,state:.ended,source:.agent,timestamp:Date(),traceID:nil,failure:nil)
  _ = store.apply(first)
  XCTAssertFalse(store.apply(.init(callID:"A",callUUID:uuid,generation:1,state:.active,source:.relay,timestamp:Date(),traceID:nil,failure:nil)))
 }
}

final class PushHealthMetadataTests: XCTestCase {
    func testMetadataWritesKeepHistoryAndDoNotOverwriteOtherReceipts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        AirSIMHealthStore.update(in: folder) { $0.lastAlert = now }
        AirSIMHealthStore.update(in: folder) { value in
            value.lastVoIP = now
            value.failures.append(.init(id: "delivery-hash", agentID: "A", date: now, reason: "key mismatch"))
        }
        let value = AirSIMHealthStore.load(from: folder)
        XCTAssertEqual(value.lastAlert, now); XCTAssertEqual(value.lastVoIP, now)
        XCTAssertEqual(value.failures.count, 1); XCTAssertEqual(value.failures[0].agentID, "A")
    }
    func testMetadataCapsHistoryAndRecoversFromCorruptFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("broken".utf8).write(to: folder.appendingPathComponent("metadata.json"))
        AirSIMHealthStore.update(in: folder) { value in
            for i in 0..<70 { value.failures.append(.init(id: String(i), agentID: "A", date: Date(timeIntervalSince1970: Double(i)), reason: "failure")) }
        }
        XCTAssertEqual(AirSIMHealthStore.load(from: folder).failures.count, 60)
    }
}
