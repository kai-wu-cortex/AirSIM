import CryptoKit
import Foundation

/// When a pairing creates an end-to-end encrypted SMS key (issue #24).
enum E2EPairingPolicy {
    /// Only a cloud pairing whose Relay forwards encrypted SMS, and whose keychain group the
    /// Notification Service Extension can read, gets a key. The Android must also advertise
    /// support before the key goes into the claim.
    static func offer(localOnly: Bool, relaySupports: Bool, keychainReady: Bool) -> Bool {
        !localOnly && relaySupports && keychainReady
    }

    /// Android keeps one key per (iPhone, Relay) and sends plaintext through a Relay it has no key
    /// for. A key kept here would refuse that plaintext as forged, so a Relay change drops the keys
    /// until a pairing through the new Relay sends a fresh one.
    static func relayChanged(from old: String, to new: String, store: any E2EKeyStoring) {
        guard old != new else { return }
        store.removeAll()
    }
}

/// What a successful claim does to the agent's stored key. Applied only when the pairing's VoWLAN
/// credential is committed, i.e. once the Android has proved its identity.
enum E2EPairingKeyChange: Equatable, Sendable {
    case save(E2EKeyRecord)
    case remove

    /// nil for a local-only pairing, which leaves the cloud key alone. Android replaces its key on
    /// every cloud pairing and deletes it when a cloud pairing carries none, so the iPhone does too.
    static func after(localOnly: Bool, sentKey: SymmetricKey?, deviceID: String) -> E2EPairingKeyChange? {
        guard !localOnly else { return nil }
        guard let sentKey else { return .remove }
        return .save(E2EKeyRecord(key: sentKey.withUnsafeBytes { Data($0) }, deviceID: deviceID))
    }

    /// The pairing result names a committed change: the key that was sent is the one stored, or a
    /// cloud pairing without a key removed the one this Android had (never silently).
    func resultSuffix(agentID: String, hadKey: Bool, store: any E2EKeyStoring = KeychainE2EKeyStore.shared) -> String {
        let stored = try? store.record(agentID: agentID)
        switch self {
        case .save(let record): return stored == record ? "，云端短信已加密" : ""
        case .remove: return hadKey && stored == nil ? "，云端短信加密已关闭" : ""
        }
    }

    /// A Bonjour pairing still waiting for the signed health check: Android already encrypts with
    /// the new key, which the iPhone keeps only in memory until then.
    static func waitingMessage(keySent: Bool) -> String {
        "加密配对已写入安卓，正在等待通话网关身份验证；暂未建立可用路由。"
            + (keySent ? "短信钥匙会在验证通过后保存，期间请保持 AirSIM 打开。" : "")
    }
}

/// A `capabilities` object from `/pair/v1/info` or the Relay's `/healthz`. Values that are not
/// integers are ignored, and an unexpected shape never fails the response that carries it.
struct CapabilityFlags: Decodable, Equatable {
    let values: [String: Int]

    var e2eSMS: Bool { values["e2e_sms"] == 1 }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: Key.self) else {
            values = [:]
            return
        }
        var values: [String: Int] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Int.self, forKey: key) { values[key.stringValue] = value }
        }
        self.values = values
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
