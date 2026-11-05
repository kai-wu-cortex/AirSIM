import CryptoKit
import Foundation

/// End-to-end encrypted cloud SMS (issue #24, phase 1). The iPhone creates the key at pairing and
/// sends it only inside the sealed pairing claim; Android encrypts each SMS with a subkey of it and
/// the Relay forwards the envelope without being able to read it.
///
/// Compiled into the app and the Notification Service Extension, so Foundation and CryptoKit only.
enum E2ESMS {
    /// The `e2e` field of an encrypted `incoming_sms` push, accepted exactly as the Relay accepts it.
    struct Envelope: Equatable {
        let v: Int
        let kid: String
        let n: String
        let ct: String

        init?(_ value: Any?) {
            guard let object = value as? [String: Any],
                  let version = object["v"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  let kid = object["kid"] as? String, kid.utf8.count == 8, kid.utf8.allSatisfy(Self.isLowerHex),
                  let n = object["n"] as? String, n.utf8.count == 16, E2ESMS.data(base64URL: n)?.count == 12,
                  let ct = object["ct"] as? String, (23...8192).contains(ct.utf8.count),
                  let sealed = E2ESMS.data(base64URL: ct), sealed.count >= 17 else { return nil }
            v = 1
            self.kid = kid
            self.n = n
            self.ct = ct
        }

        private static func isLowerHex(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// What Android sealed. The display time comes from the push, not from `timestamp`.
    struct Plaintext: Decodable, Equatable {
        let sender: String
        let content: String
        let timestamp: String
        let truncated: Bool
        /// The receiving SIM ("SIM 1"), which plaintext pushes carry in clear. Older Android
        /// builds leave it out.
        var simSlot: String? = nil

        enum CodingKeys: String, CodingKey {
            case sender, content, timestamp, truncated
            case simSlot = "sim_slot"
        }
    }

    enum Failure: Error, Equatable {
        /// The envelope was sealed with another key (one side re-paired).
        case keyMismatch
        case undecryptable
    }

    private static let label = "AirSIM-E2E/v1"

    static func newKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func subkey(_ key: SymmetricKey, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(count: 32),
                               info: Data("\(label)/\(purpose)".utf8), outputByteCount: 32)
    }

    static func kid(of key: SymmetricKey) -> String {
        subkey(key, purpose: "kid").withUnsafeBytes { bytes in
            bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func open(_ envelope: Envelope, key: SymmetricKey, deviceID: String, agentID: String,
                     deliveryID: String) throws -> Plaintext {
        guard envelope.kid == kid(of: key) else { throw Failure.keyMismatch }
        guard let nonce = data(base64URL: envelope.n), let sealed = data(base64URL: envelope.ct),
              sealed.count > 16 else { throw Failure.undecryptable }
        // Binds the ciphertext to this iPhone, this Android and this message.
        let aad = Data("\(label)|incoming_sms|\(deviceID)|\(agentID)|\(deliveryID)".utf8)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            let plaintext = try AES.GCM.open(box, using: subkey(key, purpose: "sms-in"), authenticating: aad)
            return try JSONDecoder().decode(Plaintext.self, from: plaintext)
        } catch {
            throw Failure.undecryptable
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes canonical unpadded base64url only. Other alphabets, padding, impossible lengths and
    /// nonzero unused bits are rejected, as the Relay rejects them.
    static func data(base64URL text: String) -> Data? {
        guard text.utf8.allSatisfy(isBase64URL) else { return nil }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64URL(data) == text else { return nil }
        return data
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }
}
