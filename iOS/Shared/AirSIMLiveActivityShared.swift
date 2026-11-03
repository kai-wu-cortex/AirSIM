import ActivityKit
import AppIntents
import Foundation

/// 主 App 与灵动岛扩展共享的活动数据，字段必须保持精简且可编码。
struct AirSIMCallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Transport: String, Codable, Hashable {
            case vowlan
            case bluetooth
            case cloud

            var title: String {
                switch self {
                case .vowlan: return "VoWLAN"
                case .bluetooth: return "VoBLE"
                case .cloud: return "云端"
                }
            }

            var systemImage: String {
                switch self {
                case .vowlan: return "wifi"
                case .bluetooth: return "wave.3.right"
                case .cloud: return "icloud.fill"
                }
            }
        }

        let callID: String
        let number: String
        let displayName: String
        let phase: Phase
        let startedAt: Date
        let transport: Transport?
        /// 模块 SIM 的蜂窝状态；只在待机状态显示，离线与通话状态不携带旧快照。
        let signalDBM: Int?
        let operatorName: String?
        let networkMode: String?
        let radioBand: String?
        let downloadBytesPerSecond: Double?
        let uploadBytesPerSecond: Double?
        /// 当前用于拨号和媒体路由的 Android Agent。字段保持可选，以兼容旧版 Relay
        /// 推送的 ContentState，并避免升级时让已存在的 Live Activity 解码失败。
        let agentDeviceName: String?
        let agentPhoneNumber: String?
        let agentKind: String?
        let pairedAgentCount: Int?
        let vowlanOnline: Bool?
        let bluetoothOnline: Bool?
        let cloudOnline: Bool?
        /// 排序后的完整待机列表；页码由主人 App 维护。可选以兼容旧版 ContentState。
        let agents: [AgentSummary]?
        /// 0-based 当前页；每页最多 5 台。旧版没有该字段时按第 1 页处理。
        let agentPage: Int?

        struct AgentSummary: Codable, Hashable, Identifiable {
            let id: String
            let name: String
            let phoneNumber: String?
            let agentKind: String?
            let vowlanOnline: Bool
            let bluetoothOnline: Bool
            let cloudOnline: Bool
            let isCurrent: Bool

            var transport: Transport? {
                if vowlanOnline { return .vowlan }
                if bluetoothOnline { return .bluetooth }
                if cloudOnline { return .cloud }
                return nil
            }
        }

        init(
            callID: String,
            number: String,
            displayName: String,
            phase: Phase,
            startedAt: Date,
            transport: Transport? = nil,
            signalDBM: Int? = nil,
            operatorName: String? = nil,
            networkMode: String? = nil,
            radioBand: String? = nil,
            downloadBytesPerSecond: Double? = nil,
            uploadBytesPerSecond: Double? = nil,
            agentDeviceName: String? = nil,
            agentPhoneNumber: String? = nil,
            agentKind: String? = nil,
            pairedAgentCount: Int? = nil,
            vowlanOnline: Bool? = nil,
            bluetoothOnline: Bool? = nil,
            cloudOnline: Bool? = nil,
            agents: [AgentSummary]? = nil,
            agentPage: Int? = nil
        ) {
            self.callID = callID
            self.number = number
            self.displayName = displayName
            self.phase = phase
            self.startedAt = startedAt
            self.transport = transport
            self.signalDBM = signalDBM
            self.operatorName = operatorName
            self.networkMode = networkMode
            self.radioBand = radioBand
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.uploadBytesPerSecond = uploadBytesPerSecond
            self.agentDeviceName = agentDeviceName
            self.agentPhoneNumber = agentPhoneNumber
            self.agentKind = agentKind
            self.pairedAgentCount = pairedAgentCount
            self.vowlanOnline = vowlanOnline
            self.bluetoothOnline = bluetoothOnline
            self.cloudOnline = cloudOnline
            self.agents = agents
            self.agentPage = agentPage
        }

        enum Phase: String, Codable, Hashable {
            case standby
            case cloudStandby = "cloud_standby"
            case incoming
            case active
            case held
            case offline

            var title: String {
                switch self {
                case .standby: return "Agent 待机"
                case .cloudStandby: return "云端在线"
                case .incoming: return "Agent 来电"
                case .active: return "通话中"
                case .held: return "通话保持"
                case .offline: return "Agent 离线"
                }
            }
        }
    }

    let moduleName: String
}

extension AirSIMCallActivityAttributes.ContentState {
    /// ActivityKit 的 stale 只表示主 App 暂时没有提交新内容，不能证明 Agent 离线。
    /// 模块离线由主 App 的真实 HTTP 探测失败显式写入 `.offline`。
    func liveActivityDisplayState(isStale: Bool) -> Self {
        // CallKit exclusively owns in-call UI. Even an activity created by an older
        // build must never render a call phase, timer or hangup button.
        guard phase == .incoming || phase == .active || phase == .held else { return self }
        return Self(
            callID: "",
            number: "",
            displayName: "等待 Agent 来电",
            phase: .standby,
            startedAt: startedAt,
            transport: transport,
            agentDeviceName: agentDeviceName,
            agentPhoneNumber: agentPhoneNumber,
            agentKind: agentKind,
            pairedAgentCount: pairedAgentCount,
            vowlanOnline: vowlanOnline,
            bluetoothOnline: bluetoothOnline,
            cloudOnline: cloudOnline,
            agents: agents,
            agentPage: agentPage
        )
    }
}

enum LiveActivityAgentPaging {
    static let pageSize = 3

    static func pageCount(for total: Int) -> Int {
        max(1, (max(0, total) + pageSize - 1) / pageSize)
    }

    static func pageIndex(_ requested: Int?, for total: Int) -> Int {
        min(max(0, requested ?? 0), pageCount(for: total) - 1)
    }

    static func slice<T>(_ values: [T], requestedPage: Int?) -> [T] {
        let page = pageIndex(requestedPage, for: values.count)
        let start = page * pageSize
        guard start < values.count else { return [] }
        return Array(values[start..<min(values.count, start + pageSize)])
    }
}

enum LiveActivityVisualPolicy {
    static func usesGlass(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase
    ) -> Bool {
        switch phase {
        case .standby, .cloudStandby, .incoming, .active, .held, .offline:
            return true
        }
    }
}

enum LiveActivityVisibilityPreference {
    static let key = "airsim.live-activity-enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func registrationToken(
        _ storedToken: String,
        defaults: UserDefaults = .standard
    ) -> String {
        isEnabled(defaults: defaults) ? storedToken : ""
    }
}

enum IslandActionLayout {
    static let buttonSide: CGFloat = 44
    static let buttonSpacing: CGFloat = 8

    static func reservedWidth(for phase: AirSIMCallActivityAttributes.ContentState.Phase) -> CGFloat {
        switch phase {
        case .incoming: return buttonSide * 2 + buttonSpacing
        case .active, .held: return buttonSide
        case .standby, .cloudStandby, .offline: return 0
        }
    }
}

enum AirSIMLiveActivityAction: String, Equatable, Sendable {
    case answer
    case reject
    case hangup
    case switchAgent
}

enum AirSIMLiveActivityActionRouting {
    static func opensApp(for transport: AirSIMCallActivityAttributes.ContentState.Transport?) -> Bool {
        transport == .bluetooth || transport == .vowlan
    }
}

enum AirSIMLiveActivityActionURL {
    static func make(action: AirSIMLiveActivityAction, callID: String) -> URL? {
        guard !callID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "airsim"
        components.host = "call"
        components.path = "/\(action.rawValue)"
        components.queryItems = [URLQueryItem(name: "call_id", value: callID)]
        return components.url
    }

    static func parse(_ url: URL) -> (action: AirSIMLiveActivityAction, callID: String)? {
        guard url.scheme?.lowercased() == "airsim",
              url.host?.lowercased() == "call",
              let action = AirSIMLiveActivityAction(
                rawValue: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
              ),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let callID = components.queryItems?.first(where: { $0.name == "call_id" })?.value,
              !callID.isEmpty else { return nil }
        return (action, callID)
    }
}

/// The Live Activity intent runs in the app process. AppModel installs this
/// handler so cloud/VoBLE/VoWLAN calls use the same authoritative path as the
/// in-app buttons instead of a hard-coded module address.
@MainActor
enum LiveActivityActionBridge {
    static var handler: ((AirSIMLiveActivityAction, String) async -> Bool)?
    static var agentSelectionHandler: ((String) async -> Bool)?

    static func perform(_ action: AirSIMLiveActivityAction, callID: String) async -> Bool {
        // A cold launch may still be initializing AppModel; give it a short window.
        for _ in 0..<20 {
            if let handler { return await handler(action, callID) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    static func selectAgent(_ agentID: String) async -> Bool {
        guard !agentID.isEmpty else { return false }
        for _ in 0..<20 {
            if let agentSelectionHandler { return await agentSelectionHandler(agentID) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

/// 灵动岛动作只走 App 内统一处理，不再保存或猜测 Android 的控制地址。

@available(iOS 17.0, *)
struct AnswerAirSIMCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "接听模块来电"
    static var openAppWhenRun = false

    @Parameter(title: "通话 ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.answer, callID: callID) else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct RejectAirSIMCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "拒绝模块来电"
    static var openAppWhenRun = false

    @Parameter(title: "通话 ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.reject, callID: callID) else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

/// 待机态翻到下一页 Android Agent；通话中不翻页，避免媒体/控制会话
/// 跨设备漂移。单台设备仍可通过行内点击选择。
@available(iOS 17.0, *)
struct SwitchAirSIMAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "下一页 Android Agent"
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.switchAgent, callID: "") else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct SelectAirSIMAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "切换到这台 Android Agent"
    static var openAppWhenRun = false

    @Parameter(title: "Agent ID") var agentID: String

    init() { agentID = "" }
    init(agentID: String) { self.agentID = agentID }

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.selectAgent(agentID) else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct HangUpAirSIMCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "挂断模块通话"
    static var openAppWhenRun = false

    @Parameter(title: "通话 ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        guard await LiveActivityActionBridge.perform(.hangup, callID: callID) else {
            throw LiveActivityActionError.appUnavailable
        }
        return .result()
    }
}

/// Background intents use the host's existing connection/binding paths. The
/// extension never changes preferences or establishes a transport on its own.
@MainActor
enum AirSIMWidgetControlBridge {
    static var handler: ((String, String, String) async -> Bool)?
    /// Installed by the app entry point, without requiring a visible scene.
    static var bootstrap: (() -> Void)?

    static func perform(action: String, expected: String, target: String) async -> Bool {
        for _ in 0..<50 {
            guard !Task.isCancelled else { return false }
            if handler == nil { bootstrap?() }
            if let handler { return await handler(action, expected, target) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

@available(iOS 17.0, *)
struct AirSIMWidgetSwitchIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "切换 AirSIM 连接"
    static var openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "操作") var action: String
    @Parameter(title: "当前值") var expected: String
    @Parameter(title: "目标值") var target: String

    init() { action = ""; expected = ""; target = "" }
    init(action: String, expected: String, target: String) {
        self.action = action; self.expected = expected; self.target = target
    }
    func perform() async throws -> some IntentResult {
        guard await AirSIMWidgetControlBridge.perform(action: action, expected: expected, target: target) else {
            throw AirSIMWidgetSwitchError.unavailable
        }
        return .result()
    }
}

private enum AirSIMWidgetSwitchError: LocalizedError {
    case unavailable
    var errorDescription: String? { "当前不能切换。请结束通话或等待小组件刷新后重试。" }
}

private enum LiveActivityActionError: LocalizedError {
    case appUnavailable

    var errorDescription: String? {
        switch self {
        case .appUnavailable: return "请在 AirSIM App 内处理该通话"
        }
    }
}

enum LiveActivityNumberFormatter {
    private static let twoDigitCountryCodes: Set<String> = [
        "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
        "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65", "66", "81", "82", "84",
        "86", "90", "91", "92", "93", "94", "95", "98",
    ]
    private static let threeDigitCountryCodes: Set<String> = [
        "211", "212", "213", "216", "218", "220", "221", "222", "223", "224", "225", "226", "227", "228", "229",
        "230", "231", "232", "233", "234", "235", "236", "237", "238", "239", "240", "241", "242", "243", "244",
        "245", "246", "247", "248", "249", "250", "251", "252", "253", "254", "255", "256", "257", "258", "260",
        "261", "262", "263", "264", "265", "266", "267", "268", "269", "290", "291", "297", "298", "299",
        "350", "351", "352", "353", "354", "355", "356", "357", "358", "359", "370", "371", "372", "373", "374",
        "375", "376", "377", "378", "379", "380", "381", "382", "383", "385", "386", "387", "389",
        "420", "421", "423", "500", "501", "502", "503", "504", "505", "506", "507", "508", "509",
        "590", "591", "592", "593", "594", "595", "596", "597", "598", "599",
        "670", "672", "673", "674", "675", "676", "677", "678", "679", "680", "681", "682", "683", "685",
        "686", "687", "688", "689", "690", "691", "692", "850", "852", "853", "855", "856", "880", "886", "960",
        "961", "962", "963", "964", "965", "966", "967", "968", "970", "971", "972", "973", "974", "975", "976",
        "977", "992", "993", "994", "995", "996", "998",
    ]

    /// Show the full synced phone number. The Live Activity is the user's own
    /// active-call surface, so a masked suffix is not useful and caused wrong
    /// country-code/last-four displays.
    static func display(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "未配置" }
        var digits = String(trimmed.filter(\.isNumber))
        guard digits.count >= 7 else { return trimmed }
        if trimmed.hasPrefix("00"), digits.hasPrefix("00") { digits.removeFirst(2) }
        return trimmed.hasPrefix("+") || trimmed.hasPrefix("00") ? "+\(digits)" : digits
    }

    private static func countryCode(_ digits: String) -> String {
        if digits.hasPrefix("1") || digits.hasPrefix("7") { return String(digits.prefix(1)) }
        let two = String(digits.prefix(2))
        if twoDigitCountryCodes.contains(two) { return two }
        let three = String(digits.prefix(3))
        if threeDigitCountryCodes.contains(three) { return three }
        return two
    }
}

