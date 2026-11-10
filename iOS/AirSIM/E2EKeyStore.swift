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
    /// A corrupt record or another keychain error; never a signal to accept plaintext.
    case unavailable
    /// This build has no usable shared entitlement and cannot have negotiated a key.
    case unconfigured
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
        guard let accessGroup else { throw E2EKeyStoreError.unconfigured }
        guard !account.isEmpty else { throw E2EKeyStoreError.unavailable }
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
        case errSecMissingEntitlement: throw E2EKeyStoreError.unconfigured
        default: throw E2EKeyStoreError.unavailable
        }
    }
}

// Shared diagnostic metadata only: never SMS contents, numbers, keys or push tokens.
import Darwin
import CryptoKit

enum AirSIMHealthStore {
    struct Failure: Codable, Equatable, Identifiable {
        let id: String
        let agentID: String?
        var date: Date
        var reason: String
        var resolved: Bool = false
    }
    struct Snapshot: Codable {
        var lastAlert: Date?
        var lastVoIP: Date?
        var deviceNames: [String: String]?
        var failures: [Failure] = []
    }
    private static func query(_ account: String) -> [String: Any]? {
        guard let group = KeychainE2EKeyStore.shared.accessGroup else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "airsim.push-health.v1",
                kSecAttrAccessGroup as String: group, kSecAttrAccount as String: account]
    }
    private static func keychainData(_ account: String) -> Data? {
        guard var q = query(account) else { return nil }
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func load(from directory: URL? = nil) -> Snapshot {
        let data = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("metadata.json")) }
            ?? (directory == nil ? keychainData("metadata") : nil)
        guard let data, data.count < 100_000,
              let value = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return value
    }
    static func update(in directory: URL? = nil, _ action: (inout Snapshot) -> Void) {
        if let folder = directory {
            let fd = Darwin.open(folder.appendingPathComponent("metadata.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return }
            defer { flock(fd, LOCK_UN); Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { return }
            var value = load(from: folder); action(&value)
            value.failures = Array(value.failures.sorted { $0.date > $1.date }.prefix(60))
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
            return
        }
        // The existing shared Keychain entitlement also works in the notification extension.
        // An expiring lock serializes read-modify-write across the two processes.
        guard var lock = query("metadata-lock") else { return }
        let lockValue = Date().timeIntervalSince1970
        lock[kSecValueData as String] = Data(String(lockValue).utf8)
        lock[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var acquired = false
        for _ in 0..<50 {
            let status = SecItemAdd(lock as CFDictionary, nil)
            if status == errSecSuccess { acquired = true; break }
            guard status == errSecDuplicateItem else { return }
            if let old = keychainData("metadata-lock"), let text = String(data: old, encoding: .utf8),
               let stamp = Double(text), Date().timeIntervalSince1970 - stamp > 10,
               let q = query("metadata-lock") { SecItemDelete(q as CFDictionary) }
            usleep(1_000)
        }
        guard acquired else { return }
        defer { if let q = query("metadata-lock") { SecItemDelete(q as CFDictionary) } }
        var value = load(); action(&value)
        value.failures = Array(value.failures.sorted { $0.date > $1.date }.prefix(60))
        guard let data = try? JSONEncoder().encode(value), var q = query("metadata") else { return }
        let result = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }
    static func registerDevices(_ devices: [String: String]) {
        update { $0.deviceNames = devices.mapValues { String($0.prefix(80)) } }
    }
    static func received(voip: Bool = false) {
        update { if voip { $0.lastVoIP = Date() } else { $0.lastAlert = Date() } }
    }
    static func sms(_ info: [AnyHashable: Any], outcome: E2ESMSPush.Outcome,
                    store: any E2EKeyStoring) {
        guard info["event"] as? String == "incoming_sms" else { return }
        let agent = (info["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let delivery = info["delivery_id"] as? String ?? "missing-delivery"
        let id = SHA256.hash(data: Data("\(agent ?? "unknown")\n\(delivery)".utf8)).map { String(format: "%02x", $0) }.joined()
        var reason: String?
        switch outcome {
        case .undecryptable:
            reason = "加密短信无法验证，请重新配对；可连接安卓同步本地短信"
            if let agent, let record = try? store.record(agentID: agent),
               let envelope = E2ESMS.Envelope(info["e2e"]), record.key.count == 32,
               envelope.kid != E2ESMS.kid(of: SymmetricKey(data: record.key)) {
                reason = "两端短信密钥不匹配，请重新配对此设备"
            }
        case .locked: reason = "首次解锁前无法读取短信密钥；解锁后打开 App 重试本地同步"
        case .unencryptedFromEncryptedAgent: reason = "已协商加密的设备发来未加密推送，已拒绝，请检查此设备配对"
        case .decrypted:
            update { value in
                if let i = value.failures.firstIndex(where: { $0.id == id }) { value.failures[i].resolved = true }
            }
            return
        case .notSMS, .plaintext: return
        }
        guard let reason else { return }
        update { value in
            guard !value.failures.contains(where: { $0.id == id }) else { return }
            value.failures.append(.init(id: id, agentID: agent, date: Date(), reason: reason))
        }
    }
    static func clearHistory() { update { $0.failures.removeAll() } }
}
