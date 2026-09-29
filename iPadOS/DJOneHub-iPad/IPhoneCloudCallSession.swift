import AVFoundation
import CallKit
import Foundation
import UIKit

enum IPhoneCloudCallError: LocalizedError {
    case mediaUnavailable
    case microphonePermissionDenied
    case microphoneUnavailable
    case invalidAudioFormat
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .mediaUnavailable: return "来电没有可用的云端媒体凭证"
        case .microphonePermissionDenied: return "需要麦克风权限才能进行云端通话"
        case .microphoneUnavailable: return "当前没有可用的麦克风输入"
        case .invalidAudioFormat: return "无法建立云端通话音频格式"
        case .connectionClosed: return "模块云端语音连接已经断开"
        }
    }
}

enum CloudCallAudioState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int, maximumAttempts: Int)
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
}

enum CloudCallAudioStartupPolicy {
    static func shouldStart(
        answered: Bool,
        mediaPrepared: Bool,
        lifecycleState: CallLifecycleState,
        isOutgoing: Bool,
        managedByCallKit: Bool,
        callKitAudioSessionActive: Bool
    ) -> Bool {
        guard answered, mediaPrepared else { return false }
        guard lifecycleState == .active || (isOutgoing && lifecycleState == .connecting) else {
            return false
        }
        return !managedByCallKit || callKitAudioSessionActive
    }
}

enum CloudMediaHealthIssue: String, Equatable, Sendable {
    case connectionLost = "connection_lost"
    case downlinkStalled = "downlink_stalled"
    case downlinkSilent = "downlink_silent"
    case uplinkStalled = "uplink_stalled"
}

enum CloudMediaHealthDecision: Equatable, Sendable {
    case none
    case rebuild(CloudMediaHealthIssue)
    case failed(CloudMediaHealthIssue)
}

struct CloudMediaHealthSnapshot: Equatable, Sendable {
    var firstDownlinkAt: Date?
    var lastDownlinkAt: Date?
    var lastUplinkAt: Date?
    var downlinkBytes: UInt64 = 0
    var downlinkFrames: UInt64 = 0
    var downlinkPeak: Int = 0
    var uplinkBytes: UInt64 = 0
    var uplinkFrames: UInt64 = 0
    var uplinkPeak: Int = 0
    var droppedFrames: UInt64 = 0
    var jitterBufferHighWatermark: Int = 0
    var rebuildCount: Int = 0
    var audioRoute = "unknown"
    var lastIssue: CloudMediaHealthIssue?
}

struct CloudMediaHealthTracker: Sendable {
    private static let stallInterval: TimeInterval = 2
    private static let silentFrameThreshold = 50
    private static let audiblePeakThreshold = 32

    private var windowStartedAt: Date
    private var consecutiveSilentFrames = 0
    private let maximumRebuilds: Int
    private(set) var snapshot = CloudMediaHealthSnapshot()

    init(startedAt: Date, maximumRebuilds: Int = 3) {
        windowStartedAt = startedAt
        self.maximumRebuilds = max(0, maximumRebuilds)
    }

    mutating func recordDownlink(
        bytes: Int,
        peak: Int,
        at timestamp: Date,
        jitterBufferFrames: Int,
        droppedFrames: Int = 0
    ) {
        guard bytes > 0 else { return }
        snapshot.firstDownlinkAt = snapshot.firstDownlinkAt ?? timestamp
        snapshot.lastDownlinkAt = timestamp
        snapshot.downlinkBytes &+= UInt64(bytes)
        snapshot.downlinkFrames &+= UInt64(max(1, bytes / 320))
        snapshot.downlinkPeak = max(snapshot.downlinkPeak, peak)
        snapshot.droppedFrames &+= UInt64(max(0, droppedFrames))
        snapshot.jitterBufferHighWatermark = max(
            snapshot.jitterBufferHighWatermark,
            max(0, jitterBufferFrames)
        )
        consecutiveSilentFrames = peak < Self.audiblePeakThreshold
            ? consecutiveSilentFrames + max(1, bytes / 320)
            : 0
    }

    mutating func recordUplink(bytes: Int, peak: Int, at timestamp: Date) {
        guard bytes > 0 else { return }
        snapshot.lastUplinkAt = timestamp
        snapshot.uplinkBytes &+= UInt64(bytes)
        snapshot.uplinkFrames &+= UInt64(max(1, bytes / 320))
        snapshot.uplinkPeak = max(snapshot.uplinkPeak, peak)
    }

    mutating func recordRoute(_ route: String) {
        let normalized = route.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.audioRoute = normalized.isEmpty ? "unknown" : normalized
    }

    func evaluate(at timestamp: Date) -> CloudMediaHealthDecision {
        let issue: CloudMediaHealthIssue?
        let lastDownlink = snapshot.lastDownlinkAt ?? windowStartedAt
        if timestamp.timeIntervalSince(lastDownlink) >= Self.stallInterval {
            issue = .downlinkStalled
        } else {
            let lastUplink = snapshot.lastUplinkAt ?? windowStartedAt
            issue = snapshot.downlinkFrames > 0 &&
                timestamp.timeIntervalSince(lastUplink) >= Self.stallInterval
                ? .uplinkStalled
                : nil
        }
        guard let issue else { return .none }
        return snapshot.rebuildCount < maximumRebuilds ? .rebuild(issue) : .failed(issue)
    }

    @discardableResult
    mutating func beginRebuild(for issue: CloudMediaHealthIssue, at timestamp: Date) -> Bool {
        guard snapshot.rebuildCount < maximumRebuilds else { return false }
        snapshot.rebuildCount += 1
        snapshot.lastIssue = issue
        windowStartedAt = timestamp
        consecutiveSilentFrames = 0
        snapshot.lastDownlinkAt = nil
        snapshot.lastUplinkAt = nil
        return true
    }
}

enum CloudMediaTransport: String, Codable, CaseIterable, Sendable {
    case legacyPCM = "legacy_pcm"
    case webRTC = "webrtc"
}

enum CloudMediaTransportNegotiator {
    static func resolve(
        requested: CloudMediaTransport,
        appSupported: Set<CloudMediaTransport>,
        agentSupported: Set<CloudMediaTransport>,
        forceLegacy: Bool
    ) -> CloudMediaTransport {
        if forceLegacy { return .legacyPCM }
        if appSupported.contains(requested), agentSupported.contains(requested) {
            return requested
        }
        return .legacyPCM
    }
}

enum CloudMediaTransportPreference {
    static let requestedKey = "djonehub.cloud-media-requested-transport"
    static let forceLegacyKey = "djonehub.cloud-media-force-legacy-pcm"

    static func requested(defaults: UserDefaults = .standard) -> CloudMediaTransport {
        guard let rawValue = defaults.string(forKey: requestedKey) else { return .legacyPCM }
        return CloudMediaTransport(rawValue: rawValue) ?? .legacyPCM
    }

    static func forceLegacy(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: forceLegacyKey)
    }
}

enum CloudCallRetryPolicy {
    /// CallKit 激活音频会话与 AVAudioEngine 可用之间会有短暂竞争；覆盖约 12 秒，
    /// 同时限制重试次数，避免真实权限错误形成后台空转。
    static let audioDelays: [TimeInterval] = [0, 0.35, 0.8, 1.5, 3, 6]
    static let reconnectDelays: [TimeInterval] = [0.4, 1, 2, 4]

    static func shouldRetryAudio(after error: Error) -> Bool {
        if case IPhoneCloudCallError.microphonePermissionDenied = error { return false }
        return true
    }
}

enum CloudCallAnswerPolicy {
    // Agent 的 ATA 最长会等待约 5 秒；重发间隔不能形成高频控制帧风暴。
    static let confirmationDelays: [TimeInterval] = [0, 3, 3, 4, 5]

    static func isAcknowledged(status: String) -> Bool {
        status == "answer_ok" || status == "active"
    }

    static func shouldReplayImmediately(status: String) -> Bool {
        status == "agent_ready"
    }
}

enum CloudCallTerminationCoordinator {
    static func finish(
        closeMedia: () async -> Void,
        enqueuePersistentControl: () async -> Void
    ) async {
        await closeMedia()
        await enqueuePersistentControl()
    }
}

struct CloudPCMControlMessage: Equatable, Sendable {
    let status: String
    let message: String?
    let action: String?
    let callID: String?
    let callUUID: String?
    let generation: UInt64?
    let commandID: String?
    let traceID: String?
    let downlinkBytes: UInt64?
    let downlinkFrames: UInt64?
    let downlinkPeak: UInt64?

    private struct Payload: Decodable {
        let status: String?
        let event: String?
        let message: String?
        let action: String?
        let callID: String?
        let callUUID: String?
        let generation: UInt64?
        let commandID: String?
        let traceID: String?
        let downlinkBytes: UInt64?
        let downlinkFrames: UInt64?
        let downlinkPeak: UInt64?

        enum CodingKeys: String, CodingKey {
            case status, event, message
            case action, generation
            case callID = "call_id"
            case callUUID = "call_uuid"
            case commandID = "command_id"
            case traceID = "trace_id"
            case downlinkBytes = "downlink_bytes"
            case downlinkFrames = "downlink_frames"
            case downlinkPeak = "downlink_peak"
        }
    }

    static func decode(_ text: String) throws -> CloudPCMControlMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let status = payload.status ?? payload.event else { return nil }
        return CloudPCMControlMessage(
            status: status,
            message: payload.message,
            action: payload.action,
            callID: payload.callID,
            callUUID: payload.callUUID,
            generation: payload.generation,
            commandID: payload.commandID,
            traceID: payload.traceID,
            downlinkBytes: payload.downlinkBytes,
            downlinkFrames: payload.downlinkFrames,
            downlinkPeak: payload.downlinkPeak
        )
    }

    var traceFields: [String: String] {
        var fields: [String: String] = [:]
        if let action { fields["action"] = action }
        if let callID { fields["call_id"] = callID }
        if let callUUID { fields["call_uuid"] = callUUID }
        if let generation { fields["generation"] = String(generation) }
        if let commandID { fields["command_id"] = commandID }
        if let traceID { fields["trace_id"] = traceID }
        return fields
    }
}

struct CloudCallControlEnvelope: Codable, Equatable, Sendable {
    let action: String
    let callID: String
    let callUUID: String
    let generation: UInt64
    let commandID: String
    let traceID: String

    enum CodingKeys: String, CodingKey {
        case action, generation
        case callID = "call_id"
        case callUUID = "call_uuid"
        case commandID = "command_id"
        case traceID = "trace_id"
    }
}

struct CloudCallControlCredentials: Equatable, Sendable {
    let relayURL: String
    let deviceID: String
    let deviceSecret: String
}

struct CloudCallControlReceipt: Decodable, Equatable, Sendable {
    struct Result: Decodable, Equatable, Sendable {
        let ended: Bool?
        let modemConfirmed: Bool?
        let clccAttempts: Int?
        let lastCLCC: String?

        enum CodingKeys: String, CodingKey {
            case ended
            case modemConfirmed = "modem_confirmed"
            case clccAttempts = "clcc_attempts"
            case lastCLCC = "last_clcc"
        }
    }

    let accepted: Bool?
    let commandID: String
    let status: String
    let agentConnected: Bool?
    let rescueCommandID: String?
    let result: Result?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accepted, status, result, error
        case commandID = "command_id"
        case agentConnected = "agent_connected"
        case rescueCommandID = "rescue_command_id"
    }

    var isFinal: Bool {
        status == "completed" || status == "failed" || status == "expired"
    }

    var modemConfirmed: Bool {
        status == "completed" && result?.modemConfirmed == true
    }

    var confirmationPhase: String {
        rescueCommandID == nil ? "modem_confirmed" : "rescue_modem_confirmed"
    }
}

enum CloudCallControlClientError: LocalizedError {
    case invalidRelayURL
    case invalidResponse
    case rejected(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL: return "Relay 地址无效"
        case .invalidResponse: return "Relay 返回了无效的通话控制响应"
        case let .rejected(message): return message
        case .timeout: return "等待 Agent 确认通话控制超时"
        }
    }
}

enum CloudCallControlClient {
    private struct Submission: Encodable {
        let action: String
        let callID: String
        let callUUID: String
        let generation: UInt64
        let commandID: String
        let traceID: String
        let owner = "iphone"
        let deviceID: String
        let deviceSecret: String

        enum CodingKeys: String, CodingKey {
            case action, generation, owner
            case callID = "call_id"
            case callUUID = "call_uuid"
            case commandID = "command_id"
            case traceID = "trace_id"
            case deviceID = "device_id"
            case deviceSecret = "device_secret"
        }
    }

    static func submissionRequest(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials
    ) throws -> URLRequest {
        guard let url = RelayEndpoint.url(
            base: credentials.relayURL,
            path: "/v1/calls/\(envelope.callUUID)/actions"
        ) else { throw CloudCallControlClientError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Submission(
            action: envelope.action,
            callID: envelope.callID,
            callUUID: envelope.callUUID,
            generation: envelope.generation,
            commandID: envelope.commandID,
            traceID: envelope.traceID,
            deviceID: credentials.deviceID,
            deviceSecret: credentials.deviceSecret
        ))
        return request
    }

    static func resultRequest(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials
    ) throws -> URLRequest {
        guard let url = RelayEndpoint.url(
            base: credentials.relayURL,
            path: "/v1/calls/\(envelope.callUUID)/actions/\(envelope.commandID)"
        ) else { throw CloudCallControlClientError.invalidRelayURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.deviceID, forHTTPHeaderField: "X-DJOneHub-Device-ID")
        return request
    }

    static func submit(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> CloudCallControlReceipt {
        try await execute(
            submissionRequest(envelope: envelope, credentials: credentials),
            session: session,
            acceptedStatusCodes: 200...202
        )
    }

    static func awaitFinalReceipt(
        envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials,
        session: URLSession = URLSession(configuration: .ephemeral),
        timeout: TimeInterval = 30
    ) async throws -> CloudCallControlReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let receipt: CloudCallControlReceipt = try await execute(
                resultRequest(envelope: envelope, credentials: credentials),
                session: session,
                acceptedStatusCodes: 200...200
            )
            if receipt.isFinal { return receipt }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CloudCallControlClientError.timeout
    }

    private static func execute<T: Decodable>(
        _ request: URLRequest,
        session: URLSession,
        acceptedStatusCodes: ClosedRange<Int>
    ) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudCallControlClientError.invalidResponse
        }
        guard acceptedStatusCodes.contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CloudCallControlClientError.rejected(detail ?? "Relay 拒绝了通话控制（HTTP \(http.statusCode)）")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudCallControlClientError.invalidResponse
        }
    }
}

/// iPhone 的公网 PCM 回退会话。PushKit 媒体密钥只保存在内存中；
/// CallKit 激活 AVAudioSession 后才启动麦克风和播放，控制 WebSocket 可提前接听模块来电。
@MainActor
final class IPhoneCloudCallSession {
    static let shared = IPhoneCloudCallSession()

    private let media = IPhoneCloudCallMediaBridge()
    private(set) var call: IncomingVoIPCall?
    private(set) var answered = false
    private(set) var lifecycleState: CallLifecycleState = .idle
    private(set) var audioState: CloudCallAudioState = .idle {
        didSet {
            guard audioState != oldValue else { return }
            onAudioStateChange?(audioState)
        }
    }
    private(set) var mediaHealthSnapshot = CloudMediaHealthSnapshot() {
        didSet { onMediaHealthChange?(mediaHealthSnapshot) }
    }
    var onAudioStateChange: ((CloudCallAudioState) -> Void)?
    var onMediaHealthChange: ((CloudMediaHealthSnapshot) -> Void)?
    var onLifecycleEvent: ((CallLifecycleEvent) -> Void)?
    private var audioRetryTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var mediaHealthTask: Task<Void, Never>?
    private var mediaHealthTracker: CloudMediaHealthTracker?
    private var answerRetryTask: Task<Void, Never>?
    private var answerRetryGeneration = 0
    private var answerAcknowledged = false

    var isPrepared: Bool { call != nil && media.isConnected }
    var hasActiveCall: Bool { call != nil && answered && lifecycleState == .active }
    private var canAttemptAudio: Bool {
        call != nil && answered && isPrepared &&
            (lifecycleState == .connecting || lifecycleState == .active)
    }
    var isRecovering: Bool { reconnectTask != nil }
    var isAudioRunning: Bool { media.isAudioRunning }

    private init() {
        media.onConnectionLost = {
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                session.answerAcknowledged = false
                session.requestMediaRebuild(.connectionLost)
            }
        }
        media.onControl = { control in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                let status = control.status
                let relayStatuses = ["action_queued", "action_forwarded", "peer_connected", "owner_claimed"]
                await AgentVerboseTraceRecorder.shared.recordEvent(
                    source: relayStatuses.contains(status) ? "RELAY" : "AGENT",
                    category: relayStatuses.contains(status) ? "relay" : "cloud-call-control",
                    phase: status,
                    title: control.action.map { "通话控制 · \($0)" } ?? "云端通话状态",
                    detail: control.message ?? "",
                    fields: control.traceFields,
                    isFailure: status == "action_error"
                )
                switch status {
                case _ where CloudCallAnswerPolicy.isAcknowledged(status: status):
                    session.confirmAnswer()
                    if status == "active" {
                        session.emitLifecycle(.active, source: .agent, traceID: control.traceID)
                    }
                case _ where CloudCallAnswerPolicy.shouldReplayImmediately(status: status):
                    session.replayAnswerIfNeeded()
                case "ownership_lost":
                    session.emitLifecycle(.ended, source: .relay, traceID: control.traceID)
                    CallKitController.shared.reportCurrentCallEnded(reason: .answeredElsewhere)
                    session.stop()
                case "rejected", "ended", "remote_ended":
                    session.emitLifecycle(
                        .ended,
                        source: status == "remote_ended" ? .relay : .agent,
                        traceID: control.traceID
                    )
                    CallKitController.shared.reportCurrentCallEnded(reason: .remoteEnded)
                    session.stop()
                case "pcm_recovering":
                    session.audioState = .connecting(
                        attempt: 1,
                        maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count
                    )
                case "pcm_stats":
                    if (control.downlinkBytes ?? 0) > 0, session.media.isAudioRunning {
                        session.audioState = .connected
                    }
                default:
                    break
                }
            }
        }
        media.onDownlinkPlayback = {
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                if session.hasActiveCall, session.media.isAudioRunning {
                    session.audioState = .connected
                }
            }
        }
        media.onDownlinkFrame = { bytes, peak, jitterBufferFrames, droppedFrames in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                session.mediaHealthTracker?.recordDownlink(
                    bytes: bytes,
                    peak: peak,
                    at: Date(),
                    jitterBufferFrames: jitterBufferFrames,
                    droppedFrames: droppedFrames
                )
                session.publishMediaHealth()
            }
        }
        media.onUplinkFrame = { bytes, peak in
            Task { @MainActor in
                let session = IPhoneCloudCallSession.shared
                session.mediaHealthTracker?.recordUplink(bytes: bytes, peak: peak, at: Date())
                session.publishMediaHealth()
            }
        }
    }

    func answer(_ incoming: IncomingVoIPCall) async throws {
        guard let url = incoming.authenticatedMediaURL else {
            throw IPhoneCloudCallError.mediaUnavailable
        }
        try media.prepareForCallKit()
        let callChanged = call?.uuid != incoming.uuid
        call = incoming
        answered = true
        lifecycleState = .connecting
        answerAcknowledged = false
        if callChanged || mediaHealthTracker == nil {
            mediaHealthTracker = CloudMediaHealthTracker(startedAt: Date(), maximumRebuilds: 3)
            mediaHealthTracker?.recordRoute(media.audioRouteDescription)
            publishMediaHealth()
        }
        if callChanged || !media.isConnected {
            media.stop()
            do {
                try await media.connect(to: url)
            } catch {
                // 系统接听动作不能因为第一次 WebSocket 建连抖动而直接失败。
                // 保留同一通话并在后台有界重连，成功后再补发 answer 控制帧。
                requestMediaRebuild(.connectionLost)
                scheduleAnswerConfirmation(for: incoming)
                return
            }
        }
        scheduleAnswerConfirmation(for: incoming)
    }

    func reject(_ incoming: IncomingVoIPCall) async throws {
        call = incoming
        answered = false
        guard let envelope = media.controlEnvelope(action: "reject", call: incoming),
              let credentials = VoIPPushController.shared.cloudCallControlCredentials() else {
            stop()
            throw IPhoneCloudCallError.mediaUnavailable
        }
        stop()
        submitPersistentControl(envelope, credentials: credentials)
    }

    func end() async {
        guard let call else {
            stop()
            return
        }
        let action = answered ? "end" : "reject"
        let envelope = media.controlEnvelope(action: action, call: call)
        let credentials = VoIPPushController.shared.cloudCallControlCredentials()
        await CloudCallTerminationCoordinator.finish(
            closeMedia: { [weak self] in self?.stop() },
            enqueuePersistentControl: { [weak self] in
                guard let self else { return }
                guard let envelope, let credentials else {
                    await self.tracePersistentControlUnavailable(action: action, call: call)
                    return
                }
                self.submitPersistentControl(envelope, credentials: credentials)
            }
        )
    }

    private func submitPersistentControl(
        _ envelope: CloudCallControlEnvelope,
        credentials: CloudCallControlCredentials
    ) {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DJOneHubCallControl")
        Task { @MainActor in
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            do {
                await tracePersistentControl(envelope, phase: "submitting")
                let receipt = try await CloudCallControlClient.submit(
                    envelope: envelope,
                    credentials: credentials
                )
                await tracePersistentControl(
                    envelope,
                    phase: receipt.agentConnected == true ? "forwarded" : "persisted",
                    detail: receipt.status
                )
                let final = receipt.isFinal ? receipt : try await CloudCallControlClient.awaitFinalReceipt(
                    envelope: envelope,
                    credentials: credentials
                )
                guard final.modemConfirmed else {
                    throw CloudCallControlClientError.rejected(
                        final.error ?? "Agent 未确认蜂窝通话已经结束"
                    )
                }
                await tracePersistentControl(
                    envelope,
                    phase: final.confirmationPhase,
                    detail: [
                        "CLCC 检查 \(final.result?.clccAttempts ?? 0) 次",
                        final.rescueCommandID.map { "救援命令 \($0)" },
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                emitLifecycle(from: envelope, state: .ended, source: .relay)
            } catch {
                await tracePersistentControl(
                    envelope,
                    phase: "failed",
                    detail: error.localizedDescription,
                    isFailure: true
                )
                emitLifecycle(
                    from: envelope,
                    state: .failed,
                    source: .relay,
                    failure: error.localizedDescription
                )
            }
        }
    }

    private func emitLifecycle(
        _ state: CallLifecycleState,
        source: CallLifecycleSource,
        traceID: String? = nil,
        failure: String? = nil
    ) {
        guard let call else { return }
        lifecycleState = state
        onLifecycleEvent?(CallLifecycleEvent(
            callID: call.callID,
            callUUID: call.uuid,
            generation: call.generation,
            state: state,
            source: source,
            timestamp: Date(),
            traceID: traceID,
            failure: failure
        ))
    }

    private func emitLifecycle(
        from envelope: CloudCallControlEnvelope,
        state: CallLifecycleState,
        source: CallLifecycleSource,
        failure: String? = nil
    ) {
        guard let uuid = UUID(uuidString: envelope.callUUID) else { return }
        lifecycleState = state
        onLifecycleEvent?(CallLifecycleEvent(
            callID: envelope.callID,
            callUUID: uuid,
            generation: envelope.generation,
            state: state,
            source: source,
            timestamp: Date(),
            traceID: envelope.traceID,
            failure: failure
        ))
    }

    private func tracePersistentControlUnavailable(action: String, call: IncomingVoIPCall) async {
        await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "APP",
            category: "cloud-call-control",
            phase: "credentials_unavailable",
            title: "通话控制 · \(action)",
            detail: "缺少 Relay 设备凭证",
            fields: [
                "action": action,
                "call_id": call.callID,
                "call_uuid": call.uuid.uuidString.lowercased(),
                "generation": String(call.generation),
            ],
            isFailure: true
        )
    }

    private func tracePersistentControl(
        _ envelope: CloudCallControlEnvelope,
        phase: String,
        detail: String = "",
        isFailure: Bool = false
    ) async {
        await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "APP",
            category: "cloud-call-control",
            phase: phase,
            title: "通话控制 · \(envelope.action)",
            detail: detail,
            fields: [
                "action": envelope.action,
                "call_id": envelope.callID,
                "call_uuid": envelope.callUUID,
                "generation": String(envelope.generation),
                "command_id": envelope.commandID,
                "trace_id": envelope.traceID,
            ],
            isFailure: isFailure
        )
    }

    func startAudio() throws {
        guard isPrepared else { throw IPhoneCloudCallError.connectionClosed }
        try media.startAudio()
        mediaHealthTracker?.recordRoute(media.audioRouteDescription)
        publishMediaHealth()
        startMediaHealthMonitoring()
    }

    func startAudioWithRetry() {
        guard canAttemptAudio else { return }
        if media.isAudioRunning {
            audioState = .connected
            traceAudio(phase: "already_running", title: "iPhone 云端音频已在运行")
            return
        }
        guard audioRetryTask == nil else { return }
        audioRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { audioRetryTask = nil }
            let delays = CloudCallRetryPolicy.audioDelays
            for (index, delay) in delays.enumerated() {
                guard !Task.isCancelled, canAttemptAudio else { return }
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, canAttemptAudio else { return }
                audioState = .connecting(attempt: index + 1, maximumAttempts: delays.count)
                guard isPrepared else { continue }
                traceAudio(
                    phase: "start_attempt",
                    title: "启动 iPhone 云端音频",
                    attempt: index + 1
                )
                do {
                    try startAudio()
                    audioState = media.hasReceivedDownlink
                        ? .connected
                        : .connecting(attempt: index + 1, maximumAttempts: delays.count)
                    traceAudio(
                        phase: "started",
                        title: "iPhone 云端音频已启动",
                        attempt: index + 1
                    )
                    return
                } catch {
                    let nsError = error as NSError
                    traceAudio(
                        phase: "start_failed",
                        title: "iPhone 云端音频启动失败",
                        detail: "\(nsError.domain) \(nsError.code) · \(error.localizedDescription)",
                        attempt: index + 1,
                        isFailure: true
                    )
                    guard CloudCallRetryPolicy.shouldRetryAudio(after: error),
                          index + 1 < delays.count else {
                        audioState = .failed(error.localizedDescription)
                        return
                    }
                }
            }
            audioState = .failed("云端 PCM 多次启动失败，请检查麦克风与网络")
        }
    }

    private func traceAudio(
        phase: String,
        title: String,
        detail: String = "",
        attempt: Int? = nil,
        isFailure: Bool = false
    ) {
        guard let call else { return }
        var fields = [
            "call_id": call.callID,
            "call_uuid": call.uuid.uuidString.lowercased(),
            "generation": String(call.generation),
            "audio_route": media.audioRouteDescription,
            "downlink_received": String(media.hasReceivedDownlink),
        ]
        if let attempt { fields["attempt"] = String(attempt) }
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "cloud-call-audio",
                phase: phase,
                title: title,
                detail: detail,
                fields: fields,
                isFailure: isFailure
            )
        }
    }

    func stopAudio() {
        audioRetryTask?.cancel()
        audioRetryTask = nil
        mediaHealthTask?.cancel()
        mediaHealthTask = nil
        media.stopAudio()
        audioState = hasActiveCall
            ? .connecting(attempt: 1, maximumAttempts: CloudCallRetryPolicy.audioDelays.count)
            : .idle
    }
    func setMuted(_ muted: Bool) { media.setMuted(muted) }

    func recordAudioRoute(_ route: String) {
        guard call != nil else { return }
        mediaHealthTracker?.recordRoute(route)
        publishMediaHealth()
    }

    func stop() {
        answerRetryGeneration &+= 1
        answerRetryTask?.cancel()
        answerRetryTask = nil
        audioRetryTask?.cancel()
        audioRetryTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        mediaHealthTask?.cancel()
        mediaHealthTask = nil
        media.stop()
        call = nil
        answered = false
        lifecycleState = .idle
        answerAcknowledged = false
        audioState = .idle
        mediaHealthTracker = nil
        mediaHealthSnapshot = CloudMediaHealthSnapshot()
    }

    private func scheduleAnswerConfirmation(for incoming: IncomingVoIPCall) {
        answerRetryGeneration &+= 1
        let generation = answerRetryGeneration
        answerRetryTask?.cancel()
        answerRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if answerRetryGeneration == generation { answerRetryTask = nil }
            }
            for delay in CloudCallAnswerPolicy.confirmationDelays {
                guard !Task.isCancelled,
                      answered,
                      !answerAcknowledged,
                      call?.uuid == incoming.uuid else { return }
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled,
                      answered,
                      !answerAcknowledged,
                      call?.uuid == incoming.uuid else { return }
                media.sendControl("answer", call: incoming)
            }
            guard answered, !answerAcknowledged, call?.uuid == incoming.uuid else { return }
            audioState = .failed("模块未确认接听，正在等待 Agent 控制通道恢复")
        }
    }

    private func replayAnswerIfNeeded() {
        guard answered, !answerAcknowledged, let call else { return }
        media.sendControl("answer", call: call)
    }

    private func confirmAnswer() {
        answerAcknowledged = true
        answerRetryGeneration &+= 1
        answerRetryTask?.cancel()
        answerRetryTask = nil
    }

    private func requestMediaRebuild(_ issue: CloudMediaHealthIssue) {
        guard reconnectTask == nil, let call, answered else { return }
        if mediaHealthTracker == nil {
            mediaHealthTracker = CloudMediaHealthTracker(startedAt: Date(), maximumRebuilds: 3)
        }
        guard mediaHealthTracker?.beginRebuild(for: issue, at: Date()) == true else {
            audioState = .failed("云端媒体已完成 3 次重建，停止自动重试")
            publishMediaHealth()
            traceMediaHealth(issue: issue, phase: "rebuild_exhausted", call: call, isFailure: true)
            return
        }
        publishMediaHealth()
        traceMediaHealth(issue: issue, phase: "rebuilding", call: call)
        recoverConnectionIfNeeded()
    }

    private func startMediaHealthMonitoring() {
        guard mediaHealthTask == nil else { return }
        mediaHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { mediaHealthTask = nil }
            while !Task.isCancelled, hasActiveCall, media.isAudioRunning {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, hasActiveCall, media.isAudioRunning,
                      let decision = mediaHealthTracker?.evaluate(at: Date()) else { continue }
                switch decision {
                case .none:
                    continue
                case let .rebuild(issue):
                    requestMediaRebuild(issue)
                    return
                case let .failed(issue):
                    audioState = .failed("云端媒体质量异常：\(issue.rawValue)")
                    if let call {
                        traceMediaHealth(issue: issue, phase: "failed", call: call, isFailure: true)
                    }
                    return
                }
            }
        }
    }

    private func publishMediaHealth() {
        mediaHealthSnapshot = mediaHealthTracker?.snapshot ?? CloudMediaHealthSnapshot()
    }

    private func traceMediaHealth(
        issue: CloudMediaHealthIssue,
        phase: String,
        call: IncomingVoIPCall,
        isFailure: Bool = false
    ) {
        let snapshot = mediaHealthSnapshot
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "cloud-media-health",
                phase: phase,
                title: "云端媒体自愈",
                detail: issue.rawValue,
                fields: [
                    "call_id": call.callID,
                    "call_uuid": call.uuid.uuidString.lowercased(),
                    "generation": String(call.generation),
                    "rebuild_count": String(snapshot.rebuildCount),
                    "downlink_frames": String(snapshot.downlinkFrames),
                    "uplink_frames": String(snapshot.uplinkFrames),
                    "audio_route": snapshot.audioRoute,
                ],
                isFailure: isFailure
            )
        }
    }

    private func recoverConnectionIfNeeded() {
        guard reconnectTask == nil, let call, answered,
              let url = call.authenticatedMediaURL else { return }
        media.stopAudio()
        audioState = .connecting(attempt: 1, maximumAttempts: CloudCallRetryPolicy.reconnectDelays.count)
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { reconnectTask = nil }
            let delays = CloudCallRetryPolicy.reconnectDelays
            var lastError: Error = IPhoneCloudCallError.connectionClosed
            for (index, delay) in delays.enumerated() {
                guard !Task.isCancelled, self.call?.uuid == call.uuid, answered else { return }
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, self.call?.uuid == call.uuid, answered else { return }
                audioState = .connecting(attempt: index + 1, maximumAttempts: delays.count)
                do {
                    media.stop()
                    try await media.connect(to: url)
                    answerAcknowledged = false
                    replayAnswerIfNeeded()
                    scheduleAnswerConfirmation(for: call)
                    startAudioWithRetry()
                    return
                } catch {
                    lastError = error
                }
            }
            audioState = .failed(lastError.localizedDescription)
            emitLifecycle(
                .failed,
                source: .relay,
                traceID: nil,
                failure: lastError.localizedDescription
            )
            CallKitController.shared.reportCurrentCallEnded(reason: .failed)
            stop()
        }
    }
}

private struct CloudCallControlOperationIdentity {
    let commandID: String
    let traceID: String
}

private final class IPhoneCloudCallMediaBridge: @unchecked Sendable {
    var onConnectionLost: (() -> Void)?
    var onControl: ((CloudPCMControlMessage) -> Void)?
    var onDownlinkPlayback: (() -> Void)?
    var onDownlinkFrame: ((_ bytes: Int, _ peak: Int, _ jitterBufferFrames: Int, _ droppedFrames: Int) -> Void)?
    var onUplinkFrame: ((_ bytes: Int, _ peak: Int) -> Void)?

    private let queue = DispatchQueue(label: "com.eric3u.airsim.iphone-cloud-media")
    private var webSocket: URLSessionWebSocketTask?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var encoder: IPhoneCloudVoicePCMEncoder?
    private var uplinkBuffer = Data()
    private var pendingDownlink = Data()
    private var scheduledFrames = 0
    private(set) var hasReceivedDownlink = false
    private var muted = false
    private var stopped = true
    private var controlOperations: [String: CloudCallControlOperationIdentity] = [:]

    var isConnected: Bool {
        queue.sync { webSocket != nil && !stopped }
    }

    var isAudioRunning: Bool { engine?.isRunning == true }

    var audioRouteDescription: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
        return outputs.isEmpty ? "unknown" : outputs.joined(separator: ",")
    }

    func prepareForCallKit() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        // 每通电话从听筒开始；用户随后可在通话页切换扬声器。
        try session.overrideOutputAudioPort(.none)
    }

    func connect(to url: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: IPhoneCloudCallError.connectionClosed)
                    return
                }
                stopped = false
                let socket = URLSession(configuration: .ephemeral).webSocketTask(with: url)
                webSocket = socket
                socket.resume()
                receiveNext(socket)
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    func sendControl(_ action: String, call: IncomingVoIPCall) {
        queue.async { [weak self] in
            guard let self, let socket = webSocket,
                  let (text, envelope) = controlText(action: action, call: call) else { return }
            traceControl(envelope, phase: "sending")
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                self?.traceControl(envelope, phase: "send_failed", detail: error.localizedDescription, isFailure: true)
            }
        }
    }

    func sendControlAndWait(_ action: String, call: IncomingVoIPCall) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !stopped, let socket = webSocket else {
                    continuation.resume()
                    return
                }
                guard let (text, envelope) = controlText(action: action, call: call) else {
                    continuation.resume()
                    return
                }
                traceControl(envelope, phase: "sending")
                socket.send(.string(text)) { [weak self] error in
                    if let error {
                        self?.traceControl(envelope, phase: "send_failed", detail: error.localizedDescription, isFailure: true)
                    } else {
                        self?.traceControl(envelope, phase: "socket_sent")
                    }
                    continuation.resume()
                }
            }
        }
    }

    func controlEnvelope(action: String, call: IncomingVoIPCall) -> CloudCallControlEnvelope? {
        queue.sync { controlEnvelopeLocked(action: action, call: call) }
    }

    private func controlText(
        action: String,
        call: IncomingVoIPCall
    ) -> (String, CloudCallControlEnvelope)? {
        guard let envelope = controlEnvelopeLocked(action: action, call: call) else { return nil }
        guard let data = try? JSONEncoder().encode(envelope),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, envelope)
    }

    private func controlEnvelopeLocked(
        action: String,
        call: IncomingVoIPCall
    ) -> CloudCallControlEnvelope? {
        let operationKey = "\(call.uuid.uuidString.lowercased()):\(action)"
        let identity: CloudCallControlOperationIdentity
        if let existing = controlOperations[operationKey] {
            identity = existing
        } else {
            let commandID = UUID().uuidString.lowercased()
            identity = CloudCallControlOperationIdentity(
                commandID: commandID,
                traceID: String(commandID.prefix(8))
            )
            controlOperations[operationKey] = identity
        }
        let envelope = CloudCallControlEnvelope(
            action: action,
            callID: call.callID,
            callUUID: call.uuid.uuidString.lowercased(),
            generation: call.generation,
            commandID: identity.commandID,
            traceID: identity.traceID
        )
        return envelope
    }

    private func traceControl(
        _ envelope: CloudCallControlEnvelope,
        phase: String,
        detail: String = "",
        isFailure: Bool = false
    ) {
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "cloud-call-control",
                phase: phase,
                title: "通话控制 · \(envelope.action)",
                detail: detail,
                fields: [
                    "action": envelope.action,
                    "call_id": envelope.callID,
                    "call_uuid": envelope.callUUID,
                    "generation": String(envelope.generation),
                    "command_id": envelope.commandID,
                    "trace_id": envelope.traceID,
                ],
                isFailure: isFailure
            )
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in
            self?.muted = muted
            self?.encoder?.setMuted(muted)
        }
    }

    func startAudio() throws {
        if engine?.isRunning == true { return }
        if #available(iOS 17.0, *) {
            guard AVAudioApplication.shared.recordPermission == .granted else {
                throw IPhoneCloudCallError.microphonePermissionDenied
            }
        } else if AVAudioSession.sharedInstance().recordPermission != .granted {
            throw IPhoneCloudCallError.microphonePermissionDenied
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let encoder = IPhoneCloudVoicePCMEncoder()
        encoder.setMuted(muted)
        engine.attach(player)
        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        ) else { throw IPhoneCloudCallError.invalidAudioFormat }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate >= 8_000 else {
            throw IPhoneCloudCallError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm = encoder.encode(buffer)
            if !pcm.isEmpty { enqueueUplink(pcm) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            throw error
        }
        player.play()
        self.engine = engine
        self.player = player
        self.encoder = encoder
        if !pendingDownlink.isEmpty {
            let pending = pendingDownlink
            pendingDownlink.removeAll(keepingCapacity: true)
            schedulePlayback(pending)
        }
    }

    func stopAudio() {
        if engine != nil { engine?.inputNode.removeTap(onBus: 0) }
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        encoder = nil
        scheduledFrames = 0
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = true
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
            uplinkBuffer.removeAll(keepingCapacity: false)
            controlOperations.removeAll(keepingCapacity: false)
        }
        DispatchQueue.main.async { [weak self] in
            self?.stopAudio()
            self?.pendingDownlink.removeAll(keepingCapacity: false)
            self?.hasReceivedDownlink = false
        }
    }

    private func receiveNext(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            queue.async {
                guard !self.stopped, self.webSocket === socket else { return }
                switch result {
                case let .success(.data(data)):
                    DispatchQueue.main.async { self.schedulePlayback(data) }
                    self.receiveNext(socket)
                case let .success(.string(text)):
                    self.consumeControl(text)
                    self.receiveNext(socket)
                case .success:
                    self.receiveNext(socket)
                case .failure:
                    self.webSocket = nil
                    self.stopped = true
                    self.onConnectionLost?()
                }
            }
        }
    }

    private func consumeControl(_ text: String) {
        guard let control = try? CloudPCMControlMessage.decode(text) else { return }
        onControl?(control)
    }

    private func enqueueUplink(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            uplinkBuffer.append(data)
            while uplinkBuffer.count >= 320 {
                let frame = Data(uplinkBuffer.prefix(320))
                uplinkBuffer.removeFirst(320)
                onUplinkFrame?(frame.count, Self.peak(of: frame))
                webSocket?.send(.data(frame)) { _ in }
            }
            if uplinkBuffer.count > 2_560 {
                uplinkBuffer = Data(uplinkBuffer.suffix(320))
            }
        }
    }

    private func schedulePlayback(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        hasReceivedDownlink = true
        let frameCount = max(1, pcm.count / 320)
        let pcmPeak = Self.peak(of: pcm)
        guard let player, engine?.isRunning == true else {
            pendingDownlink.append(pcm)
            var droppedFrames = 0
            if pendingDownlink.count > 3_200 {
                droppedFrames = max(1, (pendingDownlink.count - 3_200) / 320)
                pendingDownlink = Data(pendingDownlink.suffix(3_200))
            }
            onDownlinkFrame?(
                pcm.count,
                pcmPeak,
                max(0, pendingDownlink.count / 320),
                droppedFrames
            )
            return
        }
        let frames = pcm.count / 2
        guard frames > 0 else { return }
        guard scheduledFrames + frames <= 3_200 else {
            onDownlinkFrame?(pcm.count, pcmPeak, max(0, scheduledFrames / 160), frameCount)
            return
        }
        guard
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 8_000,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ), let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                let bits = UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8
                output[frame] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        scheduledFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async {
                self?.scheduledFrames = max(0, (self?.scheduledFrames ?? 0) - frames)
            }
        }
        if !player.isPlaying { player.play() }
        onDownlinkFrame?(pcm.count, pcmPeak, max(0, scheduledFrames / 160), 0)
        onDownlinkPlayback?()
    }

    private static func peak(of pcm: Data) -> Int {
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var peak = 0
            var offset = 0
            while offset + 1 < bytes.count {
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let sample = Int(Int16(bitPattern: bits))
                peak = max(peak, sample == -32_768 ? 32_768 : abs(sample))
                offset += 2
            }
            return peak
        }
    }
}

struct CloudPCMResampler {
    private var samples: [Float] = []
    private var position = 0.0
    private var sampleRate = 0.0

    mutating func encode(samples input: [Float], sampleRate rate: Double, muted: Bool) -> Data {
        guard !input.isEmpty, rate >= 8_000 else { return Data() }
        if sampleRate != rate {
            sampleRate = rate
            samples.removeAll(keepingCapacity: true)
            position = 0
        }
        samples.append(contentsOf: input)
        let step = rate / 8_000
        var output = Data()
        output.reserveCapacity(input.count / max(1, Int(step)) * 2 + 4)
        while position + 1 < Double(samples.count) {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let value = samples[index] + (samples[index + 1] - samples[index]) * fraction
            let scaled = muted ? Int16(0) : Int16(max(-1, min(1, value)) * 32_767)
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
            position += step
        }
        let consumed = max(0, min(Int(position), samples.count - 1))
        if consumed > 0 {
            samples.removeFirst(consumed)
            position -= Double(consumed)
        }
        if samples.count > Int(rate) {
            samples = Array(samples.suffix(max(2, Int(rate / 10))))
            position = 0
        }
        return output
    }
}

private final class IPhoneCloudVoicePCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var resampler = CloudPCMResampler()
    private var muted = false

    func setMuted(_ muted: Bool) {
        lock.lock(); self.muted = muted; lock.unlock()
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channel = buffer.floatChannelData?[0] else { return Data() }
        let input = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rate = buffer.format.sampleRate
        lock.lock()
        defer { lock.unlock() }
        return resampler.encode(samples: input, sampleRate: rate, muted: muted)
    }
}
