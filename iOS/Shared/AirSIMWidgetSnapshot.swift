import Foundation
import Darwin
import WidgetKit

struct AndroidBatteryReading: Codable, Equatable, Sendable {
    let percent: Int
    let charging: Bool
    let observedAtMS: Double
    enum CodingKeys: String, CodingKey { case percent, charging; case observedAtMS = "observed_at_ms" }
    init(percent: Int, charging: Bool, observedAtMS: Double) {
        self.percent = percent; self.charging = charging; self.observedAtMS = observedAtMS
    }
    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        percent = (try? values?.decode(Int.self, forKey: .percent)) ?? -1
        charging = (try? values?.decode(Bool.self, forKey: .charging)) ?? false
        observedAtMS = (try? values?.decode(Double.self, forKey: .observedAtMS)) ?? 0
    }
    var observedAt: Date { Date(timeIntervalSince1970: observedAtMS / 1000) }
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return (0...100).contains(percent) && observedAtMS.isFinite && observedAtMS > 0
            && age >= -60 && age < AirSIMWidgetSnapshot.freshness
    }
    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        if percent <= 10 { return "battery.0percent" }
        if percent <= 35 { return "battery.25percent" }
        if percent <= 60 { return "battery.50percent" }
        if percent <= 85 { return "battery.75percent" }
        return "battery.100percent"
    }
}

/// A display snapshot protected by WidgetKit privacy redaction.
/// Never contains pairing secrets or endpoints, or authorizes a carrier command.
struct AirSIMWidgetSnapshot: Codable, Equatable, Sendable {
    static let kind = "AirSIMDeviceWidget"
    static let freshness: TimeInterval = 300
    static func badgeText(_ count: Int) -> String? {
        count > 0 ? (count > 99 ? "99+" : String(count)) : nil
    }
    var version = 1
    var generatedAt: Date
    var devices: [Device]
    var calls: [RecentCall]
    // Optional for compatibility with snapshots saved before SMS summaries.
    var messages: [RecentMessage]? = nil
    var controls: Controls? = nil
    var readCallKeys: [String: [String]]? = nil
    var unseenCallKeys: [String: [String]]? = nil
    var readMessageKeys: [String: [String]]? = nil
    var unreadMessageKeys: [String: [String]]? = nil

    struct Controls: Codable, Equatable, Sendable {
        let mode: String
        let modeTitle: String
        let nextMode: String
        let nextModeTitle: String
        let currentAgentID: String
        let nextAgentID: String?
        let nextAgentName: String?
        let blockedByCall: Bool
    }

    struct RecentMessage: Codable, Equatable, Sendable {
        let agentID: String?
        let date: Date
        let incoming: Bool
        var contentPreview: String? = nil
        var sender: String? = nil
        var simSlot: String? = nil
        var identityKey: String? = nil

        var displayText: String { contentPreview ?? "打开查看短信内容" }
    }

    static func messagePreview(_ content: String) -> String {
        let singleLine = content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return singleLine.isEmpty ? "（空短信）" : String(singleLine.prefix(120))
    }

    func latestCall(for agentID: String) -> RecentCall? {
        calls.filter { $0.agentID == agentID }.max { $0.date < $1.date }
    }
    func latestMessage(for agentID: String) -> RecentMessage? {
        (messages ?? []).filter { $0.agentID == agentID }.max { $0.date < $1.date }
    }

    struct Device: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let transport: String
        let recentlyReachable: Bool
        let observedAt: Date?
        var batteryPercent: Int? = nil
        var battery: AndroidBatteryReading? = nil
        var unreadMessages: Int? = nil
        var unseenMissedCalls: Int? = nil
        var activeState: String? = nil
        var refreshFailed: Bool? = nil
        var lastRefreshAttempt: Date? = nil
        var refreshFailureReason: String? = nil
        var refreshPending: Bool? = nil
        func refreshInProgress(at now: Date) -> Bool {
            refreshPending == true && lastRefreshAttempt.map { now.timeIntervalSince($0) < 20 } == true
        }

        func isFresh(at date: Date) -> Bool {
            guard let observedAt else { return false }
            return date.timeIntervalSince(observedAt) >= -60
                && date.timeIntervalSince(observedAt) < AirSIMWidgetSnapshot.freshness
        }
        func status(at date: Date) -> String {
            if refreshInProgress(at: date) { return "正在刷新…" }
            if refreshPending == true { return "上次刷新中断，请重试" }
            if refreshFailed == true { return refreshFailureReason ?? "刷新失败，请重试" }
            guard isFresh(at: date) else { return "状态待刷新" }
            return recentlyReachable ? "最近在线" : "未连接"
        }
    }
    struct RecentCall: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let agentID: String?
        let maskedNumber: String
        let date: Date
        let incoming: Bool
        let missed: Bool
        var slotIndex: Int? = nil
        var duration: TimeInterval? = nil
        var number: String? = nil
        var displayNumber: String {
            let value = number?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.flatMap { $0.isEmpty ? nil : $0 } ?? maskedNumber
        }
        var detailText: String {
            var parts = [slotIndex.flatMap { $0 >= 0 && $0 < 8 ? "SIM \($0 + 1)" : nil } ?? "SIM 未记录"]
            if !missed, let duration, duration.isFinite, duration >= 0 {
                let seconds = Int(min(duration, 604800))
                parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
            }
            return parts.joined(separator: " · ")
        }
    }
    static var empty: Self { .init(generatedAt: .distantPast, devices: [], calls: []) }
    static func mask(_ number: String?) -> String {
        let digits = (number ?? "").filter(\.isNumber)
        guard digits.count >= 7 else { return "号码已隐藏" }
        return "\(digits.prefix(3)) •••• \(digits.suffix(4))"
    }
    /// Future entries turn old observations neutral even when the app sleeps.
    func expirationDates(after now: Date) -> [Date] {
        Array(Set((devices.compactMap { $0.observedAt?.addingTimeInterval(Self.freshness) }
                   + devices.compactMap { $0.battery?.observedAt.addingTimeInterval(Self.freshness) })
            .filter { $0 > now })).sorted()
    }
    static func preview(at now: Date = Date()) -> Self {
        .init(generatedAt: now, devices: [
            .init(id: "preview-galaxy", name: "Galaxy", transport: "VoWLAN", recentlyReachable: true,
                  observedAt: now, batteryPercent: 82,
                  battery: .init(percent: 82, charging: false, observedAtMS: now.timeIntervalSince1970 * 1000),
                  unreadMessages: 1, unseenMissedCalls: 2, activeState: "idle"),
            .init(id: "preview-redmi", name: "Redmi", transport: "VoBLE", recentlyReachable: true,
                  observedAt: now.addingTimeInterval(-36000))
        ], calls: [
            .init(id: "example-1", agentID: "preview-galaxy", maskedNumber: "138 •••• 6028",
                  date: now.addingTimeInterval(-1500), incoming: true, missed: true, slotIndex: 0, number: "13800138000"),
            .init(id: "example-3", agentID: "preview-galaxy", maskedNumber: "139 •••• 9000",
                  date: now.addingTimeInterval(-3000), incoming: true, missed: false, slotIndex: 1, duration: 155, number: "13900139000"),
            .init(id: "example-4", agentID: "preview-galaxy", maskedNumber: "136 •••• 6000",
                  date: now.addingTimeInterval(-3500), incoming: true, missed: true, slotIndex: 0, number: "13600136000"),
            .init(id: "example-2", agentID: "preview-redmi", maskedNumber: "186 •••• 7720",
                  date: now.addingTimeInterval(-3600), incoming: true, missed: true)
        ], messages: [
            .init(agentID: "preview-galaxy", date: now.addingTimeInterval(-600), incoming: true,
                  contentPreview: "话费余额充足，感谢使用。", sender: "10086", simSlot: "SIM 1")
        ], controls: .init(mode: "vowlan", modeTitle: "VoWLAN", nextMode: "vowlan",
                          nextModeTitle: "VoWLAN", currentAgentID: "preview-galaxy",
                          nextAgentID: "preview-redmi", nextAgentName: "Redmi", blockedByCall: false))
    }
}

struct AirSIMWidgetStore {
    let fileURL: URL?
    init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL; return }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AirSIMWidgetAppGroup") as? String,
              group.hasPrefix("group."), !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { self.fileURL = nil; return }
        self.fileURL = container.appendingPathComponent("widget-snapshot-v1.json")
    }
    func load() -> AirSIMWidgetSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL), data.count < 256_000,
              let snapshot = try? JSONDecoder().decode(AirSIMWidgetSnapshot.self, from: data),
              snapshot.version == 1 else { return .empty }
        return snapshot
    }
    @discardableResult
    func save(_ snapshot: AirSIMWidgetSnapshot) -> Bool {
        guard let fileURL else { return false }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
}

enum AirSIMWidgetDestination: String, CaseIterable {
    case status, dial, messages, contacts, recents
    func url(agentID: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = "airsim"; c.host = "widget"; c.path = "/" + rawValue
        if let agentID { c.queryItems = [.init(name: "agent", value: agentID)] }
        return c.url!
    }
    static func parse(_ url: URL) -> (destination: Self, agentID: String?)? {
        guard url.scheme?.lowercased() == "airsim", url.host == "widget",
              url.user == nil, url.password == nil, url.port == nil,
              let destination = Self(rawValue: String(url.path.dropFirst())),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = c.queryItems?.first(where: { $0.name == "agent" })?.value
        return (destination, id)
    }
}

// Shared by the app and WidgetKit. Pairing material stays in the shared
// Keychain; it is never included in the display snapshot or a URL.
import CryptoKit
import Security

struct WidgetDirectTarget: Codable, Sendable {
    let agentID: String
    let host: String
    let port: Int
    let secret: Data
    let clockOffset: TimeInterval
    var isLAN: Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let p = pieces.compactMap { Int($0) }
        return pieces.count == 4 && p.count == 4
            && zip(pieces, p).allSatisfy { String($0.1) == String($0.0) } && p.allSatisfy { (0...255).contains($0) }
            && (p[0] == 10 || (p[0] == 192 && p[1] == 168)
                || (p[0] == 172 && (16...31).contains(p[1])))
            && (1...65535).contains(port) && secret.count >= 32 && clockOffset.isFinite && abs(clockOffset) < 315_360_000
    }
}

enum WidgetDirectKeychain {
    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AirSIMWidgetAppGroup") as? String,
              group.hasPrefix("group."), !group.contains("$(") else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "AirSIM.widget.direct.v1",
                kSecAttrAccount as String: "verified-lan-targets",
                kSecAttrAccessGroup as String: group]
    }
    static func remove(agentID: String) {
        let remaining = load().filter { $0.agentID != agentID }
        save(remaining, allowedIDs: Set(remaining.map(\.agentID)))
    }
    static func status() -> OSStatus {
        guard let q = query else { return errSecMissingEntitlement }
        return SecItemCopyMatching(q as CFDictionary, nil)
    }
    static func load() -> [WidgetDirectTarget] {
        guard var q = query else { return [] }
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count < 64_000,
              let targets = try? JSONDecoder().decode([WidgetDirectTarget].self, from: data) else { return [] }
        return Array(targets.filter(\.isLAN).prefix(2))
    }
    @discardableResult static func save(_ targets: [WidgetDirectTarget], allowedIDs: Set<String>) -> OSStatus {
        guard var q = query else { return errSecMissingEntitlement }
        let fresh = targets.filter { $0.isLAN && allowedIDs.contains($0.agentID) }
        let ids = Set(fresh.map(\.agentID))
        let merged = Array((fresh + load().filter { allowedIDs.contains($0.agentID) && !ids.contains($0.agentID) }).prefix(2))
        guard !merged.isEmpty else { return SecItemDelete(q as CFDictionary) }
        guard let data = try? JSONEncoder().encode(merged) else { return errSecParam }
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status }
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }
}

private final class WidgetNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum WidgetDirectRefresh {
    struct Health: Decodable, Sendable {
        let ok: Bool
        let agent_id: String
        let identity_proof: String
        let battery: AndroidBatteryReading?
    }
    private static func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func read(_ target: WidgetDirectTarget, path: String,
                      send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> (Data, String) {
        guard target.isLAN, ["/v1/health", "/api/calls/status", "/api/sms"].contains(path) else { throw URLError(.badURL) }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let timestamp = Int64(Date().timeIntervalSince1970 + target.clockOffset)
        let digest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let canonical = "GET\n\(path)\n\(digest)\n\(timestamp)\n\(nonce)"
        let key = SymmetricKey(data: target.secret)
        let signature = encoded(Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)))
        var request = URLRequest(url: URL(string: "http://\(target.host):\(target.port)\(path)")!)
        request.timeoutInterval = 4; request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in [("Version", "1"), ("Timestamp", String(timestamp)), ("Nonce", nonce), ("Signature", signature)] {
            request.setValue(value, forHTTPHeaderField: "X-AirSIM-VoWLAN-" + name)
        }
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false; config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: WidgetNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response): (Data, URLResponse)
        if let send { (data, response) = try await send(request) }
        else { (data, response) = try await session.data(for: request) }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw NSError(domain: "AirSIM.Widget.HTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count < (path == "/v1/health" ? 64_000 : 512_000) else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, nonce)
    }
    static func fetch(_ target: WidgetDirectTarget,
                      send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> Health {
        let (data, nonce) = try await read(target, path: "/v1/health", send: send)
        let key = SymmetricKey(data: target.secret)
        let health = try JSONDecoder().decode(Health.self, from: data)
        let proof = health.identity_proof.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard health.ok, health.agent_id == target.agentID,
              let supplied = Data(base64Encoded: proof + String(repeating: "=", count: (4 - proof.count % 4) % 4)),
              HMAC<SHA256>.isValidAuthenticationCode(supplied,
                authenticating: Data("AIRSIM-HEALTH1\n\(nonce)\n\(target.agentID)".utf8), using: key)
        else { throw URLError(.userAuthenticationRequired) }
        return health
    }
    private static func diagnostic(_ fields: [String: Any]) {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AirSIMWidgetAppGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? JSONSerialization.data(withJSONObject: fields) else { return }
        try? data.write(to: root.appendingPathComponent("widget-direct-diagnostic.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private struct Observation: Codable {
        let agentID: String
        let date: Date
        let battery: AndroidBatteryReading?
        var calls: [AirSIMWidgetSnapshot.RecentCall]? = nil
        var messages: [AirSIMWidgetSnapshot.RecentMessage]? = nil
        var activeState: String? = nil
        var lastFailure: Date? = nil
        var lastAttempt: Date? = nil
        var failureReason: String? = nil
        var pending: Bool? = nil
    }
    private static var observationURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AirSIMWidgetAppGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let folder = root.appendingPathComponent("Library/WidgetDirect", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("observations.json")
    }
    static func displaySnapshot() -> AirSIMWidgetSnapshot {
        var snapshot = AirSIMWidgetStore().load()
        guard let url = observationURL, let data = try? Data(contentsOf: url), data.count < 64_000,
              let observations = try? JSONDecoder().decode([Observation].self, from: data) else { return snapshot }
        let allowed = Set(WidgetDirectKeychain.load().map(\.agentID))
        for reading in observations where allowed.contains(reading.agentID) && reading.date > snapshot.generatedAt {
            snapshot = mergingRecords(calls: reading.calls, messages: reading.messages, agentID: reading.agentID, into: snapshot)
        }
        snapshot.devices = snapshot.devices.map { device in
            guard allowed.contains(device.id), let reading = observations.first(where: { $0.agentID == device.id }) else { return device }
            var result = device
            if reading.date > (device.observedAt ?? .distantPast) {
                result = .init(id: device.id, name: device.name, transport: "VoWLAN", recentlyReachable: true,
                    observedAt: reading.date, battery: reading.battery, unreadMessages: device.unreadMessages,
                    unseenMissedCalls: device.unseenMissedCalls, activeState: reading.activeState)
            }
            result.lastRefreshAttempt = reading.lastAttempt
            result.refreshPending = reading.pending
            result.refreshFailureReason = reading.failureReason
            if let failure = reading.lastFailure, failure > reading.date {
                result.refreshFailed = true
            }
            return result
        }
        return snapshot
    }
    static func refreshError(_ error: String) -> String {
        if error.contains("HTTP:401") || error.contains("HTTP:403") || error.contains(":-1013") { return "配对认证失败，请打开 App 检查" }
        if error.contains(":-1001") { return "连接安卓超时，请检查 Wi-Fi" }
        if error.contains(":-1009") { return "网络不可用，请检查 Wi-Fi" }
        if error.contains(":-1004") || error.contains(":-1003") { return "安卓地址不可达，请打开 App 重新发现" }
        return "查询失败，请打开 App 检查连接"
    }
    static func snapshot(showProgress: Bool = false) async -> AirSIMWidgetSnapshot {
        let targets = WidgetDirectKeychain.load()
        guard let url = observationURL else { return displaySnapshot() }
        let fd = Darwin.open(url.deletingLastPathComponent().appendingPathComponent("refresh.lock").path,
            O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return displaySnapshot() }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return displaySnapshot() }
        if targets.isEmpty {
            var snapshot = displaySnapshot()
            snapshot.devices = snapshot.devices.map { device in
                var result = device; result.lastRefreshAttempt = Date(); result.refreshFailed = true
                result.refreshFailureReason = WidgetDirectKeychain.status() == errSecInteractionNotAllowed
                    ? "首次解锁后重试" : "请打开 App 同步直连配对配置"
                return result
            }
            return snapshot
        }
        var starting: [Observation] = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([Observation].self, from: $0)
        } ?? []
        // An intent already queried and persisted the result. Its timeline reload must
        // display that result rather than immediately starting a second network refresh.
        if !showProgress, !starting.isEmpty, targets.allSatisfy({ target in
            starting.contains { $0.agentID == target.agentID && $0.pending != true
                && $0.lastAttempt.map { Date().timeIntervalSince($0) < 5 } == true }
        }) { return displaySnapshot() }
        let baseSnapshot = AirSIMWidgetStore().load()
        for target in targets {
            if let index = starting.firstIndex(where: { $0.agentID == target.agentID }) {
                starting[index].lastAttempt = Date(); starting[index].pending = true
            } else {
                let device = baseSnapshot.devices.first { $0.id == target.agentID }
                starting.append(Observation(agentID: target.agentID, date: device?.observedAt ?? .distantPast,
                    battery: device?.battery, lastAttempt: Date(), pending: true))
            }
        }
        if let data = try? JSONEncoder().encode(starting) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if showProgress { WidgetCenter.shared.reloadTimelines(ofKind: AirSIMWidgetSnapshot.kind) }
        let started = Date().timeIntervalSince1970
        let keychainStatus = WidgetDirectKeychain.status()
        diagnostic(["stage":"started", "time":started, "targets":targets.count,
            "keychain_status":Int(keychainStatus), "bundle":Bundle.main.bundleIdentifier ?? "unknown"])
        var readings: [String: (Report, Date)] = [:]
        var errors: [String] = []
        var failedIDs = Set<String>()
        var failureReasons: [String: String] = [:]
        await withTaskGroup(of: (String, Report?, Date, String?).self) { group in
            for target in targets {
                group.addTask {
                    do { return (target.agentID, try await reportWithRetry(target), Date(), nil) }
                    catch { let e = error as NSError; return (target.agentID, nil, Date(), "\(e.domain):\(e.code)") }
                }
            }
            for await result in group {
                let (id, health, date, error) = result
                if let health { readings[id] = (health, date) }
                if let error { errors.append(error); failedIDs.insert(id); failureReasons[id] = refreshError(error) }
            }
        }
        diagnostic(["stage":"completed", "time":Date().timeIntervalSince1970, "started":started,
            "targets":targets.count, "success":readings.count, "errors":errors,
            "call_sources":readings.values.filter { $0.0.calls != nil }.count,
            "sms_sources":readings.values.filter { $0.0.messages != nil }.count,
            "fetched_calls":readings.values.reduce(0) { $0 + ($1.0.calls?.count ?? 0) },
            "fetched_sms":readings.values.reduce(0) { $0 + ($1.0.messages?.count ?? 0) },
            "keychain_status":Int(keychainStatus), "bundle":Bundle.main.bundleIdentifier ?? "unknown"])
        // Persist only health observations; never overwrite app-owned history.
        if !readings.isEmpty || !failedIDs.isEmpty, let url = observationURL {
            let allowed = Set(WidgetDirectKeychain.load().map(\.agentID))
            var observations: [Observation] = []
            if let data = try? Data(contentsOf: url), data.count < 64_000 {
                observations = (try? JSONDecoder().decode([Observation].self, from: data)) ?? []
            }
            let previous = observations
            observations.removeAll { readings[$0.agentID] != nil || !allowed.contains($0.agentID) }
            observations += readings.compactMap { id, reading in
                allowed.contains(id) ? Observation(agentID: id, date: reading.1, battery: reading.0.health.battery,
                    calls: reading.0.calls ?? previous.first(where: { $0.agentID == id })?.calls,
                    messages: reading.0.messages ?? previous.first(where: { $0.agentID == id })?.messages,
                    activeState: reading.0.activeState, lastAttempt: Date(timeIntervalSince1970: started),
                    failureReason: reading.0.calls == nil || reading.0.messages == nil ? "状态已更新，部分记录查询失败" : nil,
                    pending: false) : nil
            }
            let base = AirSIMWidgetStore().load()
            for id in failedIDs where allowed.contains(id) {
                if let index = observations.firstIndex(where: { $0.agentID == id }) {
                    observations[index].lastFailure = Date()
                    observations[index].pending = false
                    observations[index].failureReason = failureReasons[id]
                } else if let device = base.devices.first(where: { $0.id == id }) {
                    observations.append(Observation(agentID: id, date: device.observedAt ?? .distantPast,
                        battery: device.battery, lastFailure: Date(), lastAttempt: Date(timeIntervalSince1970: started), failureReason: failureReasons[id], pending: false))
                }
            }
            if let data = try? JSONEncoder().encode(observations) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        return displaySnapshot()
    }
}

// Stable read-state keys never contain message bodies or phone numbers.
enum WidgetRecordKeys {
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func call(_ agent: String, _ id: String) -> String { digest("call\n\(agent)\n\(id)") }
    static func message(_ agent: String, deliveryID: String?, sender: String, date: Date) -> String {
        if let deliveryID, !deliveryID.isEmpty { return digest("sms\n\(agent)\n\(deliveryID)") }
        return digest("sms\n\(agent)\n\(sender)\n\(Int64((date.timeIntervalSince1970 * 1000).rounded()))")
    }
}

extension WidgetDirectRefresh {
    struct Report: Sendable {
        let health: Health
        let calls: [AirSIMWidgetSnapshot.RecentCall]?
        let messages: [AirSIMWidgetSnapshot.RecentMessage]?
        let activeState: String?
    }
    private static func wireDate(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let t = n.doubleValue
            guard t.isFinite, t > 0, t < 100_000_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: t > 100_000_000_000 ? t / 1000 : t)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func parseCalls(_ data: Data, agentID: String) throws -> ([AirSIMWidgetSnapshot.RecentCall], String) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["last_poll_error"] as? String ?? "").isEmpty,
              let history = root["history"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        let calls = history.compactMap { row -> AirSIMWidgetSnapshot.RecentCall? in
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count < 512,
                  let date = wireDate(row["started_at"]),
                  row["ended_at"] is String || ["ended", "failed"].contains(row["state"] as? String ?? "") else { return nil }
            let missed = row["missed"] as? Bool == true
            let connected = wireDate(row["connected_at"]), ended = wireDate(row["ended_at"])
            let duration = connected.flatMap { start in ended.flatMap { $0 >= start ? $0.timeIntervalSince(start) : nil } }
            return .init(id: WidgetRecordKeys.call(agentID, id), agentID: agentID,
                maskedNumber: AirSIMWidgetSnapshot.mask(row["number"] as? String), date: date,
                incoming: row["direction"] as? String == "incoming", missed: missed,
                slotIndex: (row["slot_index"] as? Int).flatMap { (0...7).contains($0) ? $0 : nil },
                duration: missed ? nil : duration, number: (row["number"] as? String).map { String($0.prefix(64)) })
        }.sorted { $0.date > $1.date }
        let active = (root["active"] as? [String: Any])?["state"] as? String ?? "idle"
        return (Array(calls.prefix(6)), active)
    }
    static func parseMessages(_ data: Data, agentID: String) throws -> [AirSIMWidgetSnapshot.RecentMessage] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        return Array(rows.compactMap { row -> AirSIMWidgetSnapshot.RecentMessage? in
            guard let date = wireDate(row["timestamp"]), let sender = row["sender"] as? String,
                  let content = row["content"] as? String else { return nil }
            return .init(agentID: agentID, date: date, incoming: row["direction"] as? String != "outgoing",
                contentPreview: AirSIMWidgetSnapshot.messagePreview(content), sender: String(sender.prefix(64)),
                simSlot: (row["sim_slot"] as? String).map { String($0.prefix(24)) },
                identityKey: WidgetRecordKeys.message(agentID, deliveryID: row["delivery_id"] as? String, sender: sender, date: date))
        }.sorted { $0.date > $1.date }.prefix(6))
    }
    // A cold widget extension can race Wi-Fi recovery after a long idle period.
    // Retry only transient transport failures; authentication failures remain visible.
    static func reportWithRetry(_ target: WidgetDirectTarget,
        operation: ((WidgetDirectTarget) async throws -> Report)? = nil,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 300_000_000) }
    ) async throws -> Report {
        do {
            if let operation { return try await operation(target) }
            return try await report(target)
        }
        catch {
            let networkError = error as NSError
            let transientCodes: [Int] = [-1001, -1004, -1005, -1009, -1003, -1006]
            guard networkError.domain == NSURLErrorDomain, transientCodes.contains(networkError.code),
                !Task.isCancelled else { throw error }
            try await pause()
            try Task.checkCancellation()
            if let operation { return try await operation(target) }
            return try await report(target)
        }
    }
    static func report(_ target: WidgetDirectTarget) async throws -> Report {
        let health = try await fetch(target)
        async let callData = try? read(target, path: "/api/calls/status")
        async let smsData = try? read(target, path: "/api/sms")
        let (callResult, smsResult) = await (callData, smsData)
        let calls = callResult.flatMap { try? parseCalls($0.0, agentID: target.agentID) }
        let messages = smsResult.flatMap { try? parseMessages($0.0, agentID: target.agentID) }
        return .init(health: health, calls: calls?.0, messages: messages, activeState: calls?.1)
    }
    static func mergingRecords(calls: [AirSIMWidgetSnapshot.RecentCall]?, messages: [AirSIMWidgetSnapshot.RecentMessage]?,
                               agentID: String, into base: AirSIMWidgetSnapshot) -> AirSIMWidgetSnapshot {
        var snapshot = base
        if let calls {
            let keys = Set(calls.map(\.id))
            snapshot.calls = Array((calls + snapshot.calls.filter { !keys.contains($0.id) }).sorted { $0.date > $1.date }.prefix(12))
        }
        if let messages {
            let keys = Set(messages.compactMap(\.identityKey))
            snapshot.messages = Array((messages + (snapshot.messages ?? []).filter {
                $0.identityKey.map { !keys.contains($0) } ?? true
            }).sorted { $0.date > $1.date }.prefix(12))
        }
        snapshot.devices = snapshot.devices.map { device in
            guard device.id == agentID else { return device }
            var copy = device
            if let read = base.readCallKeys?[agentID], let calls {
                let seen = Set(read)
                let unseen = Set(base.unseenCallKeys?[agentID] ?? []).union(calls.filter { $0.missed }.map(\.id)).subtracting(seen)
                copy.unseenMissedCalls = max(device.unseenMissedCalls ?? 0, unseen.count)
            }
            if let read = base.readMessageKeys?[agentID], let messages {
                let seen = Set(read)
                let unread = Set(base.unreadMessageKeys?[agentID] ?? []).union(messages.filter(\.incoming).compactMap(\.identityKey)).subtracting(seen)
                copy.unreadMessages = max(device.unreadMessages ?? 0, unread.count)
            }
            return copy
        }
        return snapshot
    }
}
