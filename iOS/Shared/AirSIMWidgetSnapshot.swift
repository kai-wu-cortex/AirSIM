import Foundation

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

/// A display snapshot with masked call numbers and bounded SMS previews.
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

        func isFresh(at date: Date) -> Bool {
            guard let observedAt else { return false }
            return date.timeIntervalSince(observedAt) >= -60
                && date.timeIntervalSince(observedAt) < AirSIMWidgetSnapshot.freshness
        }
        func status(at date: Date) -> String {
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
                  battery: .init(percent: 82, charging: false, observedAtMS: now.timeIntervalSince1970 * 1000)),
            .init(id: "preview-redmi", name: "Redmi", transport: "VoBLE", recentlyReachable: true,
                  observedAt: now.addingTimeInterval(-36000))
        ], calls: [
            .init(id: "example-1", agentID: "preview-galaxy", maskedNumber: "138 •••• 6028",
                  date: now.addingTimeInterval(-1500), incoming: false, missed: false),
            .init(id: "example-2", agentID: "preview-redmi", maskedNumber: "186 •••• 7720",
                  date: now.addingTimeInterval(-3600), incoming: true, missed: true)
        ], messages: [
            .init(agentID: "preview-galaxy", date: now.addingTimeInterval(-600), incoming: true,
                  contentPreview: "快递已送达，请及时查收。")
        ], controls: .init(mode: "vowlan", modeTitle: "VoWLAN", nextMode: "bluetooth",
                          nextModeTitle: "蓝牙", currentAgentID: "preview-galaxy",
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
