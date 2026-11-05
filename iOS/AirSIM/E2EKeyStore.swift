import Foundation
import Security

/// The E2E SMS key for one Android agent, with the iPhone `device_id` that Android binds into the
/// AAD. Stored as JSON in the keychain, so the coding keys must stay stable across updates.
struct E2EKeyRecord: Codable, Equatable, Sendable {
    let key: Data
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case key
        case deviceID = "device_id"
    }
}

enum E2EKeyStoreError: Error, Equatable {
    /// The keychain cannot be read until the first unlock after a restart.
    case locked
    /// No shared group (an unsigned or re-signed build without Keychain Sharing) or another keychain error.
    case unavailable
}

protocol E2EKeyStoring: Sendable {
    func record(agentID: String) throws -> E2EKeyRecord?
    func save(_ record: E2EKeyRecord, agentID: String) throws
    func remove(agentID: String)
    func removeAll()
    /// Whether a key saved now can also be read by the Notification Service Extension.
    func canStore() -> Bool
}

/// Keeps keys in the keychain group shared with the Notification Service Extension: readable
/// after the first unlock, never synced and never restored to another device.
struct KeychainE2EKeyStore: E2EKeyStoring {
    static let shared = KeychainE2EKeyStore()
    private static let service = "airsim.e2e-sms"

    /// Expands from `$(AppIdentifierPrefix)airsim.e2e-sms` in Info.plist.
    let accessGroup: String?

    init(accessGroup: String? = Bundle.main.object(forInfoDictionaryKey: "AirSIME2EKeychainGroup") as? String) {
        self.accessGroup = accessGroup?.isEmpty == false ? accessGroup : nil
    }

    func record(agentID: String) throws -> E2EKeyRecord? {
        var query = try baseQuery(account: agentID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        guard let data = item as? Data,
              let record = try? JSONDecoder().decode(E2EKeyRecord.self, from: data) else {
            throw E2EKeyStoreError.unavailable
        }
        return record
    }

    func save(_ record: E2EKeyRecord, agentID: String) throws {
        try write(JSONEncoder().encode(record), query: baseQuery(account: agentID))
    }

    func remove(agentID: String) {
        guard let query = try? baseQuery(account: agentID) else { return }
        SecItemDelete(query as CFDictionary)
    }

    func removeAll() {
        guard let accessGroup else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func canStore() -> Bool {
        guard let query = try? baseQuery(account: "probe-\(UUID().uuidString)") else { return false }
        defer { SecItemDelete(query as CFDictionary) }
        return (try? write(Data("probe".utf8), query: query)) != nil
    }

    private func baseQuery(account: String) throws -> [String: Any] {
        guard let accessGroup, !account.isEmpty else { throw E2EKeyStoreError.unavailable }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    private func write(_ payload: Data, query: [String: Any]) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: payload] as CFDictionary)
        guard status == errSecItemNotFound else { return try Self.check(status) }
        var item = query
        item[kSecValueData as String] = payload
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try Self.check(SecItemAdd(item as CFDictionary, nil))
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed: throw E2EKeyStoreError.locked
        default: throw E2EKeyStoreError.unavailable
        }
    }
}
