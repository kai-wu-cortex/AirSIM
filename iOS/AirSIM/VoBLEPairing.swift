import CryptoKit
import Foundation
import Security

enum VoBLEPairingError: Error, Equatable {
    case invalidKey
    case invalidNonce
    case invalidTranscript
    case confirmationFailed
    case expired
    case replayed
    case revoked
    case keychain(OSStatus)
}

struct VoBLEPairingTranscript: Equatable, Sendable {
    static let protocolVersion = Data([1])

    let androidIdentity: String
    let androidPublicKey: Data
    let iphonePublicKey: Data
    let androidNonce: Data
    let iphoneNonce: Data

    var encoded: Data {
        var output = Data()
        for field in [
            Self.protocolVersion, Data(androidIdentity.utf8), androidPublicKey,
            iphonePublicKey, androidNonce, iphoneNonce,
        ] {
            output.append(UInt8(truncatingIfNeeded: field.count >> 8))
            output.append(UInt8(truncatingIfNeeded: field.count))
            output.append(field)
        }
        return output
    }

    func validate() throws {
        guard !androidIdentity.isEmpty, androidIdentity.utf8.count <= Int(UInt16.max),
              androidPublicKey.count == 32, iphonePublicKey.count == 32,
              androidNonce.count == 32, iphoneNonce.count == 32 else {
            throw VoBLEPairingError.invalidTranscript
        }
    }
}

struct VoBLEPairingMaterial: Equatable, Sendable {
    let pairingKey: Data
    let sas: String
}

struct VoBLESessionKeys: Equatable, Sendable {
    let control: Data
    let media: Data
    let reconnect: Data
}

enum VoBLESessionAuthenticator {
    private static let prefix = "AirSIM/VoBLE/v1/"

    static func derivePairing(
        privateKey: Data,
        peerPublicKey: Data,
        transcript: VoBLEPairingTranscript
    ) throws -> VoBLEPairingMaterial {
        try transcript.validate()
        guard privateKey.count == 32, peerPublicKey.count == 32 else {
            throw VoBLEPairingError.invalidKey
        }
        let local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try local.sharedSecretFromKeyAgreement(with: peer)
        let salt = Data(SHA256.hash(data: transcript.encoded))
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt,
            sharedInfo: Data("\(prefix)pairing".utf8), outputByteCount: 32
        )
        let pairingKey = key.data
        let sasDigest = HMAC<SHA256>.authenticationCode(
            for: Data("\(prefix)sas".utf8) + transcript.encoded,
            using: SymmetricKey(data: pairingKey)
        )
        let sasNumber = Data(sasDigest).prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        } % 1_000_000
        return VoBLEPairingMaterial(
            pairingKey: pairingKey,
            sas: String(format: "%06u", sasNumber)
        )
    }

    static func deriveSessionKeys(
        pairingKey: Data,
        sessionID: Data,
        callID: String,
        generation: UInt64
    ) throws -> VoBLESessionKeys {
        guard pairingKey.count == 32, !sessionID.isEmpty, sessionID.count <= Int(UInt16.max),
              callID.utf8.count <= Int(UInt16.max) else {
            throw VoBLEPairingError.invalidKey
        }
        var context = Data()
        context.appendLengthPrefixed(sessionID)
        context.appendLengthPrefixed(Data(callID.utf8))
        var bigEndianGeneration = generation.bigEndian
        withUnsafeBytes(of: &bigEndianGeneration) { context.append(contentsOf: $0) }
        let salt = Data(SHA256.hash(data: context))
        let source = SymmetricKey(data: pairingKey)
        func derive(_ label: String) -> Data {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: source, salt: salt,
                info: Data("\(prefix)\(label)".utf8), outputByteCount: 32
            ).data
        }
        return VoBLESessionKeys(
            control: derive("control"), media: derive("media"),
            reconnect: derive("reconnect")
        )
    }

    static func tag(message: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw VoBLEPairingError.invalidKey }
        return Data(HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: key)
        )).prefix(16)
    }

    static func authenticate(message: Data, tag: Data, key: Data) -> Bool {
        guard let expected = try? self.tag(message: message, key: key),
              expected.count == tag.count else { return false }
        return zip(expected, tag).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func reconnectTag(
        pairingKey: Data,
        transcript: VoBLEPairingTranscript
    ) throws -> Data {
        try transcript.validate()
        return try tag(
            message: Data("\(prefix)reconnect".utf8) + transcript.encoded,
            key: pairingKey
        )
    }

    static func confirmationTag(pairingKey: Data, challengeID: String) throws -> Data {
        guard !challengeID.isEmpty else { throw VoBLEPairingError.confirmationFailed }
        return try tag(
            message: Data("\(prefix)ready\(challengeID)".utf8),
            key: pairingKey
        )
    }
}

struct VoBLEReplayWindow: Sendable {
    private let maximumAge: TimeInterval
    private let capacity: Int
    private var order: [Data] = []
    private var observed: Set<Data> = []
    private var revoked = false

    init(maximumAge: TimeInterval = 30, capacity: Int = 256) {
        self.maximumAge = maximumAge
        self.capacity = max(1, capacity)
    }

    mutating func accept(nonce: Data, timestamp: Date, now: Date = Date()) -> Bool {
        guard !revoked, !nonce.isEmpty,
              timestamp >= now.addingTimeInterval(-maximumAge),
              timestamp <= now.addingTimeInterval(5),
              !observed.contains(nonce) else { return false }
        observed.insert(nonce)
        order.append(nonce)
        if order.count > capacity {
            observed.remove(order.removeFirst())
        }
        return true
    }

    mutating func revoke() {
        revoked = true
        order.removeAll(keepingCapacity: false)
        observed.removeAll(keepingCapacity: false)
    }
}

struct VoBLEStoredPeer: Codable, Equatable, Sendable {
    let identity: String
    let pairingKey: Data
    let createdAt: Date
}

protocol VoBLEPairingStoring: Sendable {
    func save(_ peer: VoBLEStoredPeer) throws
    func load(identity: String) throws -> VoBLEStoredPeer?
    func revoke(identity: String) throws
}

final class VoBLEPairingStore: VoBLEPairingStoring, @unchecked Sendable {
    private let service: String

    init(service: String = "com.eric3u.airsim.voble") {
        self.service = service
    }

    func save(_ peer: VoBLEStoredPeer) throws {
        let data = try JSONEncoder().encode(peer)
        SecItemDelete(query(account: peer.identity) as CFDictionary)
        var attributes = query(account: peer.identity)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VoBLEPairingError.keychain(status) }
    }

    func load(identity: String) throws -> VoBLEStoredPeer? {
        var request = query(account: identity)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VoBLEPairingError.keychain(status)
        }
        return try JSONDecoder().decode(VoBLEStoredPeer.self, from: data)
    }

    func revoke(identity: String) throws {
        let status = SecItemDelete(query(account: identity) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoBLEPairingError.keychain(status)
        }
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}

private extension Data {
    mutating func appendLengthPrefixed(_ field: Data) {
        append(UInt8(truncatingIfNeeded: field.count >> 8))
        append(UInt8(truncatingIfNeeded: field.count))
        append(field)
    }
}
