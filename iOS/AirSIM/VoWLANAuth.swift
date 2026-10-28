import CryptoKit
import Foundation
import Security

struct VoWLANCredential: Equatable, Sendable {
    let secret: Data
    /// Server clock minus the local clock at pairing time. Signed requests use
    /// this to avoid a 401 when the two devices are not time-synchronised.
    let clockOffset: TimeInterval

    var encodedSecret: String { secret.base64URL }

    init(secret: Data, clockOffset: TimeInterval = 0) throws {
        guard secret.count >= 32 else { throw VoWLANAuthError.invalidSecret }
        self.secret = secret
        self.clockOffset = clockOffset.isFinite ? clockOffset : 0
    }
    init(encodedSecret: String, clockOffset: TimeInterval = 0) throws {
        let value = encodedSecret.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4)) else {
            throw VoWLANAuthError.invalidSecret
        }
        try self.init(secret: data, clockOffset: clockOffset)
    }
}

struct VoWLANSignedRequest: Equatable, Sendable {
    let timestamp: Int64
    let nonce: String
    let canonical: String
    let signature: String
}

enum VoWLANAuthError: LocalizedError {
    case invalidSecret
    case randomUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSecret: return "VoWLAN 配对密钥无效"
        case .randomUnavailable: return "无法生成 VoWLAN 安全随机数"
        }
    }
}

struct VoWLANRequestSigner: Sendable {
    let credential: VoWLANCredential

    init(secret: Data) throws {
        credential = try VoWLANCredential(secret: secret)
    }

    init(credential: VoWLANCredential) {
        self.credential = credential
    }

    func sign(
        method: String,
        path: String,
        body: Data,
        timestamp: Int64? = nil,
        nonce: String = VoWLANRequestSigner.makeNonce()
    ) throws -> VoWLANSignedRequest {
        guard !nonce.isEmpty else { throw VoWLANAuthError.randomUnavailable }
        let timestamp = timestamp ?? Int64(Date().addingTimeInterval(credential.clockOffset)
            .timeIntervalSince1970)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method.uppercased())\n\(path)\n\(digest)\n\(timestamp)\n\(nonce)"
        let key = SymmetricKey(data: credential.secret)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        return VoWLANSignedRequest(
            timestamp: timestamp,
            nonce: nonce,
            canonical: canonical,
            signature: Data(mac).base64URL
        )
    }

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        return Data(bytes).base64URL
    }
}

enum VoWLANCredentialStore {
    private static let service = "com.example.airsim.vowlan"
    private static let account = "paired-secret-v1"

    static func generate() throws -> VoWLANCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VoWLANAuthError.randomUnavailable
        }
        return try VoWLANCredential(secret: Data(bytes))
    }

    private struct StoredCredential: Codable {
        let secret: String
        let clockOffset: Double?
    }

    private static func encode(_ credential: VoWLANCredential) -> Data {
        let stored = StoredCredential(secret: credential.encodedSecret, clockOffset: credential.clockOffset)
        return (try? JSONEncoder().encode(stored)) ?? credential.secret
    }

    private static func decode(_ data: Data) -> VoWLANCredential? {
        if let stored = try? JSONDecoder().decode(StoredCredential.self, from: data),
           let credential = try? VoWLANCredential(encodedSecret: stored.secret,
                                                  clockOffset: stored.clockOffset ?? 0) {
            return credential
        }
        // Credentials written by older builds are the raw 32-byte secret.
        return try? VoWLANCredential(secret: data)
    }

    private static func deviceAccount(_ agentID: String) -> String {
        "agent-v1-" + SHA256.hash(data: Data(agentID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(agentID: String) -> VoWLANCredential? {
        guard !agentID.isEmpty else { return nil }
        var query = queryWithoutValue()
        query[kSecAttrAccount as String] = deviceAccount(agentID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return decode(data)
    }
    static func save(_ credential: VoWLANCredential, agentID: String) throws {
        guard !agentID.isEmpty else { throw VoWLANAuthError.invalidSecret }
        var query = queryWithoutValue()
        query[kSecAttrAccount as String] = deviceAccount(agentID)
        let payload = encode(credential)
        let update = [kSecValueData as String: payload]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = payload
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw VoWLANAuthError.randomUnavailable }
        } else if status != errSecSuccess { throw VoWLANAuthError.randomUnavailable }
    }
    static func remove(agentID: String) {
        var query = queryWithoutValue()
        query[kSecAttrAccount as String] = deviceAccount(agentID)
        SecItemDelete(query as CFDictionary)
        VoWLANPairingRecordStore.remove(agentID: agentID)
    }
    static func hasAny() -> Bool {
        load() != nil || PairedAndroidDeviceStore.records().contains { load(agentID: $0.id) != nil }
    }

    static func loadOrCreate() throws -> VoWLANCredential {
        if let existing = load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VoWLANAuthError.randomUnavailable
        }
        let credential = try VoWLANCredential(secret: Data(bytes))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(queryWithoutValue() as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw VoWLANAuthError.randomUnavailable
        }
        return credential
    }

    static func load() -> VoWLANCredential? {
        var query = queryWithoutValue()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return decode(data)
    }

    static func remove() {
        SecItemDelete(queryWithoutValue() as CFDictionary)
    }

    private static func queryWithoutValue() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainLocalDeviceCredentials: LocalDeviceCredentialStoring {
    func load(agentID: String) -> VoWLANCredential? { VoWLANCredentialStore.load(agentID: agentID) }
    func save(_ credential: VoWLANCredential, agentID: String) throws { try VoWLANCredentialStore.save(credential, agentID: agentID) }
    func remove(agentID: String) { VoWLANCredentialStore.remove(agentID: agentID) }
    func legacy() -> VoWLANCredential? { VoWLANCredentialStore.load() }
}

enum VoWLANHealthProof {
    static func verifyDial(_ signature: String?, nonce: String, operationID: String,
                           androidID: String, backendID: String, credential: VoWLANCredential) -> Bool {
        guard let signature, !androidID.isEmpty, !backendID.isEmpty else { return false }
        let encoded = signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes,
            authenticating: Data("AIRSIM-DIAL1\n\(nonce)\n\(operationID)\n\(androidID)\n\(backendID)".utf8),
            using: SymmetricKey(data: credential.secret))
    }
    static func verify(_ signature: String?, nonce: String, agentID: String, credential: VoWLANCredential) -> Bool {
        guard let signature, !nonce.isEmpty, !agentID.isEmpty else { return false }
        let encoded = signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let supplied = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(supplied,
            authenticating: Data("AIRSIM-HEALTH1\n\(nonce)\n\(agentID)".utf8), using: SymmetricKey(data: credential.secret))
    }
}

/// Client-side pairing list. The secret itself stays in Keychain; this record
/// only keeps a fingerprint, endpoint history and last-seen time so a VoWLAN ↔
/// Tailscale address change can update one pairing instead of creating a
/// mismatched duplicate.
struct VoWLANPairingRecord: Codable, Equatable, Identifiable, Sendable {
    struct Endpoint: Codable, Equatable, Sendable {
        let host: String
        let controlPort: UInt16
        let pcmPort: UInt16
        var tls: Bool? = nil

        init(_ endpoint: VoWLANEndpoint) {
            host = endpoint.host
            controlPort = endpoint.controlPort
            pcmPort = endpoint.pcmPort
            tls = endpoint.usesTLS ? true : nil
        }

        var endpoint: VoWLANEndpoint? {
            try? VoWLANEndpoint(host: host, controlPort: controlPort, pcmPort: pcmPort, usesTLS: tls == true)
        }
    }

    let id: String
    let agentID: String
    var deviceName: String?
    let createdAt: Date
    var lastSeenAt: Date
    var endpoints: [Endpoint]
}

enum VoWLANPairingRecordStore {
    private static let key = "airsim.vowlan.pairing-records.v1"
    private static let maxEndpoints = 4

    static func pairingID(for credential: VoWLANCredential) -> String {
        SHA256.hash(data: credential.secret).map { String(format: "%02x", $0) }.joined()
    }

    static func records(defaults: UserDefaults = .standard) -> [VoWLANPairingRecord] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([VoWLANPairingRecord].self, from: data) else {
            return []
        }
        return values
            .filter { !$0.id.isEmpty && !$0.agentID.isEmpty }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    static func remember(
        agentID: String,
        credential: VoWLANCredential,
        endpoint: VoWLANEndpoint?,
        deviceName: String?,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        guard !agentID.isEmpty else { return }
        let id = pairingID(for: credential)
        var values = records(defaults: defaults)
        // Keep the previous address history/created time when the same Agent is
        // re-paired with a new secret (secret rotation).
        let previous = values.first { $0.id == id }
            ?? values.first { $0.agentID == agentID }
        // One iPhone uses one active secret per Agent. Re-pairing replaces the
        // stale record for the same Agent instead of leaving both behind.
        values.removeAll { $0.agentID == agentID && $0.id != id }
        var endpoints = previous?.endpoints ?? []
        if let endpoint {
            let next = VoWLANPairingRecord.Endpoint(endpoint)
            endpoints.removeAll { $0 == next }
            endpoints.append(next)
            if endpoints.count > maxEndpoints { endpoints.removeFirst(endpoints.count - maxEndpoints) }
        }
        let record = VoWLANPairingRecord(
            id: id,
            agentID: agentID,
            deviceName: deviceName ?? previous?.deviceName,
            createdAt: previous?.createdAt ?? now,
            lastSeenAt: now,
            endpoints: endpoints
        )
        values.removeAll { $0.id == id }
        values.append(record)
        values.sort { $0.lastSeenAt > $1.lastSeenAt }
        defaults.set(try? JSONEncoder().encode(Array(values.prefix(8))), forKey: key)
    }

    static func remove(agentID: String, defaults: UserDefaults = .standard) {
        let values = records(defaults: defaults).filter { $0.agentID != agentID }
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
