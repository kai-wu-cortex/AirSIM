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

    /// The pairing result mentions encryption only once the key that was sent is the one stored.
    func successSuffix(agentID: String, store: any E2EKeyStoring = KeychainE2EKeyStore.shared) -> String {
        guard case .save(let record) = self, (try? store.record(agentID: agentID)) == record else { return "" }
        return "，云端短信已加密"
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
