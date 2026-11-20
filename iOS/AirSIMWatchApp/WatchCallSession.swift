import Foundation
import Network
import os
import CryptoKit
import Security
import WatchConnectivity

@MainActor
final class WatchCallSession: NSObject, ObservableObject {
    @Published private(set) var companionReachable = false
    @Published private(set) var smsPage: WatchSMSPage?
    @Published private(set) var smsBusy = false
    @Published private(set) var smsUsingDirect = false
    @Published private(set) var smsShowingCompanionHistory = false
    @Published private(set) var smsShowingCachedHistory = false
    @Published private(set) var confirmedReadSMSKeys = Set<String>()
    private func smsReadKey(_ row: WatchSMSRow) -> String {
        Self.localReadKey(agentID: row.agentID, key: WatchSMSPolicy.readKey(messageID: row.id, deliveryKey: row.deliveryKey))
    }
    private static func localReadKey(agentID: String, key: String) -> String {
        Data(agentID.utf8).base64EncodedString() + "." + key
    }

    private struct ReadReceipt: Codable {
        let agentID: String
        let key: String
        var synced = false
    }
    private static let receiptsKey = "watchSMS.readReceipts.v1"
    private var readReceipts: [ReadReceipt] = []
    private var readSyncBusy = false
    private var readSyncOffset = 0

    private func saveReadReceipts() {
        confirmedReadSMSKeys = Set(readReceipts.map { Self.localReadKey(agentID: $0.agentID, key: $0.key) })
        UserDefaults.standard.set(try? JSONEncoder().encode(readReceipts), forKey: Self.receiptsKey)
    }

    private func syncReadReceipts() async {
        guard !isUIFixture, !readSyncBusy, connectivity?.isReachable == true,
              let agentID = directRoute?.agentID ?? smsPage?.selectedAgentID else { return }
        let pending = readReceipts.filter { !$0.synced && $0.agentID == agentID }.map(\.key)
        guard !pending.isEmpty else { return }
        let start = readSyncOffset % pending.count
        let batch = (0..<min(40, pending.count)).map { pending[(start + $0) % pending.count] }
        readSyncOffset = start + batch.count
        readSyncBusy = true
        defer { readSyncBusy = false }
        guard let reply = try? await companionRequest(["action": "watch_sms_read_batch", "agent_id": agentID,
                                                       "read_keys": batch], timeout: 5),
              let accepted = reply["accepted"] as? [String] else { return }
        let acknowledged = Set(accepted).intersection(batch)
        guard !acknowledged.isEmpty else { return }
        for index in readReceipts.indices where readReceipts[index].agentID == agentID
            && acknowledged.contains(readReceipts[index].key) {
            readReceipts[index].synced = true
        }
        saveReadReceipts()
    }
    func isSMSUnread(_ row: WatchSMSRow) -> Bool { !row.outgoing && row.unread && !confirmedReadSMSKeys.contains(smsReadKey(row)) }
    @Published private(set) var smsError: String?
    private var smsRequestID = UUID()
    private var connectivity: WCSession?
    private var directRoute: WatchSMSDirectRoute?
    private var directInbox: WatchDirectInbox?
    private var directSendInFlight = false
    private var companionHistory: WatchSMSPage?
    private var historyCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "WatchSMSHistory.json")
    }

    private func clearHistory() {
        companionHistory = nil
        smsPage = nil
        readReceipts.removeAll()
        saveReadReceipts()
        try? FileManager.default.removeItem(at: historyCacheURL)
    }

    private func rememberHistory(_ page: WatchSMSPage) {
        guard let agentID = page.selectedAgentID else { clearHistory(); return }
        let rows = WatchSMSPolicy.merged(direct: page.rows, companion: companionHistory?.rows ?? [], agentID: agentID)
        companionHistory = .init(devices: page.devices, selectedAgentID: agentID,
            rows: Array(rows.prefix(120)), total: max(page.total, rows.count), generatedAt: page.generatedAt)
        guard let data = try? JSONEncoder().encode(companionHistory) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: historyCacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var cacheURL = historyCacheURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cacheURL.setResourceValues(values)
    }

    var isUIFixture: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--watch-ui-fixture")
#else
        false
#endif
    }
    private func installUIFixture() {
        companionReachable = true
        let rows = [
            WatchSMSRow(id: "fixture-1", agentID: "fixture-agent", sender: "测试联系人", preview: "这是一条模拟短信，用于检查手表阅读体验。", timestamp: Date(), sim: "SIM 2", outgoing: false, unread: true),
            WatchSMSRow(id: "fixture-out", agentID: "fixture-agent", sender: "测试联系人", preview: "好的，这是我发送的模拟回复。", timestamp: Date().addingTimeInterval(-20), sim: "SIM 1", outgoing: true, unread: false),
            WatchSMSRow(id: "fixture-2", agentID: "fixture-agent", sender: "运营商服务", preview: "模拟长短信：中文、换行和数字 123456。", timestamp: Date().addingTimeInterval(-3600), sim: "SIM 1", outgoing: false, unread: false)]
        smsPage = WatchSMSPage(devices: [.init(id: "fixture-agent", name: "模拟安卓")], selectedAgentID: "fixture-agent", rows: rows, total: rows.count, generatedAt: Date())
    }

    override init() {
        super.init()
        if isUIFixture { installUIFixture(); return }
        if let data = UserDefaults.standard.data(forKey: Self.receiptsKey),
           let receipts = try? JSONDecoder().decode([ReadReceipt].self, from: data) {
            readReceipts = receipts
            confirmedReadSMSKeys = Set(receipts.map { Self.localReadKey(agentID: $0.agentID, key: $0.key) })
        }
        // Remove the old direct-call credential when upgrading to the SMS app.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "AirSIM.watch.direct-call.v1"] as CFDictionary)
        var query = Self.routeKeychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let route = try? JSONDecoder().decode(WatchSMSDirectRoute.self, from: data), route.allowsLocalAccess {
            directRoute = route
            if let data = try? Data(contentsOf: historyCacheURL),
               let page = try? JSONDecoder().decode(WatchSMSPage.self, from: data),
               page.selectedAgentID == route.agentID {
                companionHistory = page
            }
        }
        if WCSession.isSupported() {
            let session = WCSession.default
            connectivity = session
            session.delegate = self
            session.activate()
        }
    }

    private static let routeKeychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "AirSIM.watch.direct-sms.v1",
        kSecAttrAccount as String: "paired-android"
    ]

    private func updateDirectRoute(_ route: WatchSMSDirectRoute?) {
        guard directRoute != route else { return }
        if let route, (directRoute?.agentID ?? companionHistory?.selectedAgentID).map({ $0 != route.agentID }) == true {
            clearHistory()
        }
        directRoute = route
        directInbox = nil
        let query = Self.routeKeychainQuery
        guard let route, let data = try? JSONEncoder().encode(route) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func loadDirectInbox(agentID: String?, allowProvision: Bool = true) async throws -> WatchDirectInbox {
        let previousRoute = directRoute
        if let route = directRoute, agentID == nil || route.agentID == agentID {
            do {
                let inbox: WatchDirectInbox = try await WatchSMSTransport.request("/api/watch/sms", route: route)
                try Task.checkCancellation()
                guard inbox.agentID == route.agentID, directRoute == route else { throw URLError(.cannotParseResponse) }
                directInbox = inbox
                return inbox
            } catch {
                try Task.checkCancellation()
                guard allowProvision else { throw error }
                let candidates = await WatchSMSBonjour.candidates(for: route)
                for candidate in candidates {
                    try Task.checkCancellation()
                    guard directRoute == route else { break }
                    if let inbox: WatchDirectInbox = try? await WatchSMSTransport.request(
                        "/api/watch/sms", route: candidate, timeout: 2), !Task.isCancelled,
                       inbox.agentID == route.agentID, directRoute == route {
                        updateDirectRoute(candidate)
                        directInbox = inbox
                        return inbox
                    }
                }
                try Task.checkCancellation()
                if connectivity?.isReachable != true { throw error }
            }
        }
        guard allowProvision else { throw WatchDirectError.unavailable }
        var routeRequest: [String: Any] = ["action": "watch_sms_direct_route"]
        routeRequest["previous_host"] = previousRoute?.host
        let reply = try await companionRequest(routeRequest, timeout: 8)
        try Task.checkCancellation()
        if reply["revoked"] as? Bool == true { updateDirectRoute(nil); clearHistory() }
        guard let data = reply["route"] as? Data,
              let route = try? JSONDecoder().decode(WatchSMSDirectRoute.self, from: data),
              route.allowsLocalAccess, agentID == nil || route.agentID == agentID else {
            throw WatchDirectError.unavailable
        }
        updateDirectRoute(route)
        return try await loadDirectInbox(agentID: agentID, allowProvision: false)
    }

    private func requestLatestState() {
        companionReachable = connectivity?.isReachable == true
        if companionReachable { Task { await syncReadReceipts() } }
    }

    @MainActor private func companionRequest(_ payload: [String: Any], timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard let connectivity, connectivity.isReachable else { throw WatchCompanionError.unreachable }
        return try await sendCompanionMessage(payload, on: connectivity, timeout: timeout)
    }

    private func sendCompanionMessage(_ payload: [String: Any], on connectivity: WCSession,
                                      timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let gate = WatchReplyGate { continuation.resume(with: $0) }
            connectivity.sendMessage(payload, replyHandler: { gate.finish(.success($0)) },
                                     errorHandler: { gate.finish(.failure($0)) })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.finish(.failure(WatchCompanionError.timeout)) }
        }
    }

    @MainActor func refreshSMS(agentID: String? = nil) async {
        if isUIFixture { return }
        let requestID = UUID(); smsRequestID = requestID
        smsBusy = true; smsError = nil
        defer { if smsRequestID == requestID { smsBusy = false } }
        var directPage: WatchSMSPage?
        var directFailure: Error?
        do {
            directPage = try await loadDirectInbox(agentID: agentID).page()
            guard smsRequestID == requestID, !Task.isCancelled else { return }
            if let directPage { publishInbox(directPage) }
        } catch { directFailure = error }

        guard smsRequestID == requestID, !Task.isCancelled else { return }
        do {
            let page = try await companionPage(action: "watch_sms_list", agentID: directPage?.selectedAgentID ?? agentID)
            guard smsRequestID == requestID, !Task.isCancelled else { return }
            rememberHistory(page)
            Task { await syncReadReceipts() }
            if let directPage { publishInbox(directPage) }
            else {
                smsUsingDirect = false
                smsShowingCachedHistory = false
                smsShowingCompanionHistory = !page.rows.isEmpty
                smsPage = companionHistory ?? page
                smsError = directFailure.map { "安卓直连暂不可用 · \($0.localizedDescription)" }
            }
        } catch {
            guard smsRequestID == requestID, !Task.isCancelled, directPage == nil else { return }
            smsUsingDirect = false
            smsShowingCachedHistory = true
            if smsPage == nil, let history = companionHistory,
               history.selectedAgentID == (agentID ?? directRoute?.agentID) { smsPage = history }
            smsError = directFailure?.localizedDescription ?? error.localizedDescription
        }
    }

    private func publishInbox(_ direct: WatchSMSPage) {
        guard let agentID = direct.selectedAgentID else { return }
        let history = companionHistory?.rows ?? []
        let rows = WatchSMSPolicy.merged(direct: direct.rows, companion: history, agentID: agentID)
        smsUsingDirect = true
        smsShowingCachedHistory = false
        smsShowingCompanionHistory = rows.count > direct.rows.count
        smsPage = .init(devices: direct.devices, selectedAgentID: agentID, rows: Array(rows.prefix(150)),
            total: rows.count, generatedAt: direct.generatedAt)
    }

    private func companionPage(action: String, agentID: String?, peer: String? = nil) async throws -> WatchSMSPage {
        var payload: [String: Any] = ["action": action]
        payload["agent_id"] = agentID
        payload["peer"] = peer
        let reply = try await companionRequest(payload, timeout: 4)
        try Task.checkCancellation()
        guard reply["ok"] as? Bool == true, let data = reply["sms_data"] as? Data else {
            throw WatchCompanionError.remote(reply["error"] as? String ?? "短信暂不可用")
        }
        let page = try JSONDecoder().decode(WatchSMSPage.self, from: data)
        guard agentID == nil || page.selectedAgentID == agentID,
              page.rows.allSatisfy({ row in
                  row.agentID == page.selectedAgentID && (peer == nil || WatchSMSConversationPolicy.peer(row.sender) == peer)
              }) else { throw WatchCompanionError.remote("短信来源不匹配") }
        return page
    }

    func replyOptions(for conversation: WatchSMSConversation) async throws -> WatchSMSReplyOptions {
        if isUIFixture {
            return .init(recipient: "13800138000", slots: [
                .init(id: "sim1", label: "SIM 1", carrier: "中国移动"),
                .init(id: "sim2", label: "SIM 2", carrier: "中国联通")
            ], selectedID: "sim1")
        }
        if let direct = try? await loadDirectInbox(agentID: conversation.agentID),
           let recipient = WatchSMSConversationPolicy.replyNumber(conversation.latest.sender) {
            let slots = direct.slots.map { $0.option }
            return .init(recipient: recipient, slots: slots, selectedID: slots.first?.id)
        }
        let reply = try await companionRequest(["action": "watch_sms_reply_options",
            "agent_id": conversation.agentID, "peer": conversation.peer])
        guard reply["ok"] as? Bool == true, let data = reply["options"] as? Data else {
            throw WatchCompanionError.remote(reply["error"] as? String ?? "无法读取发送卡")
        }
        let options = try JSONDecoder().decode(WatchSMSReplyOptions.self, from: data)
        guard WatchSMSConversationPolicy.peer(options.recipient) == conversation.peer else {
            throw WatchCompanionError.remote("短信收件人与当前会话不匹配")
        }
        return options
    }

    private func pendingKey(_ conversation: WatchSMSConversation) -> String {
        "watchSMS.pending." + WatchSMSPolicy.digest(conversation.id)
    }

    func hasPendingReply(for conversation: WatchSMSConversation) -> Bool {
        UserDefaults.standard.string(forKey: pendingKey(conversation)) != nil
    }

    func dismissPendingReply(for conversation: WatchSMSConversation) {
        UserDefaults.standard.removeObject(forKey: pendingKey(conversation))
    }

    private func completeReply(_ outcome: WatchSMSReplyOutcome, for conversation: WatchSMSConversation) -> WatchSMSReplyOutcome {
        switch outcome {
        case .sent, .failed: UserDefaults.standard.removeObject(forKey: pendingKey(conversation))
        case .uncertain: break
        }
        return outcome
    }

    func sendReply(to conversation: WatchSMSConversation, text: String, slotID: String) async -> WatchSMSReplyOutcome {
        if isUIFixture { return .sent }
        guard !directSendInFlight else { return .failed("上一条短信仍在发送") }
        guard !hasPendingReply(for: conversation) else { return .uncertain }
        directSendInFlight = true
        defer { directSendInFlight = false }
        let direct = try? await loadDirectInbox(agentID: conversation.agentID)
        guard !Task.isCancelled else { return .failed("发送已取消") }
        guard let number = WatchSMSConversationPolicy.replyNumber(conversation.latest.sender) else {
            return .failed("当前会话没有可回复的电话号码")
        }
        let operation = UUID().uuidString.lowercased()
        let outcome: WatchSMSReplyOutcome
        if let direct, let route = directRoute, route.agentID == direct.agentID {
            guard direct.supportsOperationStatus == true else { return .failed("请更新安卓 AirSIM 后再从手表发送") }
            guard direct.slots.contains(where: { $0.id == slotID }) else { return .failed("发送卡已变化，请重新选择") }
            UserDefaults.standard.set(operation, forKey: pendingKey(conversation))
            do {
                let body = try JSONEncoder().encode(["number": number, "body": text, "slot": slotID, "operation_id": operation])
                let result: WatchDirectSend = try await WatchSMSTransport.request("/api/watch/sms/send", route: route, body: body)
                outcome = result.outcome
            } catch { outcome = .uncertain }
        } else {
            UserDefaults.standard.set(operation, forKey: pendingKey(conversation))
            do {
                let reply = try await companionRequest(["action": "watch_sms_tracked_reply_send", "agent_id": conversation.agentID,
                    "peer": conversation.peer, "body": text, "slot_id": slotID, "operation_id": operation,
                    "expires_at": Date().addingTimeInterval(15).timeIntervalSince1970], timeout: 82)
                outcome = Self.companionOutcome(reply)
            } catch WatchCompanionError.unreachable {
                outcome = .failed("安卓与 iPhone 当前均无法连接，短信未发送")
            } catch { outcome = .uncertain }
        }
        return completeReply(outcome, for: conversation)
    }

    func checkReply(for conversation: WatchSMSConversation) async -> WatchSMSReplyOutcome {
        guard !directSendInFlight,
              let operation = UserDefaults.standard.string(forKey: pendingKey(conversation)) else { return .uncertain }
        let direct = try? await loadDirectInbox(agentID: conversation.agentID)
        let outcome: WatchSMSReplyOutcome
        if direct?.supportsOperationStatus == true, let route = directRoute, route.agentID == conversation.agentID,
           let data = try? JSONSerialization.data(withJSONObject: ["operation_id": operation, "status_only": true]),
           let result: WatchDirectSend = try? await WatchSMSTransport.request("/api/watch/sms/send", route: route, body: data, timeout: 5) {
            outcome = result.outcome
        } else if let reply = try? await companionRequest(["action": "watch_sms_reply_status", "agent_id": conversation.agentID,
                                                          "operation_id": operation], timeout: 10),
                  reply["status_result"] as? Bool == true {
            outcome = Self.companionOutcome(reply)
        } else { outcome = .uncertain }
        return completeReply(outcome, for: conversation)
    }

    private static func companionOutcome(_ reply: [String: Any]) -> WatchSMSReplyOutcome {
        if reply["ok"] as? Bool == true { return .sent }
        if reply["uncertain"] as? Bool == true { return .uncertain }
        return .failed(reply["error"] as? String ?? "短信未发送")
    }

    func loadConversation(_ conversation: WatchSMSConversation) async throws -> WatchSMSPage {
        let agentID = conversation.agentID
        let peer = conversation.peer
        if isUIFixture {
            return .init(devices: smsPage?.devices ?? [], selectedAgentID: agentID,
                rows: conversation.rows, total: conversation.rows.count, generatedAt: Date())
        }
        let direct = try? await loadDirectInbox(agentID: agentID)
        let phone = try? await companionPage(action: "watch_sms_thread", agentID: agentID, peer: peer)
        try Task.checkCancellation()
        if let phone { rememberHistory(phone) }
        if let direct, smsPage?.selectedAgentID == agentID { publishInbox(direct.page()) }
        let directRows = direct?.page(peer: peer).rows ?? conversation.rows.filter { $0.id.hasPrefix("lan:") }
        let historicalRows = companionHistory?.rows.filter { WatchSMSConversationPolicy.peer($0.sender) == peer }
            ?? conversation.rows.filter { !$0.id.hasPrefix("lan:") }
        let rows = WatchSMSPolicy.merged(direct: directRows, companion: historicalRows, agentID: agentID)
        return .init(devices: direct?.page().devices ?? phone?.devices ?? smsPage?.devices ?? [],
            selectedAgentID: agentID, rows: rows, total: rows.count, generatedAt: Date())
    }

    @MainActor func loadSMS(_ row: WatchSMSRow) async throws -> WatchSMSDetail {
        if isUIFixture {
            return WatchSMSDetail(row: row, body: String(repeating: "这是一条用于模拟阅读的短信正文。\n中文、数字 123456 和表情🙂。\n", count: 5), truncated: false)
        }
        if row.id.hasPrefix("lan:") {
            let inbox: WatchDirectInbox
            if let cached = directInbox, cached.agentID == row.agentID,
               cached.messages.contains(where: { $0.row(agentID: cached.agentID)?.id == row.id }) { inbox = cached }
            else { inbox = try await loadDirectInbox(agentID: row.agentID) }
            guard let message = inbox.messages.first(where: { $0.row(agentID: row.agentID)?.id == row.id }) else {
                throw WatchDirectError.unavailable
            }
            return try WatchSMSPolicy.boundedDetail(row: row, body: message.content)
        }
        guard connectivity?.isReachable == true,
              let reply = try? await companionRequest(["action": "watch_sms_detail", "agent_id": row.agentID, "message_id": row.id]),
              !Task.isCancelled else {
            try Task.checkCancellation()
            return .init(row: row, body: row.preview, truncated: true)
        }
        guard reply["ok"] as? Bool == true, let data = reply["sms_data"] as? Data else {
            throw WatchCompanionError.remote(reply["error"] as? String ?? "短信暂不可用")
        }
        let detail = try JSONDecoder().decode(WatchSMSDetail.self, from: data)
        guard WatchSMSPolicy.matches(detail.row, agentID: row.agentID, id: row.id) else { throw WatchCompanionError.remote("短信来源不匹配") }
        return detail
    }
    @MainActor func markSMSRead(_ row: WatchSMSRow) async -> Bool {
        if isUIFixture { confirmedReadSMSKeys.insert(smsReadKey(row)); return true }
        guard !row.outgoing else { return true }
        let key = WatchSMSPolicy.readKey(messageID: row.id, deliveryKey: row.deliveryKey)
        if !confirmedReadSMSKeys.contains(smsReadKey(row)) {
            readReceipts.append(.init(agentID: row.agentID, key: key))
            if readReceipts.count > 512 { readReceipts.remove(at: readReceipts.firstIndex(where: \.synced) ?? 0) }
            saveReadReceipts()
        }
        Task { await syncReadReceipts() }
        if let page = smsPage {
            smsPage = WatchSMSPage(devices: page.devices, selectedAgentID: page.selectedAgentID,
                rows: page.rows.map { value in
                    guard value.id == row.id, value.agentID == row.agentID else { return value }
                    var read = value
                    read.unread = false
                    return read
                }, total: page.total, generatedAt: page.generatedAt)
        }
        return true
    }

}

private enum WatchSMSBonjour {
    static func candidates(for saved: WatchSMSDirectRoute) async -> [WatchSMSDirectRoute] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "AirSIM Watch SMS Bonjour")
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airsim-vowlan._tcp", domain: nil),
                                    using: parameters)
            let candidates = OSAllocatedUnfairLock(initialState: [WatchSMSDirectRoute]())
            browser.browseResultsChangedHandler = { results, _ in
                let found: [WatchSMSDirectRoute] = results.compactMap { result in
                    guard case let .bonjour(record) = result.metadata,
                          record["v"] == "1", record["agent_id"] == saved.agentID,
                          let host = record["host"], let port = record["control_port"].flatMap(UInt16.init) else { return nil }
                    let candidate = WatchSMSDirectRoute(agentID: saved.agentID, host: host, port: port,
                                                        secret: saved.secret, clockOffset: saved.clockOffset)
                    return candidate.allowsLocalAccess && candidate != saved ? candidate : nil
                }
                candidates.withLock { $0 = found }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) {
                browser.browseResultsChangedHandler = nil
                browser.cancel()
                continuation.resume(returning: candidates.withLock { Array($0.prefix(4)) })
            }
        }
    }
}

private struct WatchDirectInbox: Decodable {
    struct Slot: Decodable {
        let id: String
        let label: String
        let slot_index: Int?
        let carrier_name: String?
        var option: WatchSMSReplyOptions.Slot {
            .init(id: id, label: slot_index.map { "SIM \($0 + 1)" } ?? label, carrier: carrier_name)
        }
    }
    struct Message: Decodable {
        let delivery_id: String
        let sender: String
        let content: String
        let timestamp: String
        let sim_slot: String?
        let direction: String?
        func row(agentID: String) -> WatchSMSRow? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard !delivery_id.isEmpty,
                  let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { return nil }
            let outgoing = direction == "outgoing"
            return .init(id: "lan:" + delivery_id, agentID: agentID, sender: sender,
                         preview: WatchSMSPolicy.prefix(content, utf8Limit: 180), timestamp: date,
                         sim: sim_slot, outgoing: outgoing, unread: !outgoing,
                         deliveryKey: WatchSMSPolicy.digest(delivery_id))
        }
    }
    let agentID: String
    let name: String
    let slots: [Slot]
    let messages: [Message]
    let supportsOperationStatus: Bool?
    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case name, slots, messages
        case supportsOperationStatus = "operation_status"
    }
    func page(peer: String? = nil) -> WatchSMSPage {
        let rows = messages.compactMap { $0.row(agentID: agentID) }
            .filter { row in peer.map { WatchSMSConversationPolicy.peer(row.sender) == $0 } ?? true }
        return .init(devices: [.init(id: agentID, name: name)], selectedAgentID: agentID,
                     rows: rows, total: rows.count, generatedAt: Date())
    }
}

extension WatchCallSession: WCSessionDelegate {
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.requestLatestState() }
    }

    nonisolated func session(_ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in self?.requestLatestState() }
    }
}

private enum WatchCompanionError: LocalizedError {
    case unreachable, timeout, remote(String)
    var errorDescription: String? {
        switch self {
        case .unreachable: return "iPhone 当前不可通信，请靠近 iPhone 并打开 AirSIM 后重试"
        case .timeout: return "iPhone 回应超时，请重试"
        case let .remote(message):
            if ["unsupported_action", "missing_action", "stale_call"].contains(message) {
                return "此 iPhone 版本不支持当前手表请求，请使用配套版本"
            }
            return message
        }
    }
}
final class WatchReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Result<[String: Any], Error>) -> Void)?
    init(_ callback: @escaping (Result<[String: Any], Error>) -> Void) { self.callback = callback }
    func finish(_ result: Result<[String: Any], Error>) {
        lock.lock(); let action = callback; callback = nil; lock.unlock()
        action?(result)
    }
}
