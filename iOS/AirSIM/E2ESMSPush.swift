import CryptoKit
import Foundation

/// Classifies an `incoming_sms` push against the stored E2E SMS keys (issue #24). The app decides
/// what to save from the outcome and the Notification Service Extension what to show.
enum E2ESMSPush {
    enum Outcome: Equatable {
        case notSMS
        /// A plaintext push from an agent without a key: handled exactly as before.
        case plaintext
        case decrypted(E2ESMS.Plaintext)
        /// The keychain cannot be read before the first unlock after a restart.
        case locked(encrypted: Bool)
        case undecryptable
        /// A plaintext push naming an agent whose SMS arrive encrypted: forged or replayed by
        /// whoever can send APNs pushes, so it is neither stored nor shown as an SMS.
        case unencryptedFromEncryptedAgent
    }

    struct Notification: Equatable {
        let title: String
        /// nil keeps the subtitle the push arrived with.
        var subtitle: String? = nil
        let body: String
        /// nil keeps the thread the push arrived with.
        let threadIdentifier: String?
    }

    static func open(_ userInfo: [AnyHashable: Any], store: any E2EKeyStoring) -> Outcome {
        let result = classify(userInfo, store: store)
        AirSIMHealthStore.sms(userInfo, outcome: result, store: store)
        return result
    }
    private static func classify(_ userInfo: [AnyHashable: Any], store: any E2EKeyStoring) -> Outcome {
        guard userInfo["event"] as? String == "incoming_sms" else { return .notSMS }
        let agentID = nonEmpty(userInfo["agent_id"])
        guard userInfo.keys.contains("e2e") else {
            guard let agentID else { return .plaintext }
            do {
                return try store.record(agentID: agentID) == nil ? .plaintext : .unencryptedFromEncryptedAgent
            } catch E2EKeyStoreError.locked {
                return .locked(encrypted: false)
            } catch E2EKeyStoreError.unconfigured {
                return .plaintext
            } catch {
                // A corrupt/unreadable key is not proof that encryption was never enabled.
                return .undecryptable
            }
        }
        // No key can open these, locked keychain or not.
        guard let agentID, let deliveryID = nonEmpty(userInfo["delivery_id"]),
              let envelope = E2ESMS.Envelope(userInfo["e2e"]) else { return .undecryptable }
        let record: E2EKeyRecord?
        do {
            record = try store.record(agentID: agentID)
        } catch E2EKeyStoreError.locked {
            return .locked(encrypted: true)
        } catch {
            return .undecryptable
        }
        guard let record,
              let sms = try? E2ESMS.open(envelope, key: SymmetricKey(data: record.key), deviceID: record.deviceID,
                                         agentID: agentID, deliveryID: deliveryID) else { return .undecryptable }
        return .decrypted(sms)
    }

    static func notification(for outcome: Outcome) -> Notification? {
        switch outcome {
        case .decrypted(let sms):
            let sender = displaySender(sms.sender)
            return Notification(title: sender, subtitle: simSlot(sms.simSlot).map { "接收于 \($0)" } ?? "SIM 未知",
                                body: sms.content, threadIdentifier: thread(for: sender))
        case .undecryptable:
            return Notification(title: "AirSIM", body: "收到一条加密短信，但无法解密，请在同一 Wi-Fi 下重新配对",
                                threadIdentifier: nil)
        case .locked(encrypted: true):
            return Notification(title: "AirSIM", body: "解锁 iPhone 后，在 AirSIM 中查看这条短信", threadIdentifier: nil)
        case .unencryptedFromEncryptedAgent:
            return Notification(title: "AirSIM", body: "收到一条未加密的短信推送，已忽略", threadIdentifier: nil)
        case .notSMS, .plaintext, .locked(encrypted: false):
            return nil
        }
    }

    /// The Relay's sender rule for plaintext pushes.
    static func displaySender(_ sender: String) -> String {
        nonEmpty(sender) ?? "未知号码"
    }

    /// The Relay's SIM slot rule for plaintext pushes: "SIM 1"…"SIM 99", otherwise unknown.
    static func simSlot(_ value: String?) -> String? {
        guard let slot = nonEmpty(value),
              slot.range(of: #"^SIM [1-9][0-9]?$"#, options: .regularExpression) != nil else { return nil }
        return slot
    }

    /// The Relay's thread rule for plaintext pushes ("airsim-sms-<sender>", at most 64 UTF-16
    /// units), so decrypted and plaintext SMS from one sender share a thread.
    private static func thread(for sender: String) -> String {
        var thread = String.UnicodeScalarView()
        var units = 0
        for scalar in "airsim-sms-\(sender)".unicodeScalars {
            units += scalar.utf16.count
            guard units <= 64 else { break }
            thread.append(scalar)
        }
        return String(thread)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
