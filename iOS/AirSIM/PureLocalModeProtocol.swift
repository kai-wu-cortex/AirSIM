import CryptoKit
import Foundation
import Security

enum PureLocalProtocolError: Error { case invalidCommand, invalidSignature, invalidStatus, keyUnavailable, keychain(OSStatus) }

struct PureLocalCommand: Codable, Equatable, Sendable {
    var version: Int = 1
    var agentID: String
    var operationID: String
    var enabled: Bool
    var expectedRevision: UInt64
    var ownerPublicKey: String
    var signature: String

    enum CodingKeys: String, CodingKey {
        case version, enabled, signature
        case agentID = "agent_id", operationID = "operation_id", expectedRevision = "expected_revision", ownerPublicKey = "owner_public_key"
    }
    var canonical: Data { Data("airsim-pure-local-v1\n\(agentID)\n\(operationID)\n\(enabled ? 1 : 0)\n\(expectedRevision)".utf8) }
    var ownerFingerprint: String { Data(SHA256.hash(data: Data(base64Encoded: ownerPublicKey) ?? Data())).map { String(format: "%02x", $0) }.joined() }
    static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil }
    static func validOperation(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil }
    static func signed(agentID: String, operationID: String, enabled: Bool, revision: UInt64, key: Curve25519.Signing.PrivateKey) throws -> Self {
        var command = Self(agentID: agentID, operationID: operationID, enabled: enabled, expectedRevision: revision,
                           ownerPublicKey: key.publicKey.rawRepresentation.base64EncodedString(), signature: "")
        guard validID(agentID), validOperation(operationID), revision <= Int64.max else { throw PureLocalProtocolError.invalidCommand }
        command.signature = try key.signature(for: command.canonical).base64EncodedString()
        return command
    }
    func verify(agentID target: String) throws {
        guard version == 1, agentID == target, Self.validID(agentID), Self.validOperation(operationID), expectedRevision <= Int64.max,
              ownerPublicKey.count == 44, signature.count == 88,
              let publicData = Data(base64Encoded: ownerPublicKey), publicData.count == 32,
              let signatureData = Data(base64Encoded: signature), signatureData.count == 64 else { throw PureLocalProtocolError.invalidCommand }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        guard key.isValidSignature(signatureData, for: canonical) else { throw PureLocalProtocolError.invalidSignature }
    }
}

struct PureLocalStatus: Codable, Equatable, Sendable {
    var version: Int
    var agentID: String
    var enabled: Bool
    var revision: UInt64
    var lastOperationID: String
    var ownerFingerprint: String
    var source: String
    var drained: Bool
    var avfRequired: Bool
    var avfConfirmed: Bool

    enum CodingKeys: String, CodingKey {
        case version, enabled, revision, source, drained
        case agentID = "agent_id", lastOperationID = "last_operation_id", ownerFingerprint = "owner_fingerprint"
        case avfRequired = "avf_required", avfConfirmed = "avf_confirmed"
    }
    var valid: Bool {
        version == 1 && PureLocalCommand.validID(agentID) && revision <= Int64.max &&
        (lastOperationID.isEmpty || PureLocalCommand.validOperation(lastOperationID)) &&
        (ownerFingerprint.isEmpty || ownerFingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil) &&
        ["remote", "android_local"].contains(source)
    }
    // Fixed-order encoding avoids JSON key-order differences across Java/Swift/Go.
    func proof(nonce: String, secret: Data) throws -> String {
        guard valid, !nonce.isEmpty, nonce.utf8.count <= 256, !nonce.contains("\n"), secret.count >= 16 else { throw PureLocalProtocolError.invalidStatus }
        let text = "airsim-pure-local-status-v1\n\(nonce)\n\(version)\n\(agentID)\n\(enabled ? 1 : 0)\n\(revision)\n\(lastOperationID)\n\(ownerFingerprint)\n\(source)\n\(drained ? 1 : 0)\n\(avfRequired ? 1 : 0)\n\(avfConfirmed ? 1 : 0)"
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: secret))).base64EncodedString()
    }
    func verifyProof(_ proof: String, nonce: String, secret: Data) -> Bool {
        guard let expected = try? self.proof(nonce: nonce, secret: secret), let lhs = Data(base64Encoded: expected), let rhs = Data(base64Encoded: proof), lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct PureLocalOwnerKeyStore {
    private let load: () throws -> Data?
    private let save: (Data) throws -> Void
    init(load: @escaping () throws -> Data?, save: @escaping (Data) throws -> Void) { self.load = load; self.save = save }
    func key(allowCreate: Bool) throws -> Curve25519.Signing.PrivateKey {
        if let bytes = try load() { return try .init(rawRepresentation: bytes) }
        guard allowCreate else { throw PureLocalProtocolError.keyUnavailable }
        let key = Curve25519.Signing.PrivateKey()
        try save(key.rawRepresentation)
        return key
    }
    static let keychain = Self(load: {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PureLocalProtocolError.keychain(status) }
        return data
    }, save: { data in
        var query = keyQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        // Never delete an existing identity or overwrite it on lock/race/error.
        guard status == errSecSuccess else { throw PureLocalProtocolError.keychain(status) }
    })
    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AirSIM.PureLocalOwner.v1", kSecAttrAccount as String: "owner"]
    }
}
