import CryptoKit
import Foundation
import Security

struct VoWLANCredential: Equatable, Sendable {
    let secret: Data

    var encodedSecret: String { secret.base64URL }

    init(secret: Data) throws {
        guard secret.count >= 32 else { throw VoWLANAuthError.invalidSecret }
        self.secret = secret
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

    func sign(
        method: String,
        path: String,
        body: Data,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        nonce: String = VoWLANRequestSigner.makeNonce()
    ) throws -> VoWLANSignedRequest {
        guard !nonce.isEmpty else { throw VoWLANAuthError.randomUnavailable }
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
    private static let service = "com.eric3u.airsim.vowlan"
    private static let account = "paired-secret-v1"

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
            kSecValueData as String: credential.secret,
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
        return try? VoWLANCredential(secret: data)
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

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
