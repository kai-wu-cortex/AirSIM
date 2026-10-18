import Foundation
import CryptoKit

/// 负责保存手机本地的通话记录和短信，不依赖模块是否在线。
final class LocalHistoryStore {
    // Background push persistence and the foreground model use separate store instances.
    private static let messageLock = NSRecursiveLock()
    private struct MessageState: Codable {
        var messages: [SMSMessage]
        var deletedKeys: Set<String>
        // Genuine no-ID deletions also suppress the same old SMS after an Agent adds delivery IDs.
        var legacyDeletedKeys: Set<String>? = nil
    }
    private let fileManager: FileManager
    private let directoryURL: URL
    private let callHistoryURL: URL
    private let messagesURL: URL

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

    func loadMessages() -> [SMSMessage] {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        return readMessageState()?.messages ?? []
    }

    @discardableResult
    func saveCallHistory(_ records: [CallRecord]) -> Bool {
        save(records, to: callHistoryURL)
    }

    @discardableResult
    func saveMessages(_ records: [SMSMessage]) -> Bool {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard var state = readMessageState() else { return false }
        // A background push can arrive after another store instance captured its input array.
        // Merge under the lock; deletion is explicit and never inferred from missing records.
        let merged = SMSHistoryPolicy.deduplicated(state.messages + records)
        state.messages = Array(merged.filter { Self.isVisible($0, in: state) }
            .sorted { $0.timestamp > $1.timestamp }.prefix(2_000))
        return writeMessageState(state)
    }

    func visibleMessages(_ records: [SMSMessage]) -> [SMSMessage] {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard let state = readMessageState() else { return [] }
        return records.filter { Self.isVisible($0, in: state) }
    }

    @discardableResult
    func deleteMessages(ids: Set<String>, from records: [SMSMessage]) -> Bool {
        Self.messageLock.lock(); defer { Self.messageLock.unlock() }
        guard var state = readMessageState() else { return false }
        for message in records + state.messages where ids.contains(message.id) {
            state.deletedKeys.formUnion(Self.deletionKeys(message))
            if message.deliveryID?.isEmpty != false {
                state.legacyDeletedKeys = (state.legacyDeletedKeys ?? []).union(Self.deletionKeys(message))
            }
        }
        state.messages = SMSHistoryPolicy.deduplicated(state.messages + records).filter { Self.isVisible($0, in: state) }
            .sorted { $0.timestamp > $1.timestamp }
        return writeMessageState(state)
    }

    private static func deletionKeys(_ message: SMSMessage) -> Set<String> {
        // Hash legacy fingerprints: an SMS id can itself contain the number and complete body.
        let legacy = "\(message.sender)\u{0}\(Int64(message.timestamp.timeIntervalSince1970.rounded(.down)))\u{0}\(message.content)\u{0}\(message.direction?.rawValue ?? "incoming")"
        return Set([message.id, legacy].map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        })
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
