import ActivityKit
import CryptoKit
import Foundation
import PushKit
import Security

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
    /// 公网 PCM 仅作为本地 ECM 控制链路不可用时的回退。完整带签名地址只保存在内存中。
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
        mediaTransport: CloudMediaTransport = .legacyPCM
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
    case moduleLocal
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
        guard defaults.object(forKey: key) != nil else { return true }
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
        let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            let canonicalStored = stored.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if bundleID == maintainerBundleID, canonicalStored == legacyDJOneHubRelayURL {
                return maintainerRelayURL
            }
            return stored
        }
        let buildSetting = buildSetting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !buildSetting.isEmpty { return buildSetting }
        return bundleID == maintainerBundleID ? maintainerRelayURL : ""
    }
}

enum RelayHealthValidation {
    private struct Payload: Decodable {
        let ok: Bool
        let service: String
        let version: String
    }

    static func accepts(statusCode: Int, data: Data) -> Bool {
        version(statusCode: statusCode, data: data) != nil
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

enum AirSIMConnectionMode: Equatable, Sendable {
    case vowlan
    case cloud
    case offline
}

struct ConnectionModePresentation: Equatable, Sendable {
    let mode: AirSIMConnectionMode
    let title: String
    let status: String
    let detail: String

    static func make(
        vowlanOnline: Bool,
        cloudModeEnabled: Bool,
        cloudOnline: Bool
    ) -> ConnectionModePresentation {
        if vowlanOnline {
            return ConnectionModePresentation(
                mode: .vowlan,
                title: "VoWLAN",
                status: "已连接",
                detail: cloudOnline ? "局域网优先，云端可回退" : "同一 Wi-Fi / 三星热点"
            )
        }
        if cloudModeEnabled {
            return ConnectionModePresentation(
                mode: .cloud,
                title: "云端",
                status: cloudOnline ? "已连接" : "不可达",
                detail: cloudOnline ? "独立 Relay 与 Agent 心跳正常" : "运行云端模式自检定位故障"
            )
        }
        return ConnectionModePresentation(
            mode: .offline,
            title: "未连接",
            status: "离线",
            detail: "VoWLAN 不可达且云端模式已关闭"
        )
    }
}

enum CloudSelfTestStepID: String, CaseIterable, Sendable {
    case configuration
    case relayIdentity
    case deviceRegistration
    case agentHeartbeat
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

struct CloudSelfTestReport: Equatable, Sendable {
    var steps: [CloudSelfTestStep]
    var completedAt: Date?

    static let initial = CloudSelfTestReport(
        steps: [
            CloudSelfTestStep(id: .configuration, title: "本机配置", state: .pending, detail: "等待检查"),
            CloudSelfTestStep(id: .relayIdentity, title: "Relay 身份", state: .pending, detail: "等待检查"),
            CloudSelfTestStep(id: .deviceRegistration, title: "设备注册", state: .pending, detail: "等待检查"),
            CloudSelfTestStep(id: .agentHeartbeat, title: "Agent 心跳", state: .pending, detail: "等待检查"),
        ],
        completedAt: nil
    )

    var allPassed: Bool {
        completedAt != nil && steps.allSatisfy { $0.state == .passed }
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
    let usbCallingAndSMS = true
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
}

enum PushRegistrationAttemptPolicy {
    static func shouldResetBackoff<Route: Equatable>(
        previousRoute: Route,
        currentRoute: Route
    ) -> Bool {
        previousRoute != currentRoute
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
        vowlanReady: Bool,
        moduleLocalReachable: Bool,
        cloudMediaAvailable: Bool,
        cloudMediaEnabled: Bool = true
    ) -> CallTransport? {
        if vowlanReady { return .vowlan }
        if moduleLocalReachable { return .moduleLocal }
        if cloudMediaEnabled && cloudMediaAvailable { return .cloud }
        return nil
    }
}

enum CloudAgentStatusError: LocalizedError {
    case unavailable
    case invalidRelayURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "云端状态尚未配置"
        case .invalidRelayURL: return "Relay 必须使用 HTTPS"
        case .invalidResponse: return "Relay 状态响应无效"
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
        let callID: String
        let callUUID: String
        let generation: UInt64?
        let callSecret: String
        let mediaURL: String
        let mediaTransport: CloudMediaTransport?
        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
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

struct AgentPushRegistration: Codable, Equatable, Sendable {
    let cloudModeEnabled: Bool
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

    enum CodingKeys: String, CodingKey {
        case cloudModeEnabled = "cloud_enabled"
        case deviceID = "device_id"
        case deviceSecret = "device_secret"
        case token = "voip_token"
        case alertToken = "alert_token"
        case watchVoIPToken = "watch_voip_token"
        case watchBundleID = "watch_bundle_id"
        case liveActivityPushToStartToken = "live_activity_push_to_start_token"
        case bundleID = "bundle_id"
        case environment
        case relayURL = "relay_url"
        case mediaTransport = "media_transport"
        case appMediaCapabilities = "app_media_capabilities"
        case forceLegacyPCM = "force_legacy_pcm"
        case vowlanSecret = "vowlan_secret"
    }
}

struct AgentPushStatus: Decodable, Sendable {
    let cloudModeEnabled: Bool?
    let configured: Bool
    let callPushReady: Bool
    let messagePushReady: Bool
    let environment: String?
    let relayURL: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
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

    var errorDescription: String? {
        switch self {
        case .unsupportedEvent: return "不是有效的新短信推送"
        case .incomplete: return "短信推送缺少必要字段"
        case .invalidTimestamp: return "短信推送时间无效"
        }
    }
}

struct IncomingRemoteSMS: Equatable, Sendable {
    let deliveryID: String
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date
    let contentTruncated: Bool

    init(userInfo: [AnyHashable: Any]) throws {
        guard userInfo["event"] as? String == "incoming_sms" else {
            throw RemoteSMSPushError.unsupportedEvent
        }
        guard let deliveryID = Self.nonEmpty(userInfo["delivery_id"] as? String),
              let sender = Self.nonEmpty(userInfo["sender"] as? String),
              let content = Self.nonEmpty(userInfo["content"] as? String) else {
            throw RemoteSMSPushError.incomplete
        }
        guard let rawTimestamp = userInfo["timestamp"] as? String,
              let timestamp = Self.parseTimestamp(rawTimestamp) else {
            throw RemoteSMSPushError.invalidTimestamp
        }
        self.deliveryID = deliveryID
        self.sender = sender
        self.content = content
        code = Self.nonEmpty(userInfo["code"] as? String)
        self.timestamp = timestamp
        contentTruncated = userInfo["content_truncated"] as? Bool ?? false
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
            direction: .incoming
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// PushKit 是被系统挂起或终止后恢复 CallKit 的入口；模块 USB 长轮询仍作为前台兜底。
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
    private var lastRegisteredFingerprint: String?
    private var lastRelayRegisteredFingerprint: String?
    private var registrationInFlight = false
    private var registrationPending = false
    private var nextRegistrationAttempt = Date.distantPast
    private var registrationRetryTask: Task<Void, Never>?
    private var latestRegistrationAPI = AirSIMAPI()
    private var activityKitRegistrationStarted = false
    private var observedActivityIDs = Set<String>()

    func start() {
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

    private func startActivityKitRegistration() {
        guard !activityKitRegistrationStarted else { return }
        if #available(iOS 17.2, *) {
            activityKitRegistrationStarted = true
            Task { @MainActor [weak self] in
                for await token in Activity<AirSIMCallActivityAttributes>.pushToStartTokenUpdates {
                    guard let self else { return }
                    UserDefaults.standard.set(
                        VoIPPushToken.hex(token),
                        forKey: Keys.liveActivityPushToStartToken
                    )
                    resetRegistrationBackoff()
                    await syncRegistration()
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for activity in Activity<AirSIMCallActivityAttributes>.activities {
                    observeLiveActivity(activity)
                }
                for await activity in Activity<AirSIMCallActivityAttributes>.activityUpdates {
                    observeLiveActivity(activity)
                }
            }
        }
    }

    func observeLiveActivity(_ activity: Activity<AirSIMCallActivityAttributes>) {
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
        _ = try? await URLSession(configuration: configuration).data(for: request)
    }

    func storeAlertToken(_ token: Data) {
        UserDefaults.standard.set(VoIPPushToken.hex(token), forKey: Keys.alertToken)
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
        UserDefaults.standard.set(token, forKey: Keys.watchVoIPToken)
        UserDefaults.standard.set(bundleID, forKey: Keys.watchBundleID)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    func updateRelayURL(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.relayURL)
        } else {
            UserDefaults.standard.set(normalized, forKey: Keys.relayURL)
        }
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

    func syncRegistration(with requestedAPI: AirSIMAPI? = nil) async {
        let api = requestedAPI ?? latestRegistrationAPI
        if PushRegistrationAttemptPolicy.shouldResetBackoff(
            previousRoute: latestRegistrationAPI.route,
            currentRoute: api.route
        ) {
            nextRegistrationAttempt = .distantPast
            registrationRetryTask?.cancel()
            registrationRetryTask = nil
        }
        latestRegistrationAPI = api
        let attemptedRoute = api.route
        if registrationInFlight {
            registrationPending = true
            return
        }
        guard Date() >= nextRegistrationAttempt,
              let registration = currentRegistration() else { return }
        let fingerprint = [
            registration.token, registration.alertToken, registration.watchVoIPToken,
            registration.watchBundleID, registration.liveActivityPushToStartToken,
            registration.bundleID, registration.environment,
            registration.relayURL, registration.deviceID
        ].joined(separator: "|")
        guard fingerprint != lastRegisteredFingerprint
                || fingerprint != lastRelayRegisteredFingerprint else { return }

        registrationInFlight = true
        defer {
            registrationInFlight = false
            if registrationPending {
                registrationPending = false
                Task { await syncRegistration(with: latestRegistrationAPI) }
            }
        }
#if DEBUG
        print(
            "[AirSIM PushKit] 开始同步 Agent；VoIP=有，通知=\(registration.alertToken.isEmpty ? "无" : "有")，" +
            "环境=\(registration.environment)，Relay=\(registration.relayURL.isEmpty ? "未配置" : "已配置")"
        )
#endif
        var agentRegistered = false
        do {
            guard case .vowlan = api.route else { throw CallKitBridgeError.noReachableTransport }
            try await api.registerVoIPPush(registration)
            lastRegisteredFingerprint = fingerprint
            agentRegistered = true
#if DEBUG
            print("[AirSIM PushKit] Agent 已接收设备注册")
            Task {
                try? await Task.sleep(for: .seconds(8))
                do {
                    let status = try await api.pushStatus()
                    print(
                        "[AirSIM PushKit] Agent 状态；配置=\(status.configured)，" +
                        "来电=\(status.callPushReady)，短信=\(status.messagePushReady)，" +
                        "错误=\(status.lastError?.isEmpty == false ? status.lastError! : "无")"
                    )
                } catch {
                    print("[AirSIM PushKit] 读取 Agent 推送状态失败：\(error.localizedDescription)")
                }
            }
#endif
        } catch {
#if DEBUG
            print("[AirSIM PushKit] 向模块注册 token 失败：\(error.localizedDescription)")
#endif
        }

        var relayRegistered = lastRelayRegisteredFingerprint == fingerprint
        if !relayRegistered {
            do {
                try await registerDirectlyWithRelay(registration)
                lastRelayRegisteredFingerprint = fingerprint
                relayRegistered = true
#if DEBUG
                print("[AirSIM PushKit] Relay 已直接接收设备注册")
#endif
            } catch {
#if DEBUG
                print("[AirSIM PushKit] 直接同步 Relay 失败：\(error.localizedDescription)")
#endif
            }
        }
        // Relay 成功但本地 Agent 仍不可达时继续低频重试，确保模块恢复后也持有同一组凭据。
        let needsRetry = PushRegistrationRetryPolicy.needsRetry(
            agentRegistered: agentRegistered,
            relayRegistered: relayRegistered
        )
        let routeWasSuperseded = PushRegistrationAttemptPolicy.shouldResetBackoff(
            previousRoute: attemptedRoute,
            currentRoute: latestRegistrationAPI.route
        )
        nextRegistrationAttempt = agentRegistered && relayRegistered || routeWasSuperseded
            ? .distantPast
            : Date().addingTimeInterval(30)
        if needsRetry, !routeWasSuperseded {
            scheduleRegistrationRetry()
        } else {
            registrationRetryTask?.cancel()
            registrationRetryTask = nil
        }
    }

    /// 忽略本次进程内的注册指纹缓存，供用户主动执行云端修复。
    func forceRegistrationSync(with api: AirSIMAPI = AirSIMAPI()) async {
        resetRegistrationBackoff()
        await syncRegistration(with: api)
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

        report.update(.configuration, state: .running, detail: "检查 Relay、PushKit 与通知凭据")
        onUpdate(report)
        let readiness = registrationReadiness()
        var missing: [String] = []
        if !CloudModePreference.isEnabled() { missing.append("云端模式未开启") }
        if !readiness.relayURLReady { missing.append("Relay HTTPS 地址无效") }
        if !readiness.deviceIdentityReady { missing.append("设备身份未生成") }
        if !readiness.voIPTokenReady { missing.append("PushKit token 未就绪") }
        if !readiness.alertTokenReady { missing.append("通知 token 未就绪") }
        guard missing.isEmpty, let registration = currentRegistration() else {
            report.fail(.configuration, detail: missing.isEmpty ? "设备注册信息不完整" : missing.joined(separator: "；"))
            onUpdate(report)
            return report
        }
        report.update(
            .configuration,
            state: .passed,
            detail: "设备 \(readiness.deviceIDHint ?? "已生成") · APNs \(readiness.environment)"
        )
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

        report.update(.deviceRegistration, state: .running, detail: "验证设备密钥与注册接口")
        onUpdate(report)
        do {
            try await registerDirectlyWithRelay(registration)
            report.update(.deviceRegistration, state: .passed, detail: "Relay 已接受设备注册")
            onUpdate(report)
        } catch {
            report.fail(.deviceRegistration, detail: "注册被拒绝：\(error.localizedDescription)")
            onUpdate(report)
            return report
        }

        report.update(.agentHeartbeat, state: .running, detail: "查询 AVF Agent 最近 90 秒心跳")
        onUpdate(report)
        do {
            let status = try await fetchCloudAgentStatusForDiagnostics()
            guard status.cloudOnline else {
                report.fail(.agentHeartbeat, detail: "Relay 已连接，但 AVF Agent 90 秒内无心跳")
                onUpdate(report)
                return report
            }
            let version = status.agentVersion?.isEmpty == false ? status.agentVersion! : "未知版本"
            let cellular = status.cellularState?.isEmpty == false ? " · 蜂窝 \(status.cellularState!)" : ""
            report.update(.agentHeartbeat, state: .passed, detail: "Agent \(version) 在线\(cellular)")
            report.completedAt = Date()
            onUpdate(report)
            return report
        } catch {
            report.fail(.agentHeartbeat, detail: "心跳查询失败：\(error.localizedDescription)")
            onUpdate(report)
            return report
        }
    }

    private func scheduleRegistrationRetry() {
        guard registrationRetryTask == nil else { return }
        registrationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            registrationRetryTask = nil
            await syncRegistration(with: latestRegistrationAPI)
        }
    }

    func setCloudModeEnabled(_ enabled: Bool, with api: AirSIMAPI = AirSIMAPI()) async {
        resetRegistrationBackoff()
        WatchCallCoordinator.shared.refreshMediaPolicy()
        // PushKit、CallKit 与 APNs 是本地 USB 模式的通知控制面，不能跟随
        // 公网 PCM 开关一起关闭。Agent 始终保持通知中继注册；偏好值只控制
        // 云端状态查询与网络 PCM 媒体通道。
        try? await api.setPushCloudEnabled(true)
        if !enabled {
            await IPhoneCloudCallSession.shared.end()
        }
        await syncRegistration(with: api)
    }

    /// 本地 USB/ECM 不可达时，通过 Relay 最近心跳判断 Agent 是否仍在公网在线。
    /// 请求体中的设备密钥仅在内存中编码，并使用不落盘的临时 URLSession。
    func fetchCloudAgentStatus() async throws -> CloudAgentStatus {
        guard CloudModePreference.isEnabled() else {
            throw CloudAgentStatusError.unavailable
        }
        return try await fetchCloudAgentStatusForDiagnostics()
    }

    /// 检查单即使在公网 PCM 关闭时也需要读取心跳，避免用户无法判断开启条件。
    func fetchCloudAgentStatusForDiagnostics() async throws -> CloudAgentStatus {
        guard let registration = currentRegistration() else {
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

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CloudAgentStatusError.invalidResponse
        }
        return try JSONDecoder().decode(CloudAgentStatus.self, from: data)
    }

    func startCloudOutgoingCall(
        number: String,
        mediaTransport: CloudMediaTransport? = nil,
        timeout: TimeInterval = 25
    ) async throws -> IncomingVoIPCall {
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            commandID: commandID,
            type: "dial",
            number: number,
            message: nil,
            mediaTransport: mediaTransport
        )
        guard enqueue.accepted, let call = enqueue.call,
              let uuid = UUID(uuidString: call.callUUID),
              let mediaURL = URL(string: call.mediaURL) else {
            throw CloudCommandError.invalidResponse
        }
        let outcome = try await waitForCloudCommand(commandID: commandID, timeout: timeout)
        guard outcome.status == "completed", outcome.result?.dialing == true else {
            throw CloudCommandError.failed(outcome.error ?? "模块未能开始拨号")
        }
        return try IncomingVoIPCall(
            outgoingCallID: call.callID,
            uuid: uuid,
            number: number,
            secret: call.callSecret,
            mediaURL: mediaURL,
            generation: call.generation ?? 1,
            mediaTransport: call.mediaTransport ?? .legacyPCM
        )
    }

    func sendCloudSMS(to number: String, message: String) async throws -> SMSSendResult {
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            commandID: commandID,
            type: "send_sms",
            number: number,
            message: message
        )
        guard enqueue.accepted else { throw CloudCommandError.invalidResponse }
        let outcome = try await waitForCloudCommand(commandID: commandID, timeout: 5 * 60)
        guard outcome.status == "completed", outcome.result?.sent == true else {
            throw CloudCommandError.failed(outcome.error ?? "模块发送短信失败")
        }
        return SMSSendResult(sent: true, segments: outcome.result?.segments)
    }

    func sendCloudDTMF(_ digit: String) async throws {
        let commandID = UUID()
        let enqueue = try await enqueueCloudCommand(
            commandID: commandID,
            type: "dtmf",
            number: digit,
            message: nil
        )
        guard enqueue.accepted else { throw CloudCommandError.invalidResponse }
        let outcome = try await waitForCloudCommand(commandID: commandID, timeout: 15)
        guard outcome.status == "completed", outcome.result?.sent == true else {
            throw CloudCommandError.failed(outcome.error ?? "模块发送 DTMF 失败")
        }
    }

    private func enqueueCloudCommand(
        commandID: UUID,
        type: String,
        number: String,
        message: String?,
        mediaTransport: CloudMediaTransport? = nil
    ) async throws -> CloudCommandEnqueueResponse {
        guard CloudModePreference.isEnabled() else { throw CloudCommandError.cloudModeDisabled }
        guard let registration = currentRegistration(),
              let url = RelayEndpoint.url(base: registration.relayURL, path: "v1/commands/enqueue") else {
            throw CloudCommandError.unavailable
        }
        var body: [String: String] = [
            "device_id": registration.deviceID,
            "device_secret": registration.deviceSecret,
            "command_id": commandID.uuidString.lowercased(),
            "type": type,
            "number": number,
        ]
        if let message { body["message"] = message }
        if let mediaTransport { body["media_transport"] = mediaTransport.rawValue }
        return try await relayRequest(url: url, body: body, as: CloudCommandEnqueueResponse.self)
    }

    private func waitForCloudCommand(commandID: UUID, timeout: TimeInterval) async throws -> CloudCommandResultResponse {
        guard let registration = currentRegistration(),
              let url = RelayEndpoint.url(base: registration.relayURL, path: "v1/commands/result") else {
            throw CloudCommandError.unavailable
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await relayRequest(
                url: url,
                body: [
                    "device_id": registration.deviceID,
                    "device_secret": registration.deviceSecret,
                    "command_id": commandID.uuidString.lowercased(),
                ],
                as: CloudCommandResultResponse.self
            )
            if response.status == "completed" || response.status == "failed" { return response }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CloudCommandError.timeout
    }

    private func relayRequest<Response: Decodable>(
        url: URL,
        body: [String: String],
        as type: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
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
    func relayHealthReachable() async -> Bool {
        guard let registration = currentRegistration(),
              (try? await fetchRelayHealthVersion(registration: registration)) != nil else { return false }
        return true
    }

    private func fetchRelayHealthVersion(registration: AgentPushRegistration) async throws -> String {
        guard let url = RelayEndpoint.url(base: registration.relayURL, path: "healthz") else {
            throw CloudAgentStatusError.invalidRelayURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse,
              let version = RelayHealthValidation.version(statusCode: http.statusCode, data: data) else {
            throw CloudAgentStatusError.invalidResponse
        }
        return version
    }

    private func registerDirectlyWithRelay(_ registration: AgentPushRegistration) async throws {
        guard let url = RelayEndpoint.url(
            base: registration.relayURL,
            path: "v1/devices/register"
        ) else { throw CloudAgentStatusError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
#if DEBUG
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data.prefix(1_024), encoding: .utf8) ?? "<非文本响应>"
            print("[AirSIM PushKit] Relay 注册被拒绝；HTTP=\(http.statusCode) body=\(detail)")
        }
#endif
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CloudAgentStatusError.invalidResponse
        }
        struct ResponseBody: Decodable { let registered: Bool }
        guard let result = try? JSONDecoder().decode(ResponseBody.self, from: data),
              result.registered else { throw CloudAgentStatusError.invalidResponse }
    }

    private func store(token: String) {
        UserDefaults.standard.set(token, forKey: Keys.token)
        resetRegistrationBackoff()
        Task { await syncRegistration() }
    }

    private func resetRegistrationBackoff() {
        lastRegisteredFingerprint = nil
        lastRelayRegisteredFingerprint = nil
        nextRegistrationAttempt = .distantPast
    }

    func cloudCallControlCredentials() -> CloudCallControlCredentials? {
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

    func pairingRegistration() -> AgentPushRegistration? {
        guard var registration = currentRegistration() else { return nil }
        registration.vowlanSecret = (try? VoWLANCredentialStore.loadOrCreate().encodedSecret)
        return registration
    }

    private func currentRegistration() -> AgentPushRegistration? {
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
            deviceID: deviceID,
            deviceSecret: secret,
            token: token,
            alertToken: defaults.string(forKey: Keys.alertToken) ?? "",
            watchVoIPToken: defaults.string(forKey: Keys.watchVoIPToken) ?? "",
            watchBundleID: defaults.string(forKey: Keys.watchBundleID) ?? "com.example.airsim.watchkitapp",
            liveActivityPushToStartToken: defaults.string(forKey: Keys.liveActivityPushToStartToken) ?? "",
            bundleID: Bundle.main.bundleIdentifier ?? "com.example.airsim",
            environment: APNsEnvironment.current,
            relayURL: relayURL,
            mediaTransport: CloudMediaTransportPreference.requested().rawValue,
            appMediaCapabilities: [CloudMediaTransport.legacyPCM.rawValue],
            forceLegacyPCM: CloudMediaTransportPreference.forceLegacy(),
            vowlanSecret: nil
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
        let userInfo = payload.dictionaryPayload
        Task { @MainActor in
            do {
                let call = try IncomingVoIPCall(userInfo: userInfo)
                CallKitController.shared.reportIncomingPush(call) { _ in completion() }
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
#if DEBUG
                print("[AirSIM PushKit] 丢弃无效来电推送：\(error.localizedDescription)")
#endif
                completion()
            }
        }
    }
}
