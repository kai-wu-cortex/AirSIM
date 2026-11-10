import ActivityKit
import CryptoKit
import Foundation
import PushKit
import Security
import UIKit

enum VoIPPushPayloadError: LocalizedError {
    case unsupportedEvent
    case missingCallID
    case invalidCallUUID
    case invalidVirtualCall
    case expired

    var errorDescription: String? {
        switch self {
        case .unsupportedEvent: return "不是有效的来电推送"
        case .missingCallID: return "来电推送缺少 call_id"
        case .invalidCallUUID: return "来电推送缺少有效 call_uuid"
        case .invalidVirtualCall: return "虚拟来电缺少有效的本地播报内容"
        case .expired: return "来电推送已经过期"
        }
    }
}

struct IncomingVoIPCall: Equatable, Sendable {
    let agentID: String?
    let callID: String
    let uuid: UUID
    let generation: UInt64
    let number: String?
    let callerName: String?
    let expiresAt: Date?
    /// Dashboard 虚拟来电仅使用本机 TTS，不触发模块 AT 或公网 PCM。
    let isVirtual: Bool
    let isOutgoing: Bool
    let ttsText: String?
    /// 公网 PCM 仅作为 VoWLAN 控制链路不可用时的回退。完整带签名地址只保存在内存中。
    let authenticatedMediaURL: URL?
    let requestedMediaTransport: CloudMediaTransport

    init(userInfo: [AnyHashable: Any], now: Date = Date()) throws {
        guard userInfo["event"] as? String == "incoming_call" else {
            throw VoIPPushPayloadError.unsupportedEvent
        }
        guard let rawCallID = userInfo["call_id"] as? String,
              !rawCallID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoIPPushPayloadError.missingCallID
        }
        guard let rawUUID = userInfo["call_uuid"] as? String,
              let uuid = UUID(uuidString: rawUUID) else {
            throw VoIPPushPayloadError.invalidCallUUID
        }

        let expiresAt = Self.date(from: userInfo["expires_at"])
        if let expiresAt, expiresAt <= now { throw VoIPPushPayloadError.expired }

        callID = rawCallID
        agentID = userInfo["agent_id"] as? String
        self.uuid = uuid
        generation = Self.positiveUInt64(from: userInfo["generation"]) ?? 1
        number = Self.nonEmpty(userInfo["number"] as? String)
        callerName = Self.nonEmpty(userInfo["caller_name"] as? String)
        self.expiresAt = expiresAt
        isVirtual = userInfo["virtual_call"] as? Bool == true
        isOutgoing = false
        let candidateTTS = Self.nonEmpty(userInfo["tts_text"] as? String)
        if isVirtual {
            guard let candidateTTS, candidateTTS.count <= 280 else {
                throw VoIPPushPayloadError.invalidVirtualCall
            }
            ttsText = candidateTTS
        } else {
            // 普通来电绝不执行推送中夹带的文字，防止真实电话路径被意外播报。
            ttsText = nil
        }
        authenticatedMediaURL = Self.authenticatedMediaURL(from: userInfo)
        requestedMediaTransport = CloudMediaTransport(
            rawValue: Self.nonEmpty(userInfo["media_transport"] as? String) ?? ""
        ) ?? .legacyPCM
    }

    init(
        outgoingCallID: String,
        uuid: UUID,
        number: String,
        secret: String,
        mediaURL: URL,
        generation: UInt64 = 1,
        mediaTransport: CloudMediaTransport = .legacyPCM,
        agentID: String? = nil
    ) throws {
        guard !outgoingCallID.isEmpty, secret.count >= 24,
              var components = URLComponents(url: mediaURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wss", components.host?.isEmpty == false else {
            throw VoIPPushPayloadError.invalidCallUUID
        }
        components.queryItems = [
            URLQueryItem(name: "role", value: "iphone"),
            URLQueryItem(name: "token", value: secret),
        ]
        guard let authenticatedURL = components.url else {
            throw VoIPPushPayloadError.invalidCallUUID
        }
        callID = outgoingCallID
        self.agentID = agentID
        self.uuid = uuid
        self.generation = max(1, generation)
        self.number = number
        callerName = nil
        expiresAt = Date().addingTimeInterval(5 * 60 * 60)
        isVirtual = false
        isOutgoing = true
        ttsText = nil
        authenticatedMediaURL = authenticatedURL
        requestedMediaTransport = mediaTransport
    }

    init(
        bluetoothCallID: String,
        uuid: UUID,
        generation: UInt64,
        number: String?,
        agentID: String? = nil
    ) {
        callID = bluetoothCallID
        self.agentID = agentID
        self.uuid = uuid
        self.generation = max(1, generation)
        self.number = number
        callerName = nil
        expiresAt = Date().addingTimeInterval(5 * 60 * 60)
        isVirtual = false
        isOutgoing = false
        ttsText = nil
        authenticatedMediaURL = nil
        requestedMediaTransport = .legacyPCM
    }

    func matches(backendID: String?, uuid: UUID?) -> Bool {
        backendID == callID || uuid == self.uuid
    }

    private static func date(from value: Any?) -> Date? {
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func positiveUInt64(from value: Any?) -> UInt64? {
        if let number = value as? NSNumber, number.uint64Value > 0 {
            return number.uint64Value
        }
        if let text = value as? String, let number = UInt64(text), number > 0 {
            return number
        }
        return nil
    }

    private static func authenticatedMediaURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let secret = nonEmpty(userInfo["call_secret"] as? String), secret.count >= 24,
              let rawURL = nonEmpty(userInfo["media_url"] as? String),
              var components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "wss",
              components.host?.isEmpty == false else { return nil }
        components.queryItems = [
            URLQueryItem(name: "role", value: "iphone"),
            URLQueryItem(name: "token", value: secret),
        ]
        return components.url
    }
}

enum CallTransport: Equatable, Sendable {
    case vowlan
    case bluetooth
    case cloud
}

enum CallTransportPathLossAction: Equatable, Sendable {
    case endCurrentCall
}

struct LockedCallTransport: Equatable, Sendable {
    let transport: CallTransport
    let generation: UInt64

    func onPathLoss() -> CallTransportPathLossAction { .endCurrentCall }
}

enum CloudModePreference {
    static let key = "airsim.cloud-audio-relay-enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if DedicatedCallPolicy.vowlanOnly { return false }
        if defaults.object(forKey: ConnectionModePreference.key) != nil {
            return ConnectionModeRuntimePolicy(
                mode: ConnectionModePreference.selected(defaults: defaults)
            ).startsCloud
        }
        guard !LocalModePreference.isEnabled(defaults: defaults) else { return false }
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

enum LocalModePreference {
    static let key = "airsim.local-only-mode-enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: ConnectionModePreference.key) != nil {
            return ConnectionModePreference.selected(defaults: defaults) == .vowlan
        }
        return defaults.bool(forKey: key)
    }
}

enum RelayConfiguration {
    static let maintainerBundleID = "com.eric3u.airsim"
    static let maintainerRelayURL = "https://airsim-push.remotepilot.site"
    private static let legacyDJOneHubRelayURL = "https://push.remotepilot.site"

    static func effectiveURL(
        stored: String?,
        buildSetting: String?,
        bundleID: String?
    ) -> String {
        let isMaintainer = bundleID == maintainerBundleID
        for raw in [stored, buildSetting] {
            guard let value = usableURL(raw, isMaintainer: isMaintainer) else { continue }
            return value
        }
        return isMaintainer ? maintainerRelayURL : ""
    }

    /// Reject truncated xcconfig values such as "https:" and upgrade the
    /// maintainer's known relay host from http:// to https://.
    private static func usableURL(_ raw: String?, isMaintainer: Bool) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        if isMaintainer, host == "push.remotepilot.site" { return maintainerRelayURL }
        let canonical = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if isMaintainer, canonical == legacyDJOneHubRelayURL { return maintainerRelayURL }
        if isMaintainer, scheme == "http",
           host == "airsim-push.remotepilot.site" || host == "push.remotepilot.site" {
            return "https://" + host + (components.path == "/" ? "" : components.path)
        }
        return value
    }
}

enum RelayHealthValidation {
    private struct Payload: Decodable {
        let ok: Bool
        let service: String
        let version: String
        let capabilities: CapabilityFlags?
    }

    static func accepts(statusCode: Int, data: Data) -> Bool {
        version(statusCode: statusCode, data: data) != nil
    }

    /// The Relay forwards end-to-end encrypted SMS (`capabilities.e2e_sms: 1`, issue #24).
    static func supportsE2ESMS(statusCode: Int, data: Data) -> Bool {
        guard version(statusCode: statusCode, data: data) != nil,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return false }
        return payload.capabilities?.e2eSMS == true
    }

    static func version(statusCode: Int, data: Data) -> String? {
        guard statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.ok,
              payload.service == "airsim-push-relay",
              !payload.version.isEmpty else { return nil }
        return payload.version
    }
}

enum ConnectionPresentationMode: Equatable, Sendable {
    case vowlan
    case bluetooth
    case cloud
    case offline
}

struct ConnectionModePresentation: Equatable, Sendable {
    let mode: ConnectionPresentationMode
    let title: String
    let status: String
    let detail: String

    static func make(
        selectedMode: AirSIMConnectionMode = .automatic,
        vowlanOnline: Bool,
        bluetoothReady: Bool = false,
        cloudModeEnabled: Bool,
        cloudOnline: Bool
    ) -> ConnectionModePresentation {
        let selected = DialRouteSelector.preferred(
            mode: selectedMode,
            vowlanReady: vowlanOnline,
            bluetoothReady: bluetoothReady,
            cloudReady: cloudModeEnabled && cloudOnline
        )
        if selectedMode == .localDual {
            return .init(mode: selected == .vowlan ? .vowlan : (selected == .bluetooth ? .bluetooth : .offline),
                title: "VoWLAN+VoBLE",
                status: vowlanOnline && bluetoothReady ? "双链路就绪" : (vowlanOnline ? "仅 VoWLAN 在线" : (bluetoothReady ? "仅 VoBLE 在线" : "无可用本地路由")),
                detail: "同一安卓优先 VoWLAN、其次 VoBLE；云端关闭，通话途中固定链路")
        }
        if selected == .vowlan {
            return ConnectionModePresentation(
                mode: .vowlan,
                title: "VoWLAN",
                status: "已连接",
                detail: bluetoothReady || cloudOnline
                    ? "自动模式优先使用同一 Wi-Fi / 三星热点"
                    : "同一 Wi-Fi / 三星热点"
            )
        }
        if selected == .bluetooth {
            return ConnectionModePresentation(
                mode: .bluetooth,
                title: "VoBLE",
                status: "已连接",
                detail: "蓝牙控制与通话音频已认证，不经过 Relay"
            )
        }
        if selected == .cloud {
            return ConnectionModePresentation(
                mode: .cloud,
                title: "云端",
                status: cloudOnline ? "已连接" : "不可达",
                detail: cloudOnline ? "独立 Relay 与 Agent 心跳正常" : "运行云端模式自检定位故障"
            )
        }
        switch selectedMode {
        case .localDual:
            return .init(mode: .offline, title: "VoWLAN+VoBLE", status: "无可用本地路由",
                         detail: "等待所选安卓的 VoWLAN 或 VoBLE 认证；云端已关闭")
        case .vowlan:
            return .init(mode: .vowlan, title: "VoWLAN", status: "不可达",
                         detail: "尚未发现已配对且通过鉴权的 VoWLAN Agent")
        case .bluetooth:
            return .init(mode: .bluetooth, title: "VoBLE", status: "不可达",
                         detail: "蓝牙 Agent 尚未完成连接与应用层认证")
        case .cloud:
            return .init(mode: .cloud, title: "云端", status: "不可达",
                         detail: "运行云端模式自检定位故障")
        case .automatic:
            return .init(mode: .offline, title: "自动", status: "无可用路由",
                         detail: "正在按 VoWLAN、VoBLE、云端顺序查找拨号路由")
        }
    }
}

enum CloudSelfTestStepID: String, CaseIterable, Sendable {
    case configuration
    case relayIdentity
    case deviceRegistration
    case agentDirectory
    case agentHeartbeat
    case commandRouting
}

enum CloudSelfTestStepState: Equatable, Sendable {
    case pending
    case running
    case passed
    case failed
}

struct CloudSelfTestStep: Identifiable, Equatable, Sendable {
    let id: CloudSelfTestStepID
    let title: String
    var state: CloudSelfTestStepState
    var detail: String
}

extension CloudSelfTestStepState {
    var diagnosticLabel: String {
        switch self {
        case .pending: return "PENDING"
        case .running: return "RUNNING"
        case .passed: return "PASS"
        case .failed: return "FAIL"
        }
    }
}

struct CloudSelfTestReport: Equatable, Sendable {
    var steps: [CloudSelfTestStep]
    var completedAt: Date?

    static let initial = CloudSelfTestReport(
        steps: [
            CloudSelfTestStep(id: .configuration, title: "本机配置", state: .pending, detail: "等待检查"),
            CloudSelfTestStep(id: .relayIdentity, title: "Relay 身份", state: .pending, detail: "等待检查"),
            CloudSelfTestStep(id: .deviceRegistration, title: "设备注册", state: .pending, detail: "等待检查"),
            CloudSelfTestStep(id: .agentDirectory, title: "Agent 记录", state: .pending, detail: "查询 Relay 已登记的 Android Agent"),
            CloudSelfTestStep(id: .agentHeartbeat, title: "Agent 心跳", state: .pending, detail: "检查最近 150 秒心跳"),
            CloudSelfTestStep(id: .commandRouting, title: "命令路由", state: .pending, detail: "检查 Agent 是否支持定向接听/挂断"),
        ],
        completedAt: nil
    )

    var allPassed: Bool {
        completedAt != nil && steps.allSatisfy { $0.state == .passed }
    }

    /// Copyable diagnostic output. Contains only status, device hints, Agent
    /// metadata and errors; never tokens, secrets, numbers or SMS content.
    var copyText: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["AirSIM Cloud Self-Test"]
        if let completedAt {
            lines.append("completed_at=\(formatter.string(from: completedAt))")
        }
        lines.append("all_passed=\(allPassed)")
        for step in steps {
            lines.append("[\(step.state.diagnosticLabel)] \(step.title)")
            lines.append("  \(step.detail)")
        }
        return lines.joined(separator: "\n")
    }

    mutating func update(_ id: CloudSelfTestStepID, state: CloudSelfTestStepState, detail: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = state
        steps[index].detail = detail
    }

    mutating func fail(_ id: CloudSelfTestStepID, detail: String) {
        update(id, state: .failed, detail: detail)
        for index in steps.indices where steps[index].state == .pending {
            steps[index].detail = "未执行：前序检查未通过"
        }
        completedAt = Date()
    }
}

struct CloudModeCapabilities: Equatable, Sendable {
    let pushKitAndCallKit = true
    let apnsSMSNotifications = true
    let notificationRelay = true
    let publicPCM: Bool
    let remoteModuleAccess: Bool

    init(isEnabled: Bool) {
        publicPCM = isEnabled
        remoteModuleAccess = isEnabled
    }
}

enum PushRegistrationRetryPolicy {
    static func needsRetry(agentRegistered: Bool, relayRegistered: Bool) -> Bool {
        !agentRegistered || !relayRegistered
    }

    static func shouldAttemptRelay(now: Date, retryAfter: Date) -> Bool {
        now >= retryAfter
    }

    static func quotaRetryDate(now: Date) -> Date {
        // Worker free-tier requests reset at midnight UTC. Recheck sooner if the
        // account is upgraded before then, without retrying every 30 seconds.
        let nextMidnightUTC = Date(timeIntervalSince1970:
            (floor(now.timeIntervalSince1970 / 86_400) + 1) * 86_400 + 10)
        return min(now.addingTimeInterval(300), nextMidnightUTC)
    }
}

enum PushRegistrationAttemptPolicy {
    static func shouldRegisterAgent<Route: Equatable>(
        fingerprint: String,
        route: Route,
        lastFingerprint: String?,
        lastRoute: Route?
    ) -> Bool {
        fingerprint != lastFingerprint || route != lastRoute
    }

    static func shouldResetBackoff<Route: Equatable>(
        previousRoute: Route,
        currentRoute: Route
    ) -> Bool {
        previousRoute != currentRoute
    }
}

/// Registration and backoff belong to each authenticated gateway, not the last
/// selected phone. One unavailable/old gateway must not starve another one.
struct PushRegistrationLedger<Route: Equatable> {
    private struct Entry {
        let route: Route
        let fingerprint: String
        let succeeded: Bool
        let retryAfter: Date
    }
    private var entries: [Entry] = []
    func needsRegistration(_ route: Route, fingerprint: String) -> Bool {
        !entries.contains { $0.route == route && $0.fingerprint == fingerprint && $0.succeeded }
    }
    func shouldAttempt(_ route: Route, fingerprint: String, now: Date = Date()) -> Bool {
        guard let entry = entries.first(where: { $0.route == route && $0.fingerprint == fingerprint }) else { return true }
        return !entry.succeeded && now >= entry.retryAfter
    }
    mutating func record(_ route: Route, fingerprint: String, succeeded: Bool, now: Date = Date()) {
        entries.removeAll { $0.route == route }
        entries.append(Entry(route: route, fingerprint: fingerprint, succeeded: succeeded,
                             retryAfter: now.addingTimeInterval(30)))
    }
    mutating func retain(_ routes: [Route]) {
        entries.removeAll { entry in !routes.contains(entry.route) }
    }
}

enum PushDiagnostics {
    // Never persist localizedDescription: HTTP bodies may contain credentials,
    // telephone numbers or signed URLs. Release diagnostics are opt-in trace only.
    static func record(_ title: String, error: Error? = nil, fields: [String: String] = [:]) {
        var safe = fields
        if let error {
            let ns = error as NSError
            safe["error_domain"] = ns.domain
            safe["error_code"] = String(ns.code)
            if case let APIError.http(status, _) = error { safe["http_status"] = String(status) }
            if case let CloudAgentStatusError.relayHTTP(status) = error { safe["http_status"] = String(status) }
            if case CloudAgentStatusError.requestLimitExceeded = error { safe["failure_kind"] = "relay_quota" }
        }
        let details = safe
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP", category: "pushkit", phase: error == nil ? "state" : "failure",
                title: title, fields: details)
        }
    }
}

enum PushDeviceIdentity {
    static func deviceID(deviceSecret: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(deviceSecret.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}

enum CallTransportPolicy {
    static func preferred(
        mode: AirSIMConnectionMode,
        vowlanReady: Bool,
        cloudMediaAvailable: Bool,
        cloudMediaEnabled: Bool = true
    ) -> CallTransport? {
        if DedicatedCallPolicy.vowlanOnly { return vowlanReady ? .vowlan : nil }
        switch mode {
        case .automatic:
            if vowlanReady { return .vowlan }
            if cloudMediaEnabled && cloudMediaAvailable { return .cloud }
            return nil
        case .cloud:
            // Explicit cloud means Relay media only. Falling back to a reachable
            // VoWLAN route here made the UI show cloud while the call silently
            // ran over the LAN, with no cloud/Relay events in Verbose.
            guard cloudMediaEnabled && cloudMediaAvailable else { return nil }
            return .cloud
        case .vowlan, .localDual:
            return vowlanReady ? .vowlan : nil
        case .bluetooth:
            return nil
        }
    }
}

enum CloudAgentStatusError: LocalizedError {
    case unavailable
    case invalidRelayURL
    case invalidResponse
    case requestLimitExceeded
    case relayHTTP(Int)

    static func relayFailure(statusCode: Int, data: Data) -> Self {
        if statusCode == 429,
           String(data: data, encoding: .utf8)?.contains("1027") == true {
            return .requestLimitExceeded
        }
        return .relayHTTP(statusCode)
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: return "云端状态尚未配置"
        case .invalidRelayURL: return "Relay 必须使用 HTTPS"
        case .invalidResponse: return "Relay 状态响应无效"
        case .requestLimitExceeded: return "Relay 每日请求额度已用尽（Cloudflare 1027），请等待额度重置或升级 Workers 套餐"
        case let .relayHTTP(statusCode): return "Relay 请求失败（HTTP \(statusCode)）"
        }
    }
}

enum CloudCommandError: LocalizedError {
    case cloudModeDisabled
    case unavailable
    case invalidResponse
    case failed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .cloudModeDisabled: return "云端模式已关闭"
        case .unavailable: return "模块云端控制通道尚未连接"
        case .invalidResponse: return "Relay 返回了无效的云端控制响应"
        case let .failed(message): return message
        case .timeout: return "等待模块执行云端命令超时"
        }
    }
}

private struct CloudCommandEnqueueResponse: Decodable {
    struct Call: Decodable {
        let agentID: String?
        let callID: String
        let callUUID: String
        let generation: UInt64?
        let callSecret: String
        let mediaURL: String
        let mediaTransport: CloudMediaTransport?
        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
            case agentID = "agent_id"
            case callUUID = "call_uuid"
            case generation
            case callSecret = "call_secret"
            case mediaURL = "media_url"
            case mediaTransport = "media_transport"
        }
    }
    let accepted: Bool
    let commandID: String
    let status: String
    let agentConnected: Bool
    let call: Call?
    enum CodingKeys: String, CodingKey {
        case accepted
        case commandID = "command_id"
        case status
        case agentConnected = "agent_connected"
        case call
    }
}

private struct CloudCommandResultResponse: Decodable {
    struct Result: Decodable {
        let dialing: Bool?
        let sent: Bool?
        let segments: Int?
    }
    let commandID: String
    let status: String
    let result: Result?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case status, result, error
    }
}

enum RelayEndpoint {
    static func url(base: String, path: String) -> URL? {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, requestedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum VoIPPushToken {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

enum APNsEnvironment {
    static func relayValue(entitlement: String?) -> String {
        entitlement == "production" ? "production" : "sandbox"
    }

    static var current: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "AirSIMAPNSEnvironment") as? String
        return configured == "production" ? "production" : "sandbox"
    }
}

struct AgentPushRegistration: Encodable, Equatable, Sendable {
    let cloudModeEnabled: Bool
    var localMode: Bool = false
    let deviceID: String
    let deviceSecret: String
    let token: String
    let alertToken: String
    let watchVoIPToken: String
    let watchBundleID: String
    let liveActivityPushToStartToken: String
    let bundleID: String
    let environment: String
    let relayURL: String
    var mediaTransport: String = CloudMediaTransport.legacyPCM.rawValue
    var appMediaCapabilities: [String] = [CloudMediaTransport.legacyPCM.rawValue]
    var forceLegacyPCM: Bool = true
    var vowlanSecret: String? = nil
    var notificationForwarding: NotificationForwardingConfig? = nil

    enum CodingKeys: String, CodingKey {
        case cloudModeEnabled = "cloud_enabled"
        case localMode = "local_mode"
        case deviceID = "device_id"
        case deviceSecret = "device_secret"
        case token = "voip_token"
        case alertToken = "alert_token"
        case watchVoIPToken = "watch_voip_token"
        case watchBundleID = "watch_bundle_id"
        case liveActivityPushToStartToken = "live_activity_push_to_start_token"
        case liveActivityPresentation = "live_activity_presentation"
        case bundleID = "bundle_id"
        case environment
        case relayURL = "relay_url"
        case mediaTransport = "media_transport"
        case appMediaCapabilities = "app_media_capabilities"
        case forceLegacyPCM = "force_legacy_pcm"
        case vowlanSecret = "vowlan_secret"
        case notificationForwarding = "notification_forwarding"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(cloudModeEnabled, forKey: .cloudModeEnabled)
        try values.encode(localMode, forKey: .localMode)
        try values.encodeIfPresent(vowlanSecret, forKey: .vowlanSecret)
        try values.encodeIfPresent(notificationForwarding, forKey: .notificationForwarding)
        guard !localMode else { return }

        try values.encode(deviceID, forKey: .deviceID)
        try values.encode(deviceSecret, forKey: .deviceSecret)
        try values.encode(token, forKey: .token)
        try values.encode(alertToken, forKey: .alertToken)
        try values.encode(watchVoIPToken, forKey: .watchVoIPToken)
        try values.encode(watchBundleID, forKey: .watchBundleID)
        try values.encode(liveActivityPushToStartToken, forKey: .liveActivityPushToStartToken)
        // The island is a device-status surface, not a second call UI. Relay
        // must not start another activity or replace its multi-device snapshot.
        try values.encode("agent_status", forKey: .liveActivityPresentation)
        try values.encode(bundleID, forKey: .bundleID)
        try values.encode(environment, forKey: .environment)
        try values.encode(relayURL, forKey: .relayURL)
        try values.encode(mediaTransport, forKey: .mediaTransport)
        try values.encode(appMediaCapabilities, forKey: .appMediaCapabilities)
        try values.encode(forceLegacyPCM, forKey: .forceLegacyPCM)
    }

    static func local(
        vowlanSecret: String,
        notificationForwarding: NotificationForwardingConfig? = nil
    ) -> Self {
        .init(
            cloudModeEnabled: false,
            localMode: true,
            deviceID: "",
            deviceSecret: "",
            token: "",
            alertToken: "",
            watchVoIPToken: "",
            watchBundleID: "",
            liveActivityPushToStartToken: "",
            bundleID: "",
            environment: "",
            relayURL: "",
            vowlanSecret: vowlanSecret,
            notificationForwarding: notificationForwarding
        )
    }
}

struct AgentPushStatus: Decodable, Sendable {
    let localMode: Bool?
    let cloudModeEnabled: Bool?
    let configured: Bool
    let callPushReady: Bool
    let messagePushReady: Bool
    let environment: String?
    let relayURL: String?
    let lastError: String?

    var preservesLocalPairing: Bool {
        if let localMode { return localMode }
        // Older AVF Agents omit local_mode but only report configured without
        // cloud credentials for a local pairing. Never infer from HTTP 200 alone.
        return configured && cloudModeEnabled == false && !callPushReady && !messagePushReady
            && (relayURL ?? "").isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case localMode = "local_mode"
        case cloudModeEnabled = "cloud_enabled"
        case configured
        case callPushReady = "call_push_ready"
        case messagePushReady = "message_push_ready"
        case environment
        case relayURL = "relay_url"
        case lastError = "last_error"
    }
}

/// 只向设置页暴露可诊断的凭据状态，不泄露设备密钥或完整 Push token。
struct PushRegistrationReadiness: Equatable, Sendable {
    let deviceIdentityReady: Bool
    let voIPTokenReady: Bool
    let alertTokenReady: Bool
    let relayURLReady: Bool
    let deviceIDHint: String?
    let environment: String
}

enum RemoteSMSPushError: LocalizedError {
    case unsupportedEvent
    case incomplete
    case invalidTimestamp
    case undecryptable
    case locked
    /// A plaintext push naming an agent whose SMS arrive encrypted (issue #24).
    case unencryptedFromEncryptedAgent

    var errorDescription: String? {
        switch self {
        case .unsupportedEvent: return "不是有效的新短信推送"
        case .incomplete: return "短信推送缺少必要字段"
        case .invalidTimestamp: return "短信推送时间无效"
        case .undecryptable: return "加密短信无法解密"
        case .locked: return "解锁前无法读取短信密钥"
        case .unencryptedFromEncryptedAgent: return "已忽略未加密的短信推送"
        }
    }
}

struct IncomingRemoteSMS: Equatable, Sendable {
    let deliveryID: String
    let agentID: String?
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date
    let contentTruncated: Bool
    let simSlot: String?

    /// End-to-end encrypted pushes (issue #24) are opened with the agent's stored key; a plaintext
    /// push from an agent that has a key is refused, since only a forger sends one.
    init(userInfo: [AnyHashable: Any], keyStore: any E2EKeyStoring = KeychainE2EKeyStore.shared) throws {
        let decrypted: E2ESMS.Plaintext?
        switch E2ESMSPush.open(userInfo, store: keyStore) {
        case .notSMS: throw RemoteSMSPushError.unsupportedEvent
        case .plaintext: decrypted = nil
        case .decrypted(let sms): decrypted = sms
        case .locked: throw RemoteSMSPushError.locked
        case .undecryptable: throw RemoteSMSPushError.undecryptable
        case .unencryptedFromEncryptedAgent: throw RemoteSMSPushError.unencryptedFromEncryptedAgent
        }
        guard let deliveryID = Self.nonEmpty(userInfo["delivery_id"] as? String),
              let sender = decrypted.map({ E2ESMSPush.displaySender($0.sender) })
                ?? Self.nonEmpty(userInfo["sender"] as? String),
              let content = Self.nonEmpty(decrypted?.content ?? (userInfo["content"] as? String)) else {
            throw RemoteSMSPushError.incomplete
        }
        guard let rawTimestamp = userInfo["timestamp"] as? String,
              let timestamp = Self.parseTimestamp(rawTimestamp) else {
            throw RemoteSMSPushError.invalidTimestamp
        }
        self.deliveryID = deliveryID
        agentID = Self.nonEmpty(userInfo["agent_id"] as? String)
        self.sender = sender
        self.content = content
        // Only plaintext pushes carry an extracted code.
        code = decrypted == nil ? Self.nonEmpty(userInfo["code"] as? String) : nil
        self.timestamp = timestamp
        contentTruncated = decrypted?.truncated ?? (userInfo["content_truncated"] as? Bool ?? false)
        // A decrypted SMS takes its SIM slot only from the sealed text: the Relay could add a clear one.
        if let decrypted {
            simSlot = E2ESMSPush.simSlot(decrypted.simSlot)
        } else {
            simSlot = Self.nonEmpty(userInfo["sim_slot"] as? String)
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        // Agent 使用 RFC3339Nano；Foundation 的默认 ISO8601 格式不接受小数秒。
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    var message: SMSMessage {
        SMSMessage(
            sender: sender,
            content: content,
            code: code,
            timestamp: timestamp,
            deliveryID: deliveryID,
            direction: .incoming,
            sourceAgentID: agentID,
            simSlot: simSlot
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// PushKit 是被系统挂起或终止后恢复 CallKit 的入口；本地长轮询仍作为前台兜底。
@MainActor
final class VoIPPushController: NSObject {
    static let shared = VoIPPushController()

    private enum Keys {
        static let token = "airsim.voip-push-token"
        static let alertToken = "airsim.alert-push-token"
        static let watchVoIPToken = "airsim.watch-voip-push-token"
        static let watchBundleID = "airsim.watch-bundle-id"
        static let liveActivityPushToStartToken = "airsim.live-activity-push-to-start-token"
        static let deviceID = "airsim.push-device-id"
        static let relayURL = "airsim.push-relay-url"
        static let keychainService = "com.example.airsim.push"
        static let keychainAccount = "device-secret"
    }

    private var registry: PKPushRegistry?
    private var agentRegistrations = PushRegistrationLedger<LocalAgentRoute>()
    private var lastRelayRegisteredFingerprint: String?
    private var registrationInFlight = false
    private let pairingGate = SamsungPairingRegistrationGate()
    private var registrationPending = false
    private var relayRegistrationFailures = 0
    private var nextRelayRegistrationAttempt = Date.distantPast
    private var registrationRetryTask: Task<Void, Never>?
    /// Supplies only currently authenticated, non-forgotten gateways.
    var registrationAPIs: (() -> [AirSIMAPI])?
    var callInProgress: () -> Bool = { false }
    private var pendingRegistrationAPIs: [AirSIMAPI] = []
    private var registrationEpoch: UInt64 = 0
    private var activityKitRegistrationStarted = false
    private var activityKitRegistrationTasks: [Task<Void, Never>] = []
    private var observedActivityIDs = Set<String>()

    func start() {
        guard CloudSignalingPreference.isEnabled() else { return }
        startActivityKitRegistration()
        if let registry {
            // 重新赋值会让系统在授权或网络状态变化后再次核对现有凭据。
            registry.desiredPushTypes = [.voIP]
#if DEBUG
            print("[AirSIM PushKit] 已刷新 VoIP token 注册")
#endif
            return
        }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
#if DEBUG
        print("[AirSIM PushKit] 已创建 VoIP token 注册")
#endif
    }

    func setSignalingEnabled(_ enabled: Bool) {
        resetRegistrationBackoff()
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        registrationPending = false

        if enabled {
            start()
            UIApplication.shared.registerForRemoteNotifications()
            Task { await syncRegistration() }
        } else {
            pendingRegistrationAPIs.removeAll()
            registry?.desiredPushTypes = []
            registry?.delegate = nil
            registry = nil
            activityKitRegistrationTasks.forEach { $0.cancel() }
            activityKitRegistrationTasks.removeAll()
            activityKitRegistrationStarted = false
            observedActivityIDs.removeAll()
            UIApplication.shared.unregisterForRemoteNotifications()
#if DEBUG
            print("[AirSIM Signaling] 已停用 PushKit/APNs")
#endif
        }
    }

    func setLocalModeEnabled(_ enabled: Bool) {
        setSignalingEnabled(!enabled)
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        if enabled, #available(iOS 17.2, *),
           let token = Activity<AirSIMCallActivityAttributes>.pushToStartToken {
            UserDefaults.standard.set(
                VoIPPushToken.hex(token),
                forKey: Keys.liveActivityPushToStartToken
            )
        }
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    private func startActivityKitRegistration() {
        guard CloudSignalingPreference.isEnabled(), !activityKitRegistrationStarted else { return }
        if #available(iOS 17.2, *) {
            activityKitRegistrationStarted = true
            let pushToStartTask = Task { @MainActor [weak self] in
                for await token in Activity<AirSIMCallActivityAttributes>.pushToStartTokenUpdates {
                    guard let self, !Task.isCancelled else { return }
                    guard CloudSignalingPreference.isEnabled(),
                          LiveActivityVisibilityPreference.isEnabled() else { continue }
                    UserDefaults.standard.set(
                        VoIPPushToken.hex(token),
                        forKey: Keys.liveActivityPushToStartToken
                    )
                    resetRegistrationBackoff()
                    await syncRegistration()
                }
            }
            let activityUpdateTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for activity in Activity<AirSIMCallActivityAttributes>.activities {
                    observeLiveActivity(activity)
                }
                for await activity in Activity<AirSIMCallActivityAttributes>.activityUpdates {
                    guard !Task.isCancelled else { return }
                    observeLiveActivity(activity)
                }
            }
            activityKitRegistrationTasks = [pushToStartTask, activityUpdateTask]
        }
    }

    func observeLiveActivity(_ activity: Activity<AirSIMCallActivityAttributes>) {
        guard LiveActivityVisibilityPreference.isEnabled() else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        guard CloudSignalingPreference.isEnabled() else { return }
        guard observedActivityIDs.insert(activity.id).inserted else { return }
        Task { @MainActor [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self else { return }
                await registerLiveActivityUpdateToken(
                    VoIPPushToken.hex(token),
                    activityID: activity.id,
                    callID: activity.content.state.callID
                )
            }
        }
    }

    private func registerLiveActivityUpdateToken(
        _ token: String,
        activityID: String,
        callID: String
    ) async {
        guard CloudSignalingPreference.isEnabled(),
              LiveActivityVisibilityPreference.isEnabled() else { return }
        guard let registration = currentRegistration(),
              let url = RelayEndpoint.url(
                base: registration.relayURL,
                path: "v1/live-activities/register"
              ) else { return }
        struct Body: Encodable {
            let deviceID: String
            let deviceSecret: String
            let activityID: String
            let callID: String
            let updateToken: String
            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case deviceSecret = "device_secret"
                case activityID = "activity_id"
                case callID = "call_id"
                case updateToken = "update_token"
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(
            deviceID: registration.deviceID,
            deviceSecret: registration.deviceSecret,
            activityID: activityID,
            callID: callID,
            updateToken: token
        ))
        let configuration = URLSessionConfiguration.ephemeral
        _ = try? await RelayEgressGate.shared.send(request)
    }

    func storeAlertToken(_ token: Data) {
        let value = VoIPPushToken.hex(token)
        guard UserDefaults.standard.string(forKey: Keys.alertToken) != value else { return }
        UserDefaults.standard.set(value, forKey: Keys.alertToken)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    func clearAlertToken() {
        UserDefaults.standard.removeObject(forKey: Keys.alertToken)
        resetRegistrationBackoff()
    }

    func storeWatchVoIPRegistration(token: String, bundleID: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !bundleID.isEmpty else { return }
        guard UserDefaults.standard.string(forKey: Keys.watchVoIPToken) != token
            || UserDefaults.standard.string(forKey: Keys.watchBundleID) != bundleID else { return }
        UserDefaults.standard.set(token, forKey: Keys.watchVoIPToken)
        UserDefaults.standard.set(bundleID, forKey: Keys.watchBundleID)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    func updateRelayURL(_ value: String) {
        let previous = configuredRelayURL()
        let normalized = RelayConfiguration.effectiveURL(
            stored: value,
            buildSetting: nil,
            bundleID: Bundle.main.bundleIdentifier
        )
        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.relayURL)
        } else {
            UserDefaults.standard.set(normalized, forKey: Keys.relayURL)
        }
        // E2E SMS keys belong to the Relay they were negotiated through (issue #24).
        E2EPairingPolicy.relayChanged(from: previous, to: configuredRelayURL(), store: KeychainE2EKeyStore.shared)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    func configuredRelayURL() -> String {
        RelayConfiguration.effectiveURL(
            stored: UserDefaults.standard.string(forKey: Keys.relayURL),
            buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
            bundleID: Bundle.main.bundleIdentifier
        )
    }

    func resumeRegistrationAfterForeground() {
        // A foreground transition starts a new bounded recovery attempt, without
        // invalidating successfully registered fingerprints or APNs tokens.
        if relayRegistrationFailures >= 5 {
            relayRegistrationFailures = 0
            nextRelayRegistrationAttempt = .distantPast
        }
        Task { await syncRegistration() }
    }

    func syncRegistration(with requestedAPI: AirSIMAPI? = nil) async {
        guard CloudSignalingPreference.isEnabled(), !RelayEgressGate.shared.isBlocked else { return }
        var routes = registrationAPIs?() ?? []
        if let requestedAPI, !routes.contains(where: { $0.route == requestedAPI.route }) {
            routes.append(requestedAPI)
        }
        for api in routes where !pendingRegistrationAPIs.contains(where: { $0.route == api.route }) {
            pendingRegistrationAPIs.append(api)
        }
        if callInProgress() || CallKitController.shared.currentCallIsAnswered {
            scheduleRegistrationRetry(after: 30)
            return
        }
        if registrationInFlight {
            registrationPending = true
            return
        }
        if relayRegistrationFailures >= 5, UIApplication.shared.applicationState == .active,
           Date() >= nextRelayRegistrationAttempt {
            relayRegistrationFailures = 0
        }
        guard let registration = currentRegistration() else { return }
        let epoch = registrationEpoch
        let fingerprint = [
            registration.token, registration.alertToken, registration.watchVoIPToken,
            registration.watchBundleID, registration.liveActivityPushToStartToken,
            registration.bundleID, registration.environment,
            registration.relayURL, registration.deviceID
        ].joined(separator: "|")
        registrationInFlight = true
        defer {
            registrationInFlight = false
            if registrationPending {
                registrationPending = false
                Task { await syncRegistration() }
            }
        }
        // Refresh APNs even without a reachable local gateway (e.g. Bluetooth
        // mode or immediately after a TestFlight token/environment change).
        var relayRegistered = lastRelayRegisteredFingerprint == fingerprint
        if !relayRegistered, relayRegistrationFailures < 5, PushRegistrationRetryPolicy.shouldAttemptRelay(
            now: Date(), retryAfter: nextRelayRegistrationAttempt
        ) {
            do {
                try await registerDirectlyWithRelay(registration)
                relayRegistrationFailures = 0
                lastRelayRegisteredFingerprint = fingerprint
                relayRegistered = true
                nextRelayRegistrationAttempt = .distantPast
                PushDiagnostics.record("Relay 推送注册成功", fields: ["environment": registration.environment])
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                relayRegistrationFailures += 1
                if case CloudAgentStatusError.requestLimitExceeded = error {
                    nextRelayRegistrationAttempt = PushRegistrationRetryPolicy.quotaRetryDate(now: Date())
                } else {
                    nextRelayRegistrationAttempt = Date().addingTimeInterval(min(300, 15 * pow(2, Double(relayRegistrationFailures))))
                }
                if relayRegistrationFailures >= 5 {
                    nextRelayRegistrationAttempt = Date().addingTimeInterval(900)
                }
                var failureKind = error is URLError ? "relay_network" : "relay_registration"
                if case let CloudAgentStatusError.relayHTTP(status) = error, status == 401 || status == 403 {
                    failureKind = "relay_authentication"
                }
                PushDiagnostics.record("Relay 推送注册失败", error: error, fields: [
                    "failure_kind": failureKind,
                    "retry_attempt": String(relayRegistrationFailures),
                    "retry_exhausted": String(relayRegistrationFailures >= 5),
                    "environment": registration.environment
                ])
            }
        }
        var needsAgentRetry = false
        while !pendingRegistrationAPIs.isEmpty {
            guard CloudSignalingPreference.isEnabled(), !RelayEgressGate.shared.isBlocked,
                  epoch == registrationEpoch else { return }
            let api = pendingRegistrationAPIs.removeFirst()
            // A route can be revoked while another gateway's request awaits.
            if let provider = registrationAPIs,
               !provider().contains(where: { $0.route == api.route }) { continue }
            guard agentRegistrations.needsRegistration(api.route, fingerprint: fingerprint) else { continue }
            guard agentRegistrations.shouldAttempt(api.route, fingerprint: fingerprint),
                  pairingGate.beginAgentWrite() else { needsAgentRetry = true; continue }
            do {
                let status = try await api.pushStatus()
                guard CloudSignalingPreference.isEnabled(), !RelayEgressGate.shared.isBlocked,
                      epoch == registrationEpoch else {
                    pairingGate.endAgentWrite()
                    return
                }
                if let provider = registrationAPIs,
                   !provider().contains(where: { $0.route == api.route }) {
                    pairingGate.endAgentWrite()
                    continue
                }
                if status.preservesLocalPairing {
                    PushDiagnostics.record("保留网关纯本地配对，未写入云端凭据")
                } else {
                    try await api.registerVoIPPush(registration)
                    PushDiagnostics.record("网关推送注册成功", fields: ["environment": registration.environment])
                }
                agentRegistrations.record(api.route, fingerprint: fingerprint, succeeded: true)
            } catch {
                agentRegistrations.record(api.route, fingerprint: fingerprint, succeeded: false)
                needsAgentRetry = true
                PushDiagnostics.record("网关推送注册失败", error: error, fields: ["failure_kind": "gateway_registration"])
            }
            pairingGate.endAgentWrite()
        }
        if let provider = registrationAPIs { agentRegistrations.retain(provider().map(\.route)) }
        if needsAgentRetry || (!relayRegistered && relayRegistrationFailures < 5) {
            scheduleRegistrationRetry(after: needsAgentRetry ? 30 : max(30, nextRelayRegistrationAttempt.timeIntervalSinceNow))
        } else {
            registrationRetryTask?.cancel()
            registrationRetryTask = nil
        }
    }

    func registrationReadiness() -> PushRegistrationReadiness {
        let defaults = UserDefaults.standard
        let secret = Self.loadOrCreateDeviceSecret()
        let deviceID = secret.map(PushDeviceIdentity.deviceID(deviceSecret:))
        let relayURL = configuredRelayURL()
        let hint = deviceID?.suffix(8).uppercased()
        return PushRegistrationReadiness(
            deviceIdentityReady: deviceID?.isEmpty == false,
            voIPTokenReady: defaults.string(forKey: Keys.token)?.isEmpty == false,
            alertTokenReady: defaults.string(forKey: Keys.alertToken)?.isEmpty == false,
            relayURLReady: RelayEndpoint.url(base: relayURL, path: "healthz") != nil,
            deviceIDHint: hint.map { "…\($0)" },
            environment: APNsEnvironment.current
        )
    }

    /// 只验证控制面，不发起电话或短信：本机凭据 → Relay 身份 → 注册鉴权 → Agent 心跳。
    func runCloudSelfTest(
        onUpdate: @MainActor @escaping (CloudSelfTestReport) -> Void = { _ in }
    ) async -> CloudSelfTestReport {
        var report = CloudSelfTestReport.initial

        guard !RelayEgressGate.shared.isBlocked,
              !UserDefaults.standard.bool(forKey: RelayEgressGate.persistenceKey) else {
            report.fail(.configuration, detail: "纯本地模式已开启，禁止云端自检")
            onUpdate(report)
            return report
        }

        report.update(.configuration, state: .running, detail: "设备身份 · PushKit/通知 Token · Relay URL")
        onUpdate(report)
        let readiness = registrationReadiness()
        var missing: [String] = []
        if !readiness.relayURLReady { missing.append("Relay HTTPS 地址无效") }
        if !readiness.deviceIdentityReady { missing.append("设备身份未生成") }
        if !readiness.voIPTokenReady { missing.append("PushKit token 未就绪") }
        if !readiness.alertTokenReady { missing.append("通知 token 未就绪") }
        guard missing.isEmpty, let registration = currentRegistration(allowLocalMode: true) else {
            report.fail(.configuration, detail: missing.isEmpty ? "设备注册信息不完整" : missing.joined(separator: "；"))
            onUpdate(report)
            return report
        }
        var configDetail = [
            "检查方式=手动自检（不改变连接模式）",
            "设备=\(readiness.deviceIDHint ?? "已生成")",
            "APNs=\(readiness.environment)",
            "PushKit=\(readiness.voIPTokenReady ? "就绪" : "缺失")",
            "通知Token=\(readiness.alertTokenReady ? "就绪" : "缺失")",
        ].joined(separator: "\n")
        if let host = URL(string: registration.relayURL)?.host {
            configDetail += "\nRelay=\(host)"
        }
        report.update(.configuration, state: .passed, detail: configDetail)
        onUpdate(report)

        report.update(.relayIdentity, state: .running, detail: "验证 AirSIM Relay 服务身份")
        onUpdate(report)
        do {
            let version = try await fetchRelayHealthVersion(registration: registration)
            report.update(.relayIdentity, state: .passed, detail: "airsim-push-relay · v\(version)")
            onUpdate(report)
        } catch {
            report.fail(.relayIdentity, detail: "Relay 不可达或服务身份不匹配：\(error.localizedDescription)")
            onUpdate(report)
            return report
        }

        report.update(.deviceRegistration, state: .running, detail: "读取并核验 Relay 已登记的设备凭据，不重复写入注册")
        onUpdate(report)
        let status: CloudAgentStatus
        do {
            status = try await fetchCloudAgentStatusForDiagnostics(allowLocalMode: true, attempts: 2)
            report.update(.deviceRegistration, state: .passed,
                detail: "Relay 已通过现有设备凭据鉴权；正常注册同步独立运行，此项不代表推送已送达。")
            onUpdate(report)
        } catch {
            report.fail(.deviceRegistration, detail: "注册状态未能核实：\(error.localizedDescription)；网络超时不等于设备未注册。")
            onUpdate(report)
            return report
        }
        report.update(.agentDirectory, state: .running, detail: "分析本次实时返回的安卓记录")
        onUpdate(report)
        guard !status.agents.isEmpty else {
            report.fail(.agentDirectory,
                detail: "Relay 没有 Android Agent 记录：Android 未完成云端注册或从未发送心跳")
            onUpdate(report)
            return report
        }
        let directory = status.agents.map { agent in
            let name = agent.deviceName?.isEmpty == false ? agent.deviceName! : agent.agentID
            let online = agent.cloudOnline ? "在线" : "心跳过期"
            let kind = agent.agentKind?.isEmpty == false ? agent.agentKind! : "unknown"
            let routing = agent.commandRoutingVersion.map { "routing=v\($0)" } ?? "routing=missing"
            return "  - \(name) · \(kind) · \(online) · \(routing)"
        }.joined(separator: "\n")
        report.update(.agentDirectory, state: .passed,
            detail: "已登记 \(status.agents.count) 台\n\(directory)\nactive=\(status.activeAgentID ?? "none")")
        onUpdate(report)

        report.update(.agentHeartbeat, state: .running, detail: "检查最近 150 秒心跳与版本")
        onUpdate(report)
        guard status.cloudOnline else {
            let known = status.agents.map {
                "  - \($0.deviceName ?? $0.agentID) · \($0.cloudOnline ? "在线" : "超过90秒")"
            }.joined(separator: "\n")
            report.fail(.agentHeartbeat,
                detail: "90秒内无有效心跳\nRelay记录：\n\(known)\nactive=\(status.activeAgentID ?? "none")")
            onUpdate(report)
            return report
        }
        let version = status.agentVersion?.isEmpty == false ? status.agentVersion! : "未知版本"
        let cellular = status.cellularState?.isEmpty == false ? " · 蜂窝 \(status.cellularState!)" : ""
        report.update(.agentHeartbeat, state: .passed,
            detail: "Agent \(version) 在线\(cellular) · active=\(status.activeAgentID ?? "none")")
        onUpdate(report)

        report.update(.commandRouting, state: .running, detail: "检查 Agent 的 command_routing_version")
        onUpdate(report)
        let activeID = status.activeAgentID
        let active = status.agents.first { $0.agentID == activeID } ?? status.agents.first
        guard let active else {
            report.fail(.commandRouting, detail: "找不到 active Agent 记录")
            onUpdate(report)
            return report
        }
        guard let routing = active.commandRoutingVersion, routing >= 1 else {
            report.fail(.commandRouting,
                detail: "Agent \(active.deviceName ?? active.agentID) 未声明 command_routing_version；接听/挂断命令无法定向")
            onUpdate(report)
            return report
        }
        report.update(.commandRouting, state: .passed,
            detail: "Agent \(active.deviceName ?? active.agentID) 支持 command_routing=v\(routing)")
        report.completedAt = Date()
        onUpdate(report)
        return report
    }

    private func scheduleRegistrationRetry(after delay: TimeInterval) {
        guard CloudSignalingPreference.isEnabled() else { return }
        registrationRetryTask?.cancel()
        registrationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            registrationRetryTask = nil
            await syncRegistration()
        }
    }

    /// 本地 VoWLAN 不可达时，通过 Relay 最近心跳判断 Agent 是否仍在公网在线。
    /// 请求体中的设备密钥仅在内存中编码，并使用不落盘的临时 URLSession。
    func fetchCloudAgentStatus() async throws -> CloudAgentStatus {
        guard CloudModePreference.isEnabled() else {
            throw CloudAgentStatusError.unavailable
        }
        return try await fetchCloudAgentStatusForDiagnostics()
    }

    /// 检查单即使在公网 PCM 关闭时也需要读取心跳，避免用户无法判断开启条件。
    func fetchCloudAgentStatusForDiagnostics(allowLocalMode: Bool = false, attempts: Int = 3) async throws -> CloudAgentStatus {
        guard !RelayEgressGate.shared.isBlocked,
              !UserDefaults.standard.bool(forKey: RelayEgressGate.persistenceKey) else {
            throw RelayEgressError.disabled
        }
        guard let registration = currentRegistration(allowLocalMode: allowLocalMode) else {
            throw CloudAgentStatusError.unavailable
        }
        guard let url = RelayEndpoint.url(
            base: registration.relayURL,
            path: "v1/devices/status"
        ) else { throw CloudAgentStatusError.invalidRelayURL }

        struct RequestBody: Encodable {
            let deviceID: String
            let deviceSecret: String

            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case deviceSecret = "device_secret"
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            deviceID: registration.deviceID,
            deviceSecret: registration.deviceSecret
        ))

        let (data, response) = try await Self.sendDiagnosticRequest(request, attempts: attempts)
        guard let http = response as? HTTPURLResponse else { throw CloudAgentStatusError.invalidResponse }
        guard http.statusCode == 200 else {
            throw CloudAgentStatusError.relayFailure(statusCode: http.statusCode, data: data)
        }
        return try JSONDecoder().decode(CloudAgentStatus.self, from: data)
    }

    func startCloudOutgoingCall(
        number: String,
        target: CloudCommandTarget,
        operationID: UUID = UUID(),
        mediaTransport: CloudMediaTransport? = nil,
        timeout: TimeInterval = 6
    ) async throws -> IncomingVoIPCall {
        guard !DedicatedCallPolicy.vowlanOnly else { throw CloudCommandError.unavailable }
        let commandID = operationID
        guard let registration = currentRegistration() else { throw CloudCommandError.unavailable }
        let enqueue = try await enqueueCloudCommand(
            target: target, registration: registration,
            commandID: commandID,
            type: "dial",
            number: number,
            message: nil,
            mediaTransport: mediaTransport
        )
        guard enqueue.accepted, let call = enqueue.call, call.agentID == target.agentID,
              let uuid = UUID(uuidString: call.callUUID),
              let mediaURL = URL(string: call.mediaURL) else {
            throw CloudCommandError.invalidResponse
        }
        // The enqueue response already contains the authenticated call/media
        // identity. Android dials the cellular call immediately; waiting for the
        // command-result KV write used to consume the whole CallKit start window.
        // A slow result is advisory; media/control events still terminate a real
        // failed call. Only an explicit failed result blocks the outgoing call.
        let outcome = try? await waitForCloudCommand(
            commandID: commandID, target: target,
            registration: registration, timeout: timeout
        )
        if let outcome, outcome.status == "failed" {
            throw CloudCommandError.failed(outcome.error ?? "模块未能开始拨号")
        }
        if let outcome, outcome.status == "completed",
           outcome.result?.dialing != true {
            throw CloudCommandError.failed(outcome.error ?? "模块未能开始拨号")
        }
        return try IncomingVoIPCall(
            outgoingCallID: call.callID,
            uuid: uuid,
            number: number,
            secret: call.callSecret,
            mediaURL: mediaURL,
            generation: call.generation ?? 1,
            mediaTransport: call.mediaTransport ?? .legacyPCM,
            agentID: call.agentID
        )
    }

    func sendCloudSMS(to number: String, message: String, target: CloudCommandTarget,
                      simAccount: String? = nil) async throws -> SMSSendResult {
        let commandID = UUID()
        guard let registration = currentRegistration() else { throw CloudCommandError.unavailable }
        let enqueue = try await enqueueCloudCommand(
            target: target, registration: registration,
            commandID: commandID,
            type: "send_sms",
            number: number,
            message: message,
            simAccount: simAccount
        )
        guard enqueue.accepted else { throw CloudCommandError.invalidResponse }
        let outcome = try await waitForCloudCommand(commandID: commandID, target: target, registration: registration, timeout: 5 * 60)
        guard outcome.status == "completed", outcome.result?.sent == true else {
            throw CloudCommandError.failed(outcome.error ?? "模块发送短信失败")
        }
        return SMSSendResult(sent: true, segments: outcome.result?.segments)
    }

    func sendCloudDTMF(_ digit: String, call: IncomingVoIPCall) async throws {
        guard let agentID = call.agentID, CloudAgentRouting.validID(agentID),
              let registration = currentRegistration() else { throw CloudCommandError.unavailable }
        let target = CloudCommandTarget(agentID: agentID, routingVersion: 1)
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            target: target, registration: registration,
            commandID: commandID,
            type: "dtmf",
            number: digit,
            message: nil,
            call: call
        )
        guard enqueue.accepted else { throw CloudCommandError.invalidResponse }
        let outcome = try await waitForCloudCommand(commandID: commandID, target: target, registration: registration, timeout: 15)
        guard outcome.status == "completed", outcome.result?.sent == true else {
            throw CloudCommandError.failed(outcome.error ?? "模块发送 DTMF 失败")
        }
    }

    private func enqueueCloudCommand(
        target: CloudCommandTarget,
        registration: AgentPushRegistration,
        commandID: UUID,
        type: String,
        number: String,
        message: String?,
        simAccount: String? = nil,
        mediaTransport: CloudMediaTransport? = nil,
        call: IncomingVoIPCall? = nil
    ) async throws -> CloudCommandEnqueueResponse {
        guard CloudModePreference.isEnabled() else { throw CloudCommandError.cloudModeDisabled }
        try Task.checkCancellation()
        guard target.routingVersion == 1, CloudAgentRouting.validID(target.agentID),
              let url = RelayEndpoint.url(base: registration.relayURL, path: "v2/commands/enqueue") else {
            throw CloudCommandError.unavailable
        }
        var body: [String: Any] = [
            "device_id": registration.deviceID,
            "device_secret": registration.deviceSecret,
            "command_id": commandID.uuidString.lowercased(),
            "type": type,
            "number": number,
            "target_agent_id": target.agentID,
        ]
        if let call {
            body.merge(CloudAgentRouting.callIdentity(call)) { _, new in new }
        }
        if let message { body["message"] = message }
        if let simAccount, !simAccount.isEmpty { body["sim_account"] = simAccount }
        if let mediaTransport { body["media_transport"] = mediaTransport.rawValue }
        return try await relayRequest(url: url, body: body, as: CloudCommandEnqueueResponse.self)
    }

    private func waitForCloudCommand(commandID: UUID, target: CloudCommandTarget, registration: AgentPushRegistration, timeout: TimeInterval) async throws -> CloudCommandResultResponse {
        guard let url = RelayEndpoint.url(base: registration.relayURL, path: "v2/commands/result") else {
            throw CloudCommandError.unavailable
        }
        return try await CloudAgentRouting.poll(timeout: timeout, request: {
            try await self.relayRequest(
                url: url,
                body: [
                    "device_id": registration.deviceID,
                    "device_secret": registration.deviceSecret,
                    "command_id": commandID.uuidString.lowercased(),
                    "target_agent_id": target.agentID,
                ],
                as: CloudCommandResultResponse.self
            )
        }, isTerminal: { $0.status == "completed" || $0.status == "failed" })
    }

    private func relayRequest<Response: Decodable>(
        url: URL,
        body: [String: Any],
        as type: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let (data, response) = try await RelayEgressGate.shared.send(request)
        guard let http = response as? HTTPURLResponse else { throw CloudCommandError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(RelayErrorResponse.self, from: data).error)
            throw CloudCommandError.failed(message ?? "Relay HTTP \(http.statusCode)")
        }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw CloudCommandError.invalidResponse
        }
        return decoded
    }

    /// 验证当前 iPhone 到 Relay 的 HTTPS 控制面，不携带设备密钥。
    func checkRelayForDiagnostics() async throws -> String {
        guard !RelayEgressGate.shared.isBlocked, CloudSignalingPreference.isEnabled(),
              let registration = currentRegistration(allowLocalMode: true) else { throw CloudAgentStatusError.unavailable }
        return try await fetchRelayHealthVersion(registration: registration)
    }
    func relayHealthReachable() async -> Bool {
        guard let registration = currentRegistration(),
              (try? await fetchRelayHealthVersion(registration: registration)) != nil else { return false }
        return true
    }

    private func fetchRelayHealthVersion(registration: AgentPushRegistration) async throws -> String {
        guard let url = RelayEndpoint.url(base: registration.relayURL, path: "healthz") else {
            throw CloudAgentStatusError.invalidRelayURL
        }
        return try await fetchRelayHealthVersionOnce(url: url)
    }

    /// Whether the Relay that a pairing registers with forwards encrypted SMS. `/healthz` needs no
    /// registration, so this works before the first cloud pairing. A "no" makes Android drop an
    /// existing key, so dropped connections and 5xx are retried like the self-test's health probe;
    /// any other answer is final.
    nonisolated static func relaySupportsE2ESMS(
        relayURL: String,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RelayEgressGate.shared.send($0)
        }
    ) async -> Bool {
        guard let url = RelayEndpoint.url(base: relayURL, path: "healthz") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for attempt in 1...3 {
            if attempt > 1 { try? await Task.sleep(for: .milliseconds(300 * (attempt - 1))) }
            guard let (data, response) = try? await send(request),
                  let http = response as? HTTPURLResponse, http.statusCode < 500 else { continue }
            return RelayHealthValidation.supportsE2ESMS(statusCode: http.statusCode, data: data)
        }
        return false
    }

    nonisolated private static let selfTestSessions = RelayDiagnosticSessionPool()

    nonisolated static func sendDiagnosticRequest(
        _ request: URLRequest,
        attempts: Int = 3,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RelayEgressGate.shared.send($0, using: selfTestSessions.current)
        }
    ) async throws -> (Data, URLResponse) {
        let limit = max(1, min(3, attempts))
        for attempt in 0..<limit {
            try Task.checkCancellation()
            do {
                let result = try await send(request)
                try Task.checkCancellation()
                if let http = result.1 as? HTTPURLResponse,
                   [502, 503, 504].contains(http.statusCode), attempt < limit - 1 {
                    try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
                    continue
                }
                return result
            } catch {
                try Task.checkCancellation()
                let transient = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
                     .cannotFindHost, .notConnectedToInternet].contains($0.code)
                } ?? false
                PushDiagnostics.record("推送实时检查请求失败", error: error,
                    fields: ["endpoint": request.url?.lastPathComponent ?? "unknown", "attempt": String(attempt + 1)])
                guard transient, attempt < limit - 1 else { throw error }
                Self.selfTestSessions.rotate()
                try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            }
        }
        throw CloudAgentStatusError.invalidResponse
    }

    private func fetchRelayHealthVersionOnce(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await Self.sendDiagnosticRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAgentStatusError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw CloudAgentStatusError.relayFailure(statusCode: http.statusCode, data: data)
        }
        guard let version = RelayHealthValidation.version(statusCode: http.statusCode, data: data) else {
            throw CloudAgentStatusError.invalidResponse
        }
        return version
    }

    private func registerDirectlyWithRelay(_ registration: AgentPushRegistration, diagnostics: Bool = false) async throws {
        guard let url = RelayEndpoint.url(
            base: registration.relayURL,
            path: "v1/devices/register"
        ) else { throw CloudAgentStatusError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = diagnostics ? 6 : 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Webhook URLs/tokens are local pairing material. Relay only needs push
        // registration fields, so never upload forwarding credentials.
        var relayRegistration = registration
        relayRegistration.notificationForwarding = nil
        request.httpBody = try JSONEncoder().encode(relayRegistration)
        let (data, response): (Data, URLResponse)
        if diagnostics {
            (data, response) = try await RelayEgressGate.shared.send(request, using: Self.selfTestSessions.current)
        } else { (data, response) = try await RelayEgressGate.shared.send(request) }
#if DEBUG
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data.prefix(1_024), encoding: .utf8) ?? "<非文本响应>"
            print("[AirSIM PushKit] Relay 注册被拒绝；HTTP=\(http.statusCode) body=\(detail)")
        }
#endif
        guard let http = response as? HTTPURLResponse else {
            throw CloudAgentStatusError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw CloudAgentStatusError.relayFailure(statusCode: http.statusCode, data: data)
        }
        struct ResponseBody: Decodable { let registered: Bool }
        guard let result = try? JSONDecoder().decode(ResponseBody.self, from: data),
              result.registered else { throw CloudAgentStatusError.invalidResponse }
    }

    private func store(token: String) {
        guard UserDefaults.standard.string(forKey: Keys.token) != token else { return }
        UserDefaults.standard.set(token, forKey: Keys.token)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    private func resetRegistrationBackoff() {
        registrationEpoch &+= 1
        agentRegistrations = PushRegistrationLedger()
        lastRelayRegisteredFingerprint = nil
        nextRelayRegistrationAttempt = .distantPast
        relayRegistrationFailures = 0
    }

    func cloudCallControlCredentials() -> CloudCallControlCredentials? {
        guard !DedicatedCallPolicy.vowlanOnly else { return nil }
        guard let secret = Self.loadOrCreateDeviceSecret() else { return nil }
        let deviceID = PushDeviceIdentity.deviceID(deviceSecret: secret)
        let relayURL = configuredRelayURL()
        guard RelayEndpoint.url(base: relayURL, path: "/") != nil else { return nil }
        return CloudCallControlCredentials(
            relayURL: relayURL,
            deviceID: deviceID,
            deviceSecret: secret
        )
    }

    /// `offerE2E` tells the pairing client it may put an E2E SMS key into the claim (issue #24).
    func performAndroidPairing<T>(
        localOnly: Bool,
        operation: (AgentPushRegistration, _ offerE2E: Bool) async throws -> T
    ) async throws -> T {
        try await pairingGate.withPairing {
            guard let registration = self.pairingRegistration(localOnly: localOnly) else {
                throw SamsungPairingClientError.registrationUnavailable
            }
            var offerE2E = false
            if !localOnly {
                let relaySupports = await Self.relaySupportsE2ESMS(relayURL: registration.relayURL)
                offerE2E = E2EPairingPolicy.offer(localOnly: localOnly, relaySupports: relaySupports,
                                                  keychainReady: relaySupports && KeychainE2EKeyStore.shared.canStore())
            }
            return try await operation(registration, offerE2E)
        }
    }

    func pairingRegistration(localOnly: Bool = !CloudSignalingPreference.isEnabled()) -> AgentPushRegistration? {
        // A pairing transaction gets a new in-memory secret. It is committed
        // under its authenticated agentID only after the gateway proves identity.
        guard let secret = try? VoWLANCredentialStore.generate().encodedSecret else { return nil }
        return try? SamsungPairingRegistrationPolicy.registration(
            localOnly: localOnly, vowlanSecret: secret,
            notificationForwarding: NotificationForwardingStore.load(),
            cloudRegistration: { self.currentRegistration(allowLocalMode: true) }
        )
    }

    private func currentRegistration(allowLocalMode: Bool = false) -> AgentPushRegistration? {
        guard allowLocalMode || CloudSignalingPreference.isEnabled() else { return nil }
        guard let token = UserDefaults.standard.string(forKey: Keys.token), !token.isEmpty else {
#if DEBUG
            print("[AirSIM PushKit] 暂无 VoIP token，跳过同步")
#endif
            return nil
        }
        let defaults = UserDefaults.standard
        guard let secret = Self.loadOrCreateDeviceSecret() else {
#if DEBUG
            print("[AirSIM PushKit] 无法创建设备密钥，跳过同步")
#endif
            return nil
        }
        let deviceID = PushDeviceIdentity.deviceID(deviceSecret: secret)
        defaults.set(deviceID, forKey: Keys.deviceID)
        let relayURL = configuredRelayURL()
        let capabilities = CloudModeCapabilities(isEnabled: CloudModePreference.isEnabled())
        return AgentPushRegistration(
            cloudModeEnabled: capabilities.notificationRelay,
            localMode: false,
            deviceID: deviceID,
            deviceSecret: secret,
            token: token,
            alertToken: defaults.string(forKey: Keys.alertToken) ?? "",
            watchVoIPToken: defaults.string(forKey: Keys.watchVoIPToken) ?? "",
            watchBundleID: defaults.string(forKey: Keys.watchBundleID) ?? "com.example.airsim.watchkitapp",
            liveActivityPushToStartToken: LiveActivityVisibilityPreference.registrationToken(
                defaults.string(forKey: Keys.liveActivityPushToStartToken) ?? "",
                defaults: defaults
            ),
            bundleID: Bundle.main.bundleIdentifier ?? "com.example.airsim",
            environment: APNsEnvironment.current,
            relayURL: relayURL,
            mediaTransport: CloudMediaTransportPreference.requested().rawValue,
            appMediaCapabilities: [CloudMediaTransport.legacyPCM.rawValue],
            forceLegacyPCM: CloudMediaTransportPreference.forceLegacy(),
            vowlanSecret: nil,
            notificationForwarding: NotificationForwardingStore.load()
        )
    }

    private static func loadOrCreateDeviceSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.keychainService,
            kSecAttrAccount as String: Keys.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let value = Data(bytes).base64EncodedString()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.keychainService,
            kSecAttrAccount as String: Keys.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8)
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return value
    }
}

extension VoIPPushController: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = VoIPPushToken.hex(pushCredentials.token)
        Task { @MainActor [weak self] in
#if DEBUG
            print("[AirSIM PushKit] VoIP token 已更新；字节数=\(pushCredentials.token.count)")
#endif
            self?.store(token: token)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        Task { @MainActor [weak self] in
#if DEBUG
            print("[AirSIM PushKit] VoIP token 已失效")
#endif
            UserDefaults.standard.removeObject(forKey: Keys.token)
            PushDiagnostics.record("PushKit 推送令牌已失效", fields: ["failure_kind": "token_invalidated"])
            self?.resetRegistrationBackoff()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        AirSIMHealthStore.received(voip: true)
        let userInfo = payload.dictionaryPayload
        Task { @MainActor in
            PushDiagnostics.record("收到 PushKit 来电", fields: [
                "app_state": String(UIApplication.shared.applicationState.rawValue)])
            do {
                let call = try IncomingVoIPCall(userInfo: userInfo)
                CallKitController.shared.reportRequiredVoIPPush(call) { error in
                    PushDiagnostics.record("PushKit 系统来电上报完成", error: error)
                    completion()
                }
                guard CallKitController.shared.currentSystemCallUUID == call.uuid else { return }
                WatchCallCoordinator.shared.publishIncoming(call)
                if call.callerName == nil, let number = call.number {
                    Task {
                        let resolvedName = await Task.detached(priority: .userInitiated) {
                            try? ContactFetcher().displayName(for: number)
                        }.value
                        if let resolvedName, resolvedName != number {
                            WatchCallCoordinator.shared.publishIncoming(call, callerName: resolvedName)
                        }
                    }
                }
            } catch {
                PushDiagnostics.record("PushKit 来电解析失败", error: error)
#if DEBUG
                print("[AirSIM PushKit] 丢弃无效来电推送：\(error.localizedDescription)")
#endif
                completion()
            }
        }
    }
}

/// Rebuild a stale HTTPS connection after transport failure, never cache results.
private final class RelayDiagnosticSessionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var session = RelayEgressGate.makeDiagnosticSession()
    var current: URLSession { lock.lock(); defer { lock.unlock() }; return session }
    func rotate() {
        lock.lock(); let old = session; session = RelayEgressGate.makeDiagnosticSession(); lock.unlock()
        old.finishTasksAndInvalidate()
    }
}
