import ActivityKit
import AppIntents
import Foundation

/// 主 App 与灵动岛扩展共享的活动数据，字段必须保持精简且可编码。
struct AirSIMCallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Transport: String, Codable, Hashable {
            case vowlan
            case cloud
            case moduleLocal = "module_local"

            var title: String {
                switch self {
                case .vowlan: return "VoWLAN"
                case .cloud: return "云端"
                case .moduleLocal: return "模块本地"
                }
            }

            var systemImage: String {
                switch self {
                case .vowlan: return "wifi"
                case .cloud: return "icloud.fill"
                case .moduleLocal: return "cable.connector"
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
        let cloudOnline: Bool?

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
            cloudOnline: Bool? = nil
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
            self.cloudOnline = cloudOnline
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
                case .standby: return "模块待机"
                case .cloudStandby: return "云端在线"
                case .incoming: return "模块来电"
                case .active: return "通话中"
                case .held: return "通话保持"
                case .offline: return "模块离线"
                }
            }
        }
    }

    let moduleName: String
}

extension AirSIMCallActivityAttributes.ContentState {
    /// ActivityKit 的 stale 只表示主 App 暂时没有提交新内容，不能证明 USB 模块离线。
    /// 模块离线由主 App 的真实 HTTP 探测失败显式写入 `.offline`。
    func liveActivityDisplayState(isStale: Bool) -> Self {
        self
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

/// 灵动岛动作使用最小化模块客户端，确保扩展无需启动主 App 也能走 USB ECM 控制通话。
private enum LiveActivityCallClient {
    enum Action {
        case answer
        case reject
        case hangup

        var endpoint: String {
            switch self {
            case .answer: return "api/calls/answer"
            case .reject: return "api/calls/reject"
            case .hangup: return "api/calls/hangup"
            }
        }
    }

    private struct Status: Decodable {
        let active: ActiveCall?
    }

    private struct ActiveCall: Decodable {
        let id: String
        let direction: String
        let state: String
    }

    static func perform(_ action: Action, callID: String) async throws {
        let transport = WiredHTTPTransport()
        let statusResponse = try await transport.send(request(method: "GET", path: "api/calls/status"))
        guard (200..<300).contains(statusResponse.statusCode) else {
            throw LiveActivityCallError.httpStatus(statusResponse.statusCode)
        }
        let status = try JSONDecoder().decode(Status.self, from: statusResponse.body)
        guard status.active?.id == callID else { throw LiveActivityCallError.staleCall }

        switch action {
        case .answer, .reject:
            guard status.active?.direction == "incoming",
                  let state = status.active?.state,
                  ["incoming", "waiting"].contains(state) else {
                throw LiveActivityCallError.invalidState
            }
        case .hangup:
            guard status.active != nil else { throw LiveActivityCallError.invalidState }
        }

        let response = try await transport.send(request(method: "POST", path: action.endpoint))
        guard (200..<300).contains(response.statusCode) else {
            throw LiveActivityCallError.httpStatus(response.statusCode)
        }
        await synchronizeActivities(after: action, callID: callID)
    }

    private static func request(method: String, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://192.168.225.1:7575/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 8
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        return request
    }

    private static func synchronizeActivities(after action: Action, callID: String) async {
        for activity in Activity<AirSIMCallActivityAttributes>.activities
        where activity.content.state.callID == callID {
            switch action {
            case .answer:
                let previous = activity.content.state
                let state = AirSIMCallActivityAttributes.ContentState(
                    callID: previous.callID,
                    number: previous.number,
                    displayName: previous.displayName,
                    phase: .active,
                    startedAt: Date(),
                    transport: previous.transport,
                    agentDeviceName: previous.agentDeviceName,
                    agentPhoneNumber: previous.agentPhoneNumber,
                    agentKind: previous.agentKind,
                    pairedAgentCount: previous.pairedAgentCount,
                    vowlanOnline: previous.vowlanOnline,
                    cloudOnline: previous.cloudOnline
                )
                await activity.update(ActivityContent(state: state, staleDate: nil))
            case .reject, .hangup:
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

@available(iOS 17.0, *)
struct AnswerAirSIMCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "接听模块来电"
    static var openAppWhenRun = false

    @Parameter(title: "通话 ID") var callID: String

    init() { callID = "" }
    init(callID: String) { self.callID = callID }

    func perform() async throws -> some IntentResult {
        try await LiveActivityCallClient.perform(.answer, callID: callID)
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
        try await LiveActivityCallClient.perform(.reject, callID: callID)
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
        try await LiveActivityCallClient.perform(.hangup, callID: callID)
        return .result()
    }
}

private enum LiveActivityCallError: LocalizedError {
    case staleCall
    case invalidState
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .staleCall: return "该来电已经结束或被另一通电话替换"
        case .invalidState: return "当前通话状态不允许执行此操作"
        case let .httpStatus(code): return "模块通话接口返回 HTTP \(code)"
        }
    }
}
