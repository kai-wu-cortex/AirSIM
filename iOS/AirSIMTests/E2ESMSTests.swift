import CryptoKit
import XCTest
@testable import AirSIM

/// End-to-end encrypted SMS (issue #24). The vectors were computed independently with Node's
/// `crypto` and are pinned in the Android tests too, so both ends agree byte for byte.
final class E2ESMSTests: XCTestCase {
    private let vectorKey = SymmetricKey(data: Data(0..<32))
    private let vectorCT = "G1bqIzAQqg49db6t2KX7AlFUmc4-J3ZRnP7zb16Y_jFW4Cr0qQSX_TCq8X4GU6j4XMzwmOCjBcJ5K1JRWBhrTEZXOH73vi8utyUL4PvZeT18QcVa6VhqzCsLIG94qPMrIVx_7zyWui8P6JZ2uWzOwJznSOxpekWaZ8mRet4v9oo"
    private let vectorDelivery = "android-sms-ff317720dfc84a7be3125b7af8e2f3f5a0351aba73f515b48d111eb126fc0394"
    private let vectorPlaintext = E2ESMS.Plaintext(sender: "95588", content: "【银行】验证码 123456",
                                                   timestamp: "2024-10-27T03:33:20Z", truncated: false)

    func testSubkeyAndKidMatchNode() {
        let smsIn = E2ESMS.subkey(vectorKey, purpose: "sms-in").withUnsafeBytes { Data($0) }
        XCTAssertEqual(hex(smsIn), "51df33def69dff3879fd25f082b96f4c53edbf4bf66ca06d9c29da22d0bddd59")
        XCTAssertEqual(E2ESMS.kid(of: vectorKey), "3946e215")
    }

    func testOpensNodeVector() throws {
        XCTAssertEqual(try open(vectorEnvelope()), vectorPlaintext)
    }

    func testAADBindsDeviceAgentAndDelivery() throws {
        let envelope = try vectorEnvelope()
        let others = [("iphone-b", "android-A", vectorDelivery),
                      ("iphone-air", "android-B", vectorDelivery),
                      ("iphone-air", "android-A", vectorDelivery + "0")]
        for (device, agent, delivery) in others {
            XCTAssertThrowsError(try open(envelope, deviceID: device, agentID: agent, deliveryID: delivery)) {
                XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable)
            }
        }
    }

    func testKidMismatch() throws {
        let otherKid = try XCTUnwrap(E2ESMS.Envelope(json(envelopeJSON(kid: "00000000"))))
        XCTAssertThrowsError(try open(otherKid)) { XCTAssertEqual($0 as? E2ESMS.Failure, .keyMismatch) }
        // After a re-pair on one side only, the iPhone's key no longer matches the envelope's kid.
        XCTAssertThrowsError(try E2ESMS.open(vectorEnvelope(), key: SymmetricKey(data: Data(1...32)),
                                             deviceID: "iphone-air", agentID: "android-A",
                                             deliveryID: vectorDelivery)) {
            XCTAssertEqual($0 as? E2ESMS.Failure, .keyMismatch)
        }
    }

    func testFlippedCiphertextUndecryptable() throws {
        // "G" → "H" flips one bit of the first ciphertext byte; the encoding stays canonical.
        let flipped = try XCTUnwrap(E2ESMS.Envelope(json(envelopeJSON(ct: "H" + String(vectorCT.dropFirst())))))
        XCTAssertThrowsError(try open(flipped)) { XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable) }
    }

    func testShortenedCiphertextUndecryptable() throws {
        // Four characters are exactly three bytes, so the shorter text is still canonical.
        let shortened = try XCTUnwrap(E2ESMS.Envelope(json(envelopeJSON(ct: String(vectorCT.dropFirst(4))))))
        XCTAssertThrowsError(try open(shortened)) { XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable) }
    }

    func testNonJSONPlaintextUndecryptable() throws {
        let sealed = try sealedEnvelopeJSON("not json", key: vectorKey, deviceID: "iphone-air",
                                            agentID: "android-A", deliveryID: vectorDelivery)
        let envelope = try XCTUnwrap(E2ESMS.Envelope(json(sealed)))
        XCTAssertThrowsError(try open(envelope)) { XCTAssertEqual($0 as? E2ESMS.Failure, .undecryptable) }
    }

    func testMalformedEnvelopeRejected() throws {
        let rejected = [
            "null", #""x""#, "{}",
            envelopeJSON(v: "true"), envelopeJSON(v: "2"), envelopeJSON(v: #""1""#),
            envelopeJSON(kid: "3946E215"), envelopeJSON(kid: "3946e21"),
            envelopeJSON(n: "oKGio6Slpqeoqaq"), envelopeJSON(n: "oKGio6Slpqeoqaqrs"), envelopeJSON(n: "oKGio6Sl+qeoqaqr"),
            envelopeJSON(ct: String(repeating: "A", count: 22)),
            // 4n+1 characters cannot encode whole bytes.
            envelopeJSON(ct: String(repeating: "A", count: 25)),
            // "B" leaves a nonzero unused bit, so this is not the canonical encoding of its bytes.
            envelopeJSON(ct: String(repeating: "A", count: 22) + "B"),
            envelopeJSON(ct: String(repeating: "A", count: 8193)),
        ]
        for text in rejected {
            XCTAssertNil(E2ESMS.Envelope(try json(text)), String(text.prefix(80)))
        }
        XCTAssertNotNil(E2ESMS.Envelope(try json(envelopeJSON(ct: String(repeating: "A", count: 23)))))
        XCTAssertNotNil(E2ESMS.Envelope(try json(envelopeJSON(ct: String(repeating: "A", count: 8192)))))
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

    private let failureCopy = E2ESMSPush.Notification(
        title: "AirSIM", body: "收到一条加密短信，但无法解密，请在同一 Wi-Fi 下重新配对", threadIdentifier: nil)

    func testOpenDecryptsVectorPush() throws {
        let outcome = E2ESMSPush.open(try vectorPush(), store: vectorStore())
        XCTAssertEqual(outcome, .decrypted(vectorPlaintext))
        XCTAssertEqual(E2ESMSPush.notification(for: outcome),
                       E2ESMSPush.Notification(title: "95588", body: "【银行】验证码 123456",
                                               threadIdentifier: "airsim-sms-95588"))
    }

    func testEmptySenderShowsUnknown() throws {
        for sender in ["", "  "] {
            let push = try sealedPush(#"{"sender":"\#(sender)","content":"正文","timestamp":"2026-11-03T08:00:00Z","truncated":false}"#)
            XCTAssertEqual(E2ESMSPush.notification(for: E2ESMSPush.open(push, store: vectorStore())),
                           E2ESMSPush.Notification(title: "未知号码", body: "正文", threadIdentifier: "airsim-sms-未知号码"))
        }
    }

    func testThreadIdentifierCutsAt64UTF16Units() throws {
        // The Relay cuts "airsim-sms-<sender>" to 64 UTF-16 units for plaintext pushes.
        let cases = [(String(repeating: "9", count: 60), "airsim-sms-" + String(repeating: "9", count: 53)),
                     (String(repeating: "中", count: 60), "airsim-sms-" + String(repeating: "中", count: 53))]
        for (sender, thread) in cases {
            let push = try sealedPush(#"{"sender":"\#(sender)","content":"x","timestamp":"2026-11-03T08:00:00Z","truncated":false}"#)
            let notification = E2ESMSPush.notification(for: E2ESMSPush.open(push, store: vectorStore()))
            XCTAssertEqual(notification?.threadIdentifier, thread)
            XCTAssertEqual(notification?.title, sender)
        }
    }

    func testLockedStoreOutcomes() throws {
        let locked = MemoryE2EKeyStore(failure: .locked)
        let encrypted = E2ESMSPush.open(try vectorPush(), store: locked)
        XCTAssertEqual(encrypted, .locked(encrypted: true))
        XCTAssertEqual(E2ESMSPush.notification(for: encrypted),
                       E2ESMSPush.Notification(title: "AirSIM", body: "解锁 iPhone 后，在 AirSIM 中查看这条短信",
                                               threadIdentifier: nil))
        let plaintext = E2ESMSPush.open(plaintextPush(agentID: "android-A"), store: locked)
        XCTAssertEqual(plaintext, .locked(encrypted: false))
        XCTAssertNil(E2ESMSPush.notification(for: plaintext))
    }

    func testUndecryptableOutcomes() throws {
        var malformed = try vectorPush()
        malformed["e2e"] = ["v": 1]
        var noAgent = try vectorPush()
        noAgent["agent_id"] = nil
        var noDelivery = try vectorPush()
        noDelivery["delivery_id"] = ""
        let otherDevice = MemoryE2EKeyStore(["android-A": E2EKeyRecord(key: Data(0..<32), deviceID: "iphone-other")])
        let cases: [(String, [AnyHashable: Any], MemoryE2EKeyStore)] = [
            ("no record", try vectorPush(), MemoryE2EKeyStore()),
            ("other device_id", try vectorPush(), otherDevice),
            ("malformed envelope", malformed, vectorStore()),
            ("missing agent_id", noAgent, vectorStore()),
            ("empty delivery_id", noDelivery, vectorStore()),
            ("keychain unavailable", try vectorPush(), MemoryE2EKeyStore(failure: .unavailable)),
        ]
        for (name, push, store) in cases {
            let outcome = E2ESMSPush.open(push, store: store)
            XCTAssertEqual(outcome, .undecryptable, name)
            XCTAssertEqual(E2ESMSPush.notification(for: outcome), failureCopy, name)
        }
    }

    func testPlaintextFromKeyedAgentIsForged() {
        let outcome = E2ESMSPush.open(plaintextPush(agentID: "android-A"), store: vectorStore())
        XCTAssertEqual(outcome, .unencryptedFromEncryptedAgent)
        XCTAssertEqual(E2ESMSPush.notification(for: outcome),
                       E2ESMSPush.Notification(title: "AirSIM", body: "收到一条未加密的短信推送，已忽略",
                                               threadIdentifier: nil))
    }

    func testUnavailableKeychainKeepsPlaintextPath() {
        // Builds without the shared group never sent a key, so their plaintext stays as today.
        let outcome = E2ESMSPush.open(plaintextPush(agentID: "android-A"), store: MemoryE2EKeyStore(failure: .unavailable))
        XCTAssertEqual(outcome, .plaintext)
        XCTAssertNil(E2ESMSPush.notification(for: outcome))
    }

    func testPlaintextWithoutAgentOrKeyIsLegacy() {
        XCTAssertEqual(E2ESMSPush.open(plaintextPush(agentID: nil), store: vectorStore()), .plaintext)
        XCTAssertEqual(E2ESMSPush.open(plaintextPush(agentID: "android-B"), store: vectorStore()), .plaintext)
    }

    func testOtherEventsIgnored() throws {
        var call = try vectorPush()
        call["event"] = "incoming_call"
        XCTAssertEqual(E2ESMSPush.open(call, store: vectorStore()), .notSMS)
        XCTAssertEqual(E2ESMSPush.open([:], store: vectorStore()), .notSMS)
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
                XCTAssertEqual($0 as? E2EKeyStoreError, .unavailable)
            }
            XCTAssertThrowsError(try store.save(E2EKeyRecord(key: Data(0..<32), deviceID: "iphone-air"),
                                                agentID: "android-A")) {
                XCTAssertEqual($0 as? E2EKeyStoreError, .unavailable)
            }
        }
    }

    // MARK: - Helpers

    private func vectorEnvelope() throws -> E2ESMS.Envelope {
        try XCTUnwrap(E2ESMS.Envelope(json(envelopeJSON())))
    }

    private func vectorStore() -> MemoryE2EKeyStore {
        MemoryE2EKeyStore(["android-A": E2EKeyRecord(key: Data(0..<32), deviceID: "iphone-air")])
    }

    /// The Relay's encrypted SMS push (13f0c41 `encryptedSMSPayload`) carrying the Node vector.
    private func vectorPush() throws -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["title": "AirSIM", "body": "新短信"], "sound": "default",
                    "thread-id": "airsim-sms-agent-android-A", "content-available": 1, "mutable-content": 1],
            "event": "incoming_sms", "delivery_id": vectorDelivery, "agent_id": "android-A",
            "timestamp": "2026-11-03T08:00:00Z", "e2e": try json(envelopeJSON()),
        ]
    }

    /// An encrypted push for `plaintextJSON`, sealed with the vector key for iphone-air / android-A.
    private func sealedPush(_ plaintextJSON: String) throws -> [AnyHashable: Any] {
        var push = try vectorPush()
        push["delivery_id"] = "android-sms-test"
        push["e2e"] = try json(sealedEnvelopeJSON(plaintextJSON, key: vectorKey, deviceID: "iphone-air",
                                                  agentID: "android-A", deliveryID: "android-sms-test"))
        return push
    }

    /// The Relay's plaintext SMS push; `agentID` nil leaves the field out like old agents.
    private func plaintextPush(agentID: String?) -> [AnyHashable: Any] {
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

    private func open(_ envelope: E2ESMS.Envelope, deviceID: String = "iphone-air",
                      agentID: String = "android-A", deliveryID: String? = nil) throws -> E2ESMS.Plaintext {
        try E2ESMS.open(envelope, key: vectorKey, deviceID: deviceID, agentID: agentID,
                        deliveryID: deliveryID ?? vectorDelivery)
    }

    /// Raw JSON text of an envelope; `v` is inserted as JSON, the other fields as string contents.
    private func envelopeJSON(v: String = "1", kid: String = "3946e215", n: String = "oKGio6Slpqeoqaqr",
                              ct: String? = nil) -> String {
        #"{"v":\#(v),"kid":"\#(kid)","n":"\#(n)","ct":"\#(ct ?? vectorCT)"}"#
    }

    /// Seals `plaintext` the way Android does (issue #24), for cases the Node vector does not cover.
    private func sealedEnvelopeJSON(_ plaintext: String, key: SymmetricKey, deviceID: String, agentID: String,
                                    deliveryID: String) throws -> String {
        let aad = Data("AirSIM-E2E/v1|incoming_sms|\(deviceID)|\(agentID)|\(deliveryID)".utf8)
        let nonce = Data(repeating: 7, count: 12)
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: E2ESMS.subkey(key, purpose: "sms-in"),
                                   nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        func url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return #"{"v":1,"kid":"\#(E2ESMS.kid(of: key))","n":"\#(url(nonce))","ct":"\#(url(box.ciphertext + box.tag))"}"#
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
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

    func canStore() -> Bool { failure == nil }
}
