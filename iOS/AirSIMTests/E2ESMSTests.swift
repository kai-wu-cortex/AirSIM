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

    // MARK: - Helpers

    private func vectorEnvelope() throws -> E2ESMS.Envelope {
        try XCTUnwrap(E2ESMS.Envelope(json(envelopeJSON())))
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
