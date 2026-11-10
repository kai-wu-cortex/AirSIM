import Foundation
import CryptoKit

/// 负责保存手机本地的通话记录和短信，不依赖模块是否在线。
final class LocalHistoryStore {
    // Background push persistence and the foreground model use separate store instances.
    private static let messageLock = NSRecursiveLock()
    private struct AttentionState: Codable {
        var readMessages: Set<String> = []
        var legacyReadMessages: Set<String> = []
        var seenCalls: Set<String> = []
        mutating func read(_ messages: [SMSMessage]) {
            for message in messages where !message.isOutgoing {
                readMessages.formUnion(LocalHistoryStore.visibilityKeys(message))
                if message.deliveryID?.isEmpty != false {
                    legacyReadMessages.formUnion(LocalHistoryStore.deletionKeys(message))
                }
            }
        }
    }
    private struct MessageState: Codable {
        var messages: [SMSMessage]
        var deletedKeys: Set<String>
        // Genuine no-ID deletions also suppress the same old SMS after an Agent adds delivery IDs.
        var legacyDeletedKeys: Set<String>? = nil
        // Migrated read state commits atomically with scoped records and tombstones.
        var migratedReadKeys: Set<String>? = nil
        // Hash of legacy delivery ID -> proven owner. Used only while the
        // current directory still confirms that unique producer.
        var legacyAliasOwners: [String: String]? = nil
        // Deliveries received without a unique producer remain ambiguous even
        // if the user later removes/re-pairs devices and the directory shrinks.
        var ambiguousLegacyKeys: Set<String>? = nil
    }
    private let fileManager: FileManager
    private let directoryURL: URL
    private let callHistoryURL: URL
    private let messagesURL: URL
    private let attentionURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let durableRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let resolvedDirectoryURL = directoryURL
            ?? durableRoot.appendingPathComponent("AirSIM", isDirectory: true)
        self.directoryURL = resolvedDirectoryURL
        callHistoryURL = resolvedDirectoryURL.appendingPathComponent("call-history.json")
        messagesURL = resolvedDirectoryURL.appendingPathComponent("messages.json")
        attentionURL = resolvedDirectoryURL.appendingPathComponent("history-attention.json")

        do {
            try fileManager.createDirectory(
                at: resolvedDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            // 本地缓存不能阻塞通话和短信；后续写入失败时仍会继续记录日志。
            Self.log("创建本地历史目录失败：\(error.localizedDescription)")
        }
    }

    func loadCallHistory() -> [CallRecord] {
        load(CallRecord.self, from: callHistoryURL) ?? []
    }

    func loadMessages() -> [SMSMessage] { messageSnapshot() ?? [] }

    /// nil denotes unreadable storage; an empty array is a valid empty inbox.
    func messageSnapshot() -> [SMSMessage]? {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        return readMessageState()?.messages
    }

    @discardableResult
    func saveCallHistory(_ records: [CallRecord]) -> Bool {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        _ = readAttentionState() // Migrate old history before inserting new records.
        return save(records, to: callHistoryURL)
    }

    struct SMSIngestion {
        let messages: [SMSMessage]
        let newMessages: [SMSMessage]
        let acceptedMessageIDs: Set<String>
        let changed: Bool
    }

    /// The caller holds a current pairing snapshot across this synchronous transaction.
    /// Unknown records gain a scope only beside a matching authenticated delivery.
    func ingestMessages(_ records: [SMSMessage], legacySourceAgentID: String? = nil,
                        recordAmbiguity: Bool = true) -> SMSIngestion? {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        let attention = readAttentionState()
        guard var state = readMessageState() else { return nil }
        let before = state.messages
        let combined = state.messages + records
        if recordAmbiguity && legacySourceAgentID == nil {
            for message in records where message.sourceAgentID?.isEmpty != false && message.deliveryID?.isEmpty == false {
                state.ambiguousLegacyKeys = (state.ambiguousLegacyKeys ?? []).union(Self.visibilityKeys(message))
            }
        }
        var scopedDeliveries = Set<String>()
        if let source = legacySourceAgentID, !source.isEmpty, attention != nil,
           !combined.contains(where: { $0.sourceAgentID?.isEmpty == false && $0.sourceAgentID != source }) {
            for message in combined where !message.isOutgoing {
                guard let id = message.deliveryID, !id.isEmpty else { continue }
                var legacy = message; legacy.sourceAgentID = nil
                let key = Self.visibilityKeys(legacy).first!
                guard !(state.ambiguousLegacyKeys ?? []).contains(key) else { continue }
                let previousOwner = state.legacyAliasOwners?[key]
                guard previousOwner == nil || previousOwner == source else { continue }
                if message.sourceAgentID == source || previousOwner == source {
                    scopedDeliveries.insert(id)
                    var aliases = state.legacyAliasOwners ?? [:]
                    aliases[key] = source
                    state.legacyAliasOwners = aliases
                }
            }
        }
        func canonical(_ message: SMSMessage) -> SMSMessage {
            var copy = message
            if !copy.isOutgoing, copy.sourceAgentID?.isEmpty != false,
               let id = copy.deliveryID, scopedDeliveries.contains(id) { copy.sourceAgentID = legacySourceAgentID }
            return copy
        }
        // Include deleted/read legacy records even when their bodies are no longer stored.
        // Only the exact stable delivery key is transferred, never a content fingerprint.
        for message in combined where message.sourceAgentID == legacySourceAgentID && !message.isOutgoing {
            guard let id = message.deliveryID, scopedDeliveries.contains(id) else { continue }
            var legacy = message; legacy.sourceAgentID = nil
            if !Self.visibilityKeys(legacy).isDisjoint(with: state.deletedKeys) {
                state.deletedKeys.formUnion(Self.visibilityKeys(message))
            }
            if let attention, !Self.visibilityKeys(legacy).isDisjoint(with: attention.readMessages) {
                state.migratedReadKeys = (state.migratedReadKeys ?? []).union(Self.visibilityKeys(message))
            }
        }
        let oldIDs = Set(state.messages.map { canonical($0).id })
        let normalized = records.map(canonical)
        state.messages = Array(SMSHistoryPolicy.deduplicated(combined.map(canonical))
            .filter { Self.isVisible($0, in: state) }.sorted { $0.timestamp > $1.timestamp }.prefix(2_000))
        let retained = Set(state.messages.map(\.id))
        let accepted = Set(zip(records, normalized).compactMap { original, mapped in
            retained.contains(mapped.id) || !Self.isVisible(mapped, in: state) ? original.id : nil
        })
        guard writeMessageState(state) else { return nil }
        let delivered = Set(normalized.map(\.id))
        return SMSIngestion(messages: state.messages,
            newMessages: state.messages.filter { delivered.contains($0.id) && !oldIDs.contains($0.id) },
            acceptedMessageIDs: accepted, changed: before != state.messages)
    }

    @discardableResult
    func saveMessages(_ records: [SMSMessage]) -> Bool { ingestMessages(records, recordAmbiguity: false) != nil }

    func visibleMessages(_ records: [SMSMessage]) -> [SMSMessage] {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard let state = readMessageState() else { return [] }
        return records.filter { Self.isVisible($0, in: state) }
    }

    @discardableResult
    func deleteMessages(ids: Set<String>, from records: [SMSMessage]) -> Bool {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard var state = readMessageState() else { return false }
        let requested = (records + state.messages).filter { ids.contains($0.id) }
        for message in requested + Self.migratedActionTargets(requested, in: state) {
            state.deletedKeys.formUnion(Self.deletionKeys(message))
            if message.deliveryID?.isEmpty != false {
                state.legacyDeletedKeys = (state.legacyDeletedKeys ?? []).union(Self.deletionKeys(message))
            }
        }
        state.messages = state.messages.filter { Self.isVisible($0, in: state) }
            .sorted { $0.timestamp > $1.timestamp }
        return writeMessageState(state)
    }

    /// A UI action may have captured the legacy row before a background migration.
    /// Do not alias a legacy row that is still present: it may be another producer.
    private static func migratedActionTargets(_ records: [SMSMessage], in state: MessageState) -> [SMSMessage] {
        records.compactMap { message in
            guard message.sourceAgentID?.isEmpty != false, message.deliveryID?.isEmpty == false,
                  !state.messages.contains(where: { $0.id == message.id }),
                  let key = visibilityKeys(message).first, !(state.ambiguousLegacyKeys ?? []).contains(key),
                  let source = state.legacyAliasOwners?[key] else { return nil }
            var scoped = message; scoped.sourceAgentID = source
            return state.messages.first { $0.id == scoped.id }
        }
    }

    private static func deletionKeys(_ message: SMSMessage) -> Set<String> {
        // Hash legacy fingerprints: an SMS id can itself contain the number and complete body.
        let legacy = message.scopedIdentity("\(message.sender)\u{0}\(Int64(message.timestamp.timeIntervalSince1970.rounded(.down)))\u{0}\(message.content)\u{0}\(message.direction?.rawValue ?? "incoming")")
        return Set([message.id, legacy].map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        })
    }

    private static func attentionCallKey(_ call: CallRecord) -> String {
        let identity = "\(call.sourceAgentID ?? "")\u{0}\(call.androidID ?? call.sourceCallID ?? call.id)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Existing history has no read information: baseline it once, before new
    /// push/local deliveries are saved. Never turn a corrupt file into empty state.
    private func readAttentionState() -> AttentionState? {
        do {
            return try JSONDecoder().decode(AttentionState.self, from: Data(contentsOf: attentionURL))
        } catch CocoaError.fileReadNoSuchFile {
            guard let existingMessages = readMessageState()?.messages else { return nil }
            var state = AttentionState()
            state.read(existingMessages)
            state.seenCalls = Set(loadCallHistory().filter { $0.missed && $0.endedAt != nil }.map(Self.attentionCallKey))
            return writeAttentionState(state) ? state : nil
        } catch { return nil }
    }

    private func writeAttentionState(_ state: AttentionState) -> Bool {
        do {
            try JSONEncoder().encode(state).write(to: attentionURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    func unreadMessageIDs(in records: [SMSMessage]) -> Set<String> {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard let state = readAttentionState() else { return [] }
        let readKeys = state.readMessages.union(readMessageState()?.migratedReadKeys ?? [])
        return Set(SMSHistoryPolicy.deduplicated(records).filter {
            !$0.isOutgoing && Self.visibilityKeys($0).isDisjoint(with: readKeys)
                && Self.deletionKeys($0).isDisjoint(with: state.legacyReadMessages)
        }.map(\.id))
    }

    func unseenMissedCallIDs(in records: [CallRecord]) -> Set<String> {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard let state = readAttentionState() else { return [] }
        return Set(records.filter {
            $0.missed && $0.direction == "incoming" && $0.endedAt != nil
                && !state.seenCalls.contains(Self.attentionCallKey($0))
        }.map(\.id))
    }

    @discardableResult
    func markMessagesRead(_ records: [SMSMessage]) -> Bool {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard var state = readAttentionState() else { return false }
        state.read(records)
        if let messages = readMessageState() { state.read(Self.migratedActionTargets(records, in: messages)) }
        return writeAttentionState(state)
    }

    @discardableResult
    func markMissedCallsSeen(_ records: [CallRecord]) -> Bool {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard var state = readAttentionState() else { return false }
        state.seenCalls.formUnion(records.filter { $0.missed && $0.endedAt != nil }.map(Self.attentionCallKey))
        return writeAttentionState(state)
    }

    private static func visibilityKeys(_ message: SMSMessage) -> Set<String> {
        if let id = message.deliveryID, !id.isEmpty {
            // A different stable delivery ID always denotes a different SMS, even for identical OTPs.
            return [SHA256.hash(data: Data(message.id.utf8)).map { String(format: "%02x", $0) }.joined()]
        }
        return deletionKeys(message)
    }

    private static func isVisible(_ message: SMSMessage, in state: MessageState) -> Bool {
        visibilityKeys(message).isDisjoint(with: state.deletedKeys)
            && deletionKeys(message).isDisjoint(with: state.legacyDeletedKeys ?? [])
    }

    private func readMessageState() -> MessageState? {
        do {
            let data = try Data(contentsOf: messagesURL)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let state = try? decoder.decode(MessageState.self, from: data) { return state }
            return MessageState(messages: try decoder.decode([SMSMessage].self, from: data), deletedKeys: [])
        } catch CocoaError.fileReadNoSuchFile {
            return MessageState(messages: [], deletedKeys: [])
        } catch {
            Self.log("读取短信历史失败；保留文件且不覆盖删除标记")
            return nil
        }
    }

    private func writeMessageState(_ state: MessageState) -> Bool {
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: messagesURL, options: [.atomic])
            return true
        } catch {
            Self.log("写入短信历史失败")
            return false
        }
    }

    private func load<Element: Decodable>(_ type: Element.Type, from url: URL) -> [Element]? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Element].self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Self.log("读取本地历史失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
            return nil
        }
    }

    private func save<Element: Encodable>(_ records: [Element], to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            // 原子写入先生成临时文件再替换目标，避免断电留下半个 JSON 文件。
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            Self.log("写入本地历史失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
            return false
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        print("[AirSIM LocalHistory] \(message)")
#endif
    }
}
