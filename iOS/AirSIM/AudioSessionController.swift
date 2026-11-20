import AVFoundation
import CallKit
import UIKit
import Network

/// Keep the codec's 8 kHz rate out of VoiceProcessingIO's hardware bus.
enum CallAudioGraph {
    static func connectPlayback(_ player: AVAudioPlayerNode, engine: AVAudioEngine,
                                format: AVAudioFormat) throws {
        let hardware = engine.outputNode.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw VoiceAudioError.microphoneUnavailable
        }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    static func installCapture(_ input: AVAudioInputNode, format: AVAudioFormat?,
                               block: @escaping AVAudioNodeTapBlock) throws {
        let rate = input.outputFormat(forBus: 0).sampleRate
        guard rate > 0, input.outputFormat(forBus: 0).channelCount > 0 else {
            throw VoiceAudioError.microphoneUnavailable
        }
        // The native tap preserves the I/O format. Never reapply a stale format
        // after VoiceProcessingIO replaces/configures its buses.
        if #available(iOS 27.0, *) {
            try input.__installTap(onBus: 0, bufferSize: AVAudioFrameCount(max(1024, rate * 0.1)),
                                   format: nil, error: (), block: block)
        } else {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: block)
        }
    }
}

@MainActor
protocol CallToneOutput: AnyObject {
    var isPlaying: Bool { get }
    func play(_ data: Data, looping: Bool, volume: Float, configureSession: Bool) throws
    func stop(deactivateSession: Bool)
}

@MainActor
final class SystemCallToneOutput: CallToneOutput {
    private var player: AVAudioPlayer?
    var isPlaying: Bool { player?.isPlaying == true }
    func play(_ data: Data, looping: Bool, volume: Float, configureSession: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if configureSession {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        }
        let player = try AVAudioPlayer(data: data)
        player.numberOfLoops = looping ? -1 : 0; player.volume = volume
        player.prepareToPlay()
        guard player.play() else { throw VoiceAudioError.tonePlaybackFailed }
        self.player = player
    }
    func stop(deactivateSession: Bool) {
        player?.stop(); player = nil
        guard deactivateSession, !CallKitController.shared.audioSessionIsActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum PCMRoute: Equatable, Sendable {
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)

    var host: String {
        switch self {
        case let .vowlan(endpoint, _): return endpoint.host
        }
    }

    var port: UInt16 {
        switch self {
        case let .vowlan(endpoint, _): return endpoint.pcmPort
        }
    }

    var usesTLS: Bool {
        if case let .vowlan(endpoint, _) = self { return endpoint.usesTLS }
        return false
    }

    var requiresWiFi: Bool {
        if case let .vowlan(endpoint, _) = self { return !VoWLANNetworkRoutePolicy.usesSystemRouting(host: endpoint.host) }
        return false
    }

    var usesSystemRouting: Bool {
        if case let .vowlan(endpoint, _) = self { return VoWLANNetworkRoutePolicy.usesSystemRouting(host: endpoint.host) }
        return false
    }

    /// VPN wording is reserved for tailnet/CGNAT addresses, not every private LAN.
    var isOverlayHost: Bool {
        if case let .vowlan(endpoint, _) = self { return VoWLANNetworkRoutePolicy.isOverlayHost(endpoint.host) }
        return false
    }

    func earlyMediaHandshake(_ grant: EarlyMediaGrant) throws -> Data {
        guard case let .vowlan(_, credential) = self,
              grant.permits(agentID: grant.agentID, callID: grant.callID,
                  now: Int64(Date().timeIntervalSince1970 + credential.clockOffset)) else {
            throw VoWLANAuthError.invalidSecret
        }
        let binding = "\(grant.agentID)\n\(grant.callID)\n\(grant.sessionID)\n\(grant.expiresAt)\nrecvonly\ns16le-8000-mono"
        let signed = try VoWLANRequestSigner(credential: credential).sign(
            method: "PCM", path: "/v1/pcm/early-media", body: Data(binding.utf8))
        let payload = Data(binding.utf8).base64EncodedString()
        return Data("AIRSIMEM1 \(signed.timestamp) \(signed.nonce) \(signed.signature) \(payload)\n".utf8)
    }

    func handshake() throws -> Data {
        switch self {
        case let .vowlan(_, credential): return try VoWLANPCMHandshake.make(credential: credential)
        }
    }
}

enum VoWLANPCMHandshake {
    static func make(
        credential: VoWLANCredential,
        timestamp: Int64? = nil,
        nonce: String = VoWLANRequestSigner.makeNonce()
    ) throws -> Data {
        let signed = try VoWLANRequestSigner(credential: credential).sign(
            method: "PCM", path: "/v1/pcm", body: Data(), timestamp: timestamp, nonce: nonce
        )
        return Data("AIRSIMVWL1 \(signed.timestamp) \(signed.nonce) \(signed.signature)\n".utf8)
    }
}

final class PCMHandshakeSequence {
    private let makeHandshake: () throws -> Data

    init(makeHandshake: @escaping () throws -> Data) {
        self.makeHandshake = makeHandshake
    }

    func next() throws -> Data {
        try makeHandshake()
    }
}

/// Transport progress and playback evidence are independent of signal amplitude.
struct PCMBridgeHealth {
    enum Phase: String { case connecting, handshaking, waiting, verifying, flowing, playbackFailed, failed }
    struct Assessment {
        let phase: Phase
        let text: String
        let warning: String?
        let repairPlayback: Bool
    }
    private(set) var handshakeAt: TimeInterval?
    private(set) var downlinkAt: TimeInterval?
    private(set) var uplinkAt: TimeInterval?
    private(set) var renderedAt: TimeInterval?
    private(set) var recoveryAt: TimeInterval?
    private(set) var recoveryAttempts = 0
    private(set) var reconnects = 0
    private(set) var lastFailurePhase: String?
    private(set) var lastRecoveryDuration: TimeInterval?
    private var phase: Phase = .connecting
    private var transportRecoveryAt: TimeInterval?
    mutating func networkReady() { phase = .handshaking }
    mutating func handshake(now: TimeInterval) {
        phase = .waiting; handshakeAt = now
        downlinkAt = nil; uplinkAt = nil; renderedAt = nil
    }
    mutating func reconnect(now: TimeInterval = 0) {
        if transportRecoveryAt == nil { transportRecoveryAt = now }
        reconnects += 1; phase = .connecting; handshakeAt = nil
        downlinkAt = nil; uplinkAt = nil; renderedAt = nil
        lastFailurePhase = "transport"
    }
    mutating func failed() { phase = .failed; handshakeAt = nil; lastFailurePhase = "transport" }
    mutating func downlink(now: TimeInterval) { downlinkAt = now }
    mutating func uplink(now: TimeInterval) { uplinkAt = now }
    mutating func rendered(now: TimeInterval) { renderedAt = now }
    mutating func repairing(now: TimeInterval) {
        recoveryAt = now; recoveryAttempts += 1; lastFailurePhase = "playback"
    }
    mutating func assess(now: TimeInterval, engineRunning: Bool, playerPlaying: Bool,
                         receiveOnly: Bool) -> Assessment {
        func result(_ phase: Phase, _ text: String, warning: Bool = false, repair: Bool = false) -> Assessment {
            Assessment(phase: phase, text: text, warning: warning ? text : nil, repairPlayback: repair)
        }
        guard let handshakeAt else {
            if phase == .failed { return result(.failed, "音频连接失败，自动重连窗口已耗尽", warning: true) }
            return result(phase, phase == .handshaking ? "网络已连接，正在认证音频握手" : "正在连接或重连音频桥")
        }
        guard let downlinkAt, downlinkAt >= handshakeAt, now - downlinkAt < 6 else {
            // Missing data alone is not proof of a broken bridge, and never restarts it.
            return result(.waiting, "音频已握手，等待下行数据验证（暂不判断故障）")
        }
        let boundary = max(handshakeAt, recoveryAt ?? handshakeAt)
        let playbackStalled = now - max(renderedAt ?? boundary, boundary) >= 6
        if !engineRunning || !playerPlaying || playbackStalled {
            lastFailurePhase = "playback"
            return result(.playbackFailed, "音频数据正在到达，但本机播放未正常推进", warning: true, repair: true)
        }
        let played = renderedAt.map { $0 > boundary && now - $0 < 6 } ?? false
        let sent = receiveOnly || (uplinkAt.map { $0 > boundary && now - $0 < 6 } ?? false)
        guard downlinkAt > boundary, played, sent else {
            return result(.verifying, !played ? "已收到下行数据，等待播放回调验证" : "下行与播放已验证，等待上行数据")
        }
        if let began = transportRecoveryAt ?? recoveryAt {
            lastRecoveryDuration = max(0, now - began)
            self.recoveryAt = nil; transportRecoveryAt = nil
        }
        return result(.flowing, receiveOnly ? "下行数据与播放回调已验证" : "上下行数据与播放回调已验证")
    }
}

struct PCMReconnectBudget {
    private(set) var attempts = 0
    mutating func reset() { attempts = 0 }
    mutating func nextDelay() -> TimeInterval? {
        guard attempts < 20 else { return nil }
        let delay = min(3, 0.25 * pow(2, Double(min(attempts, 4))))
        attempts += 1; return delay
    }
}

struct PlaybackRecoveryBudget {
    private(set) var attempts = 0
    private var lastAttempt: TimeInterval = -.infinity
    mutating func claim(now: TimeInterval) -> Bool {
        guard attempts < 3, now - lastAttempt >= 10 else { return false }
        attempts += 1; lastAttempt = now; return true
    }
}

enum SpeakerRoutePolicy {
    static let retryDelays: [TimeInterval] = [0, 0.15, 0.35, 0.7, 1.2]
    static let routeVerificationDelay: TimeInterval = 0.08

    static func toggledTarget(
        currentRouteIsSpeaker: Bool,
        pendingTarget: Bool? = nil
    ) -> Bool {
        !(pendingTarget ?? currentRouteIsSpeaker)
    }

    static func routeMatches(requestedSpeaker: Bool, currentRouteIsSpeaker: Bool) -> Bool {
        requestedSpeaker == currentRouteIsSpeaker
    }

    static func requestedSpeakerAfterSystemRouteChange(
        requestedSpeaker: Bool,
        observedRouteIsSpeaker: Bool
    ) -> Bool {
        // observedRouteIsSpeaker is deliberately not adopted: CallKit can briefly expose the
        // previous playback route while activating a new call. Only the user's button changes
        // the requested override.
        _ = observedRouteIsSpeaker
        return requestedSpeaker
    }
}

enum CallHeadphoneIcon {
    static func symbol(for name: String,
                       isAvailable: (String) -> Bool = { UIImage(systemName: $0) != nil }) -> String {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let candidates: [String]
        if key.contains("airpodsmax") { candidates = ["airpodsmax", "headphones"] }
        else if key.contains("airpodspro") { candidates = ["airpodspro", "headphones"] }
        else if let range = key.range(of: "airpods") {
            let suffix = String(key[range.upperBound...])
            func generation(_ digit: String, _ chinese: String, _ ordinal: String) -> Bool {
                suffix.hasPrefix(digit) || suffix.contains("gen" + digit)
                    || suffix.contains("generation" + digit) || suffix.contains(digit + ordinal + "generation")
                    || suffix.contains("第" + digit + "代") || suffix.contains("第" + chinese + "代")
            }
            if generation("5", "五", "th") {
                // AirPods 4 and 5 use the same short-stem silhouette.
                candidates = ["airpods.gen4", "airpods.gen3", "airpods", "headphones"]
            } else if generation("4", "四", "th") {
                candidates = ["airpods.gen4", "airpods.gen3", "airpods", "headphones"]
            } else if generation("3", "三", "rd") {
                candidates = ["airpods.gen3", "airpods", "headphones"]
            } else if generation("1", "一", "st") || generation("2", "二", "nd") {
                candidates = ["airpods", "headphones"]
            } else { candidates = ["headphones"] }
        } else { candidates = ["headphones"] }
        return candidates.first(where: isAvailable) ?? "headphones"
    }
}

struct CallAudioRouteChoice: Identifiable {
    let id: String
    let title: String
    let icon: String
    let selected: Bool
}

/// 管理 iPhone/iPad 内置麦克风、扬声器与 VoWLAN 网络 PCM 之间的双向通话音频。
@MainActor
final class AudioSessionController: ObservableObject {
    @Published private(set) var audioHealthText = "当前没有通话音频会话"
    @Published private(set) var audioHealthWarning: String?
    private var lastDownlinkUptime: TimeInterval?
    private var playbackRecoveryBudget = PlaybackRecoveryBudget()
    private var playbackRecoveryOwner: UUID?
    private var audioHealthTask: Task<Void, Never>?
    private var bridgeHealth = PCMBridgeHealth()
    private var observedUplinkBytes: UInt64 = 0
    private var observedDownlinkBytes: UInt64 = 0
    private var lastHealthPhase: PCMBridgeHealth.Phase?
    @Published private(set) var active = false
    @Published private(set) var routeDescription = ""
    @Published private(set) var transportReady = false
    @Published private(set) var hasReceivedEarlyMedia = false
    @Published private(set) var diagnosticDescription = ""
    @Published private(set) var moduleDiagnosticDescription = ""
    @Published private(set) var speakerEnabled = false
    @Published private(set) var callOutputName = "iPhone"
    @Published private(set) var callOutputIcon = "iphone"
    @Published private(set) var hasExternalCallRoutes = false
    private var systemRouteSelectionActive = false
    private var bluetoothSuppressedForReceiver = false
    private var knownExternalCallPorts: [AVAudioSessionPortDescription] = []
    private var preferredCallCategoryOptions: AVAudioSession.CategoryOptions {
        requestedCallRouteID == "receiver" ? [] : [.allowBluetoothHFP]
    }
    private var callRouteSelectionTask: Task<Void, Never>?
    private(set) var requestedCallRouteID: String?
    private var callRouteSelectionGeneration: UInt64 = 0
    private let applyRouteForTesting: ((String) throws -> Void)?
    private let readRouteForTesting: (() -> String?)?
    @Published private(set) var changingCallRoute = false
    @Published private(set) var callRouteChoices: [CallAudioRouteChoice] = []
    @Published private(set) var speakerRoutePending = false
    @Published var errorMessage: String?

    let levelMeter = CallAudioLevelMeter()

    private var engine: AVAudioEngine?
    private(set) var sessionOwner: UUID?
    private(set) var receiveOnly = false
    private var earlyMediaLease: EarlyMediaLeaseState?
    private var earlyMediaClockOffset: TimeInterval = 0
    private var captureInstalled = false
    private var player: AVAudioPlayerNode?
    private var transport: NetworkPCMTransport?
    private var encoder: VoicePCMEncoder?
    private let toneOutput: any CallToneOutput
    private let overrideSpeakerRoute: (Bool) throws -> Void
    private let makeEngine: () -> AVAudioEngine
    private var currentCallTone: CallTone?
    private var endedToneTask: Task<Void, Never>?
    private var incomingRingtoneTask: Task<Void, Never>?
    private var incomingRingtoneWindow: (callID: String, deadline: ContinuousClock.Instant)?
    var hasCallTone: Bool { currentCallTone != nil }
    private(set) var muted = false
    private var requestedSpeakerOverride = false
    private var speakerRouteRetryTask: Task<Void, Never>?
    private var sessionActivationManagedByCallKit = false
    private var routeChangeObserver: NSObjectProtocol?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var earlyPlaybackRecoveryTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0
    private var playbackQueue = PlaybackQueueTracker(maximumFrames: 4_000)
    private var startupUptime: TimeInterval = 0
    private var recordedFirstDownlink = false

    private func recordStartup(_ phase: String) {
        let elapsed = Int(max(0, ProcessInfo.processInfo.systemUptime - startupUptime) * 1_000)
        let carrierRingback = phase == "first_downlink" && receiveOnly
        Task { await AgentVerboseTraceRecorder.shared.recordAudioStartup(
            phase: phase, elapsedMilliseconds: elapsed, carrierRingback: carrierRingback
        ) }
    }

    init(toneOutput: (any CallToneOutput)? = nil,
         makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         applyCallRoute: ((String) throws -> Void)? = nil,
         readCallRoute: (() -> String?)? = nil,
         overrideSpeakerRoute: @escaping (Bool) throws -> Void = {
             try AVAudioSession.sharedInstance().overrideOutputAudioPort($0 ? .speaker : .none)
         }) {
        self.toneOutput = toneOutput ?? SystemCallToneOutput()
        self.applyRouteForTesting = applyCallRoute
        self.readRouteForTesting = readCallRoute
        self.overrideSpeakerRoute = overrideSpeakerRoute
        self.makeEngine = makeEngine
        // CallKit、蓝牙或系统控制中心都可能改变输出路由，按钮状态必须跟随真实会话。
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleRouteChange(notification) }
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["AIRSIM_UI_FIXTURE"] == "sms-navigation",
           ProcessInfo.processInfo.environment["AIRSIM_UI_AUDIO_ROUTES"] == "external" {
            hasExternalCallRoutes = true
            callOutputName = "AirPods 5"
            callOutputIcon = "airpods.gen4"
            callRouteChoices = [
                .init(id: "speaker", title: "扬声器", icon: "speaker.wave.2.fill", selected: false),
                .init(id: "receiver", title: "iPhone", icon: "iphone", selected: false),
                .init(id: "fixture-headset", title: "AirPods 5", icon: "airpods.gen4", selected: true)
            ]
        }
#endif

#if DEBUG
        if ProcessInfo.processInfo.environment["AIRSIM_AUDIO_ROUTE_SELFTEST"] == "1", !Self.physicalRouteSelfTestStarted {
            Self.physicalRouteSelfTestStarted = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.physicalRouteSelfTest()
            }
        }
#endif

    }

#if DEBUG
    private static var physicalRouteSelfTestStarted = false
    private func physicalRouteSelfTest() async {
        let session = AVAudioSession.sharedInstance()
        guard !CXCallObserver().calls.contains(where: { !$0.hasEnded }), !active,
              session.recordPermission == .granted else { return }
        let category = session.category, mode = session.mode, options = session.categoryOptions
        let preferredUID = session.preferredInput?.uid
        let diagnosticEngine = AVAudioEngine()
        var diagnosticTapInstalled = false
        let wasSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        defer {
            diagnosticEngine.stop()
            if diagnosticTapInstalled { diagnosticEngine.inputNode.removeTap(onBus: 0) }
            prepareForSystemRouteSelection()
            if !CXCallObserver().calls.contains(where: { !$0.hasEnded }) {
                try? session.overrideOutputAudioPort(.none)
                try? session.setPreferredInput(session.availableInputs?.first { $0.uid == preferredUID })
                if wasSpeaker && category == .playAndRecord { try? session.overrideOutputAudioPort(.speaker) }
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                try? session.setCategory(category, mode: mode, options: options)
            }
        }
        do {
            try configureCallAudioSession()
            try session.setActive(true)
            let input = diagnosticEngine.inputNode
            try input.setVoiceProcessingEnabled(true)
            // Drain locally only; no audio is stored, played or transmitted.
            input.installTap(onBus: 0, bufferSize: 480, format: nil) { _, _ in }
            diagnosticTapInstalled = true
            diagnosticEngine.prepare()
            try diagnosticEngine.start()
            try await Task.sleep(for: .milliseconds(300))
            let ids = ["receiver", "speaker"] + (session.availableInputs ?? []).filter { $0.portType != .builtInMic }.map(\.uid)
            for id in ids {
                guard !CXCallObserver().calls.contains(where: { !$0.hasEnded }) else { return }
                selectCallRoute(id)
                await callRouteSelectionTask?.value
                await AgentVerboseTraceRecorder.shared.recordEvent(source: "APP", category: "audio-route",
                    phase: "hardware_selftest", title: "本机音频输出自测（不拨号）", fields: [
                        "target": ["receiver", "speaker"].contains(id) ? id : "headset",
                        "matched": String(currentCallRouteID() == id),
                        "output_types": session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","),
                        "input_types": session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","),
                        "engine_running": String(diagnosticEngine.isRunning)])
            }
        } catch {
            await AgentVerboseTraceRecorder.shared.recordFailure(category: "audio-route", phase: "hardware_selftest", error: error)
        }
    }
#endif

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
    }

    var microphonePermissionIsUndetermined: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .undetermined
        }
        return AVAudioSession.sharedInstance().recordPermission == .undetermined
    }

    func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        // iOS 16 仍通过 AVAudioSession 的回调接口请求录音权限。
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    @discardableResult
    func activateForCall(
        route: PCMRoute,
        sessionAlreadyActive: Bool = false,
        owner: UUID = UUID(),
        earlyMedia: EarlyMediaGrant? = nil,
        isCurrent: () -> Bool = { true }
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        guard !active else { return true }
        lastDownlinkUptime = nil
        bridgeHealth = PCMBridgeHealth(); observedUplinkBytes = 0; observedDownlinkBytes = 0; lastHealthPhase = nil
        audioHealthText = "正在建立音频连接"; audioHealthWarning = nil
        startupUptime = ProcessInfo.processInfo.systemUptime
        recordedFirstDownlink = false
        hasReceivedEarlyMedia = false
        recordStartup("phone_start")
        let receiveOnly = earlyMedia != nil
        let permission: Bool
        if receiveOnly { permission = true }
        else { permission = await requestMicrophonePermission() }
        // Authorization may outlive the call that asked for it.
        guard !Task.isCancelled, isCurrent() else { return false }
        guard permission else {
            recordStartup("failed")
            errorMessage = "需要麦克风权限才能进行双向通话"
            return false
        }

        levelMeter.beginSession(owner, uplinkMuted: muted || receiveOnly)
        let levelMeter = self.levelMeter
        var startupPhase = "configure_session"
        do {
            let session = AVAudioSession.sharedInstance()
            sessionActivationManagedByCallKit = sessionAlreadyActive
            if receiveOnly {
                // Playback-only sessions cannot route to the built-in receiver.
                // Keep capture disabled below, but allow both call outputs.
                if !sessionAlreadyActive {
                    try session.setCategory(.playAndRecord, mode: .default, options: preferredCallCategoryOptions)
                }
            } else { try configureCallAudioSession() }
            if !sessionAlreadyActive {
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
            // 每次通话默认使用听筒；仅在用户主动开启扬声器后覆盖输出路由。
            // Route changes can be rejected while CallKit activates audio.
            // A pending output preference must never abort carrier playback.
            if !systemRouteSelectionActive { try? overrideSpeakerRoute(requestedSpeakerOverride) }
            refreshRouteDescription()

            let engine = makeEngine()
            let player = AVAudioPlayerNode()
            let encoder = VoicePCMEncoder()
            // 用户可能在权限弹窗或音频启动期间切换静音，新编码器必须继承期望状态。
            encoder.setMuted(muted)
            let earlyLease = earlyMedia.map(EarlyMediaLeaseState.init)
            let handshakeSequence = PCMHandshakeSequence {
                if let earlyLease { return try route.earlyMediaHandshake(earlyLease.current()) }
                return try route.handshake()
            }
            let transport = NetworkPCMTransport(
                host: NWEndpoint.Host(route.host),
                port: NWEndpoint.Port(rawValue: route.port)!,
                handshakeSequence: handshakeSequence,
                requiresWiFi: route.requiresWiFi,
                usesSystemRouting: route.usesSystemRouting,
                usesTLS: route.usesTLS,
                isOverlayHost: route.isOverlayHost,
                receiveOnly: receiveOnly,
                onPCM: { [weak self] pcm in
                    Task { @MainActor [weak self] in
                        guard self?.sessionOwner == owner else { return }
                        self?.schedulePlayback(pcm)
                    }
                },
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard self?.sessionOwner == owner else { return }
                        self?.handleTransportEvent(event)
                    }
                }
            )

            engine.attach(player)
            startupPhase = "enable_voice_processing"
            // Switching I/O must precede all fixed-rate graph connections.
            if !receiveOnly { try engine.inputNode.setVoiceProcessingEnabled(true) }
            guard let playbackFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 8_000,
                channels: 1,
                interleaved: false
            ) else {
                throw VoiceAudioError.invalidPlaybackFormat
            }
            startupPhase = "connect_playback"
            try CallAudioGraph.connectPlayback(player, engine: engine, format: playbackFormat)

            if !receiveOnly {
            let input = engine.inputNode
            // Read the final input format only after enabling VoiceProcessingIO.
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate >= 8_000 else {
                throw VoiceAudioError.microphoneUnavailable
            }
            startupPhase = "install_capture_tap"
            try CallAudioGraph.installCapture(input, format: nil) {
                buffer, _ in
                let pcm = encoder.encode(buffer)
                if !pcm.isEmpty {
                    levelMeter.record(pcm, direction: .uplink, owner: owner)
                    transport.sendPCM(pcm)
                }
            }

                captureInstalled = true
            }

            startupPhase = "start_engine"
            engine.prepare()
            try engine.start()
            player.play()
            recordStartup("engine_ready")

            self.engine = engine
            self.receiveOnly = receiveOnly
            self.earlyMediaLease = earlyLease
            if case let .vowlan(_, credential) = route { earlyMediaClockOffset = credential.clockOffset }
            sessionOwner = owner
            self.player = player
            self.encoder = encoder
            self.transport = transport
            playbackQueue.reset()
            active = true
            if receiveOnly {
                engineConfigurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
                ) { [weak self, weak engine] _ in
                    Task { @MainActor [weak self, weak engine] in
                        guard let self, let engine, self.engine === engine,
                              self.sessionOwner == owner else { return }
                        self.recoverEarlyPlaybackIfNeeded()
                    }
                }
            }
            transportReady = false
            routeDescription = route.isOverlayHost ? "正在连接 VPN 直连语音…"
                : (route.requiresWiFi ? "正在连接 VoWLAN 语音…" : "正在连接模块网络语音…")
            diagnosticDescription = "\(DeviceContext.displayName) PCM 尚未握手"
            moduleDiagnosticDescription = ""
            errorMessage = nil
            retryRequestedSpeakerRoute()
            startAudioHealthMonitor()
            transport.start()
            return true
        } catch {
            let phase = startupPhase
            Task { await AgentVerboseTraceRecorder.shared.recordFailure(category: "vowlan", phase: phase, error: error) }
            recordStartup("failed")
            deactivate()
            errorMessage = "无法启用通话音频：\(error.localizedDescription)"
            return false
        }
    }

    /// CallKit 执行动作前先声明语音类别，真正激活由系统随后回调 didActivate。
    func prepareForCallKit() throws {
        resetSpeakerPreferenceForNewCall()
        try configureCallAudioSession()
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        sessionActivationManagedByCallKit = true
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        encoder?.setMuted(muted)
        levelMeter.setUplinkMuted(muted)
    }

    /// 根据模块通话状态播放来电铃声或呼出等待音，接通后立即让位给网络 PCM。
    func updateCallTone(for call: CallRecord?, allowIncomingRingtone: Bool = true) {
        guard !active else {
            // Keep the existing waiting tone until the early stream actually
            // delivers PCM. A lease/ACK alone is not an audible announcement.
            if receiveOnly, !hasReceivedEarlyMedia { return }
            stopCallTone()
            return
        }
        guard let call else {
            // 设置页试听不属于通话状态，空闲轮询不能提前将它停止。
            if case .preview? = currentCallTone { return }
            if case .outgoingEnded? = currentCallTone { return }
            stopCallTone()
            return
        }

        if allowIncomingRingtone, call.direction == "incoming", !call.isTerminal,
           ["incoming", "waiting"].contains(call.state) {
            // If VoWLAN loses the terminal event, repeated polls for this call
            // must not keep the app's fallback ringtone alive indefinitely.
            let clock = ContinuousClock()
            if incomingRingtoneWindow?.callID != call.id {
                incomingRingtoneWindow = (call.id, clock.now.advanced(by: .seconds(60)))
            }
            guard let window = incomingRingtoneWindow, clock.now < window.deadline else {
                stopIncomingRingtone()
                return
            }
            let ringtone = UserDefaults.standard.string(forKey: "airsim.ringtone") ?? "Hero"
            playCallTone(.incoming(ringtone), looping: true)
            if currentCallTone != nil, incomingRingtoneTask == nil {
                incomingRingtoneTask = Task { @MainActor [weak self] in
                    do { try await clock.sleep(until: window.deadline) } catch { return }
                    self?.stopIncomingRingtone()
                }
            }
        } else if call.direction != "incoming", ["dialing", "alerting"].contains(call.state) {
            playCallTone(.outgoingWaiting, looping: true)
        } else {
            stopCallTone()
        }
    }

    func stopIncomingRingtone() {
        guard case .incoming? = currentCallTone else { return }
        stopCallTone()
    }

    /// The caller already verified the nonce-bound response proof. Renewal may
    /// only update this exact receive-only audio owner and its pinned session.
    func renewEarlyMedia(_ grant: EarlyMediaGrant, owner: UUID) -> Bool {
        guard active, receiveOnly, sessionOwner == owner, let earlyMediaLease else { return false }
        return earlyMediaLease.renew(grant, now: Int64(Date().timeIntervalSince1970 + earlyMediaClockOffset))
    }

    /// 设置页只试听一遍，不能像真实来电一样无限循环。
    func previewRingtone(named ringtone: String) {
        guard !active else { return }
        playCallTone(.preview(ringtone), looping: false)
    }

    func stopRingtonePreview() {
        guard case .preview? = currentCallTone else { return }
        stopCallTone()
    }

    func playOutgoingEndedTone() {
        guard !active else { return }
        playCallTone(.outgoingEnded, looping: false)
        endedToneTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, case .outgoingEnded? = self.currentCallTone else { return }
            self.stopCallTone() // release playback/ducking after the finite cue
        }
    }

    func stopCallTone(deactivateSession: Bool = true) {
        endedToneTask?.cancel(); endedToneTask = nil
        incomingRingtoneTask?.cancel(); incomingRingtoneTask = nil
        let hadTone = currentCallTone != nil
        currentCallTone = nil
        // 空闲轮询会反复调用本方法；没有铃声时绝不能停用后台待机正在使用的会话。
        // CallKit 的 didActivate 回调之后，音频会话也只能由系统释放。
        toneOutput.stop(deactivateSession: hadTone && deactivateSession && !active && !sessionActivationManagedByCallKit)
    }

    /// 切换当前通话的输出路由；关闭扬声器时交还给系统选择听筒或已连接的蓝牙设备。
    func setSpeakerEnabled(_ enabled: Bool) {
        cancelCallRouteSelection(clearIntent: true)
        restoreBluetoothAvailability()
        systemRouteSelectionActive = false
        requestedSpeakerOverride = enabled
        speakerRoutePending = !SpeakerRoutePolicy.routeMatches(
            requestedSpeaker: enabled,
            currentRouteIsSpeaker: speakerEnabled
        )
        retryRequestedSpeakerRoute()
    }

    func toggleSpeakerRoute() {
        let pendingTarget = speakerRoutePending ? requestedSpeakerOverride : nil
        setSpeakerEnabled(SpeakerRoutePolicy.toggledTarget(
            currentRouteIsSpeaker: speakerEnabled,
            pendingTarget: pendingTarget
        ))
    }

    private func cancelCallRouteSelection(clearIntent: Bool) {
        callRouteSelectionGeneration &+= 1
        callRouteSelectionTask?.cancel(); callRouteSelectionTask = nil
        changingCallRoute = false
        if clearIntent { requestedCallRouteID = nil }
    }

    func selectCallRoute(_ id: String) {
        cancelCallRouteSelection(clearIntent: false)
        speakerRouteRetryTask?.cancel(); speakerRouteRetryTask = nil
        speakerRoutePending = false
        systemRouteSelectionActive = true
        requestedCallRouteID = id
        changingCallRoute = true
        errorMessage = nil
        let generation = callRouteSelectionGeneration
        Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "APP", category: "audio-route",
            phase: "requested", title: "请求切换通话输出", fields: ["target": id == "speaker" || id == "receiver" ? id : "headset"]) }
        callRouteSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == callRouteSelectionGeneration {
                    callRouteSelectionTask = nil; changingCallRoute = false
                }
            }
            var lastError: Error?
            for delay in [0.0, 0.15, 0.35, 0.7, 1.2] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, generation == callRouteSelectionGeneration else { return }
                do {
                    if let applyRouteForTesting { try applyRouteForTesting(id) }
                    else { try await applyCallRoute(id) }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, generation == callRouteSelectionGeneration else { return }
                    refreshRouteDescription()
                    let actual: String?
                    if let readRouteForTesting { actual = readRouteForTesting() }
                    else { actual = currentCallRouteID() }
                    if actual == id {
                        requestedSpeakerOverride = id == "speaker"
                        Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "APP", category: "audio-route",
                            phase: "verified", title: "通话输出切换已确认",
                            fields: ["target": id == "speaker" || id == "receiver" ? id : "headset"]) }
                        return
                    }
                } catch { lastError = error }
            }
            guard generation == callRouteSelectionGeneration else { return }
            requestedCallRouteID = nil
            restoreBluetoothAvailability()
            if !["receiver", "speaker"].contains(id),
               AVAudioSession.sharedInstance().availableInputs?.contains(where: { $0.uid == id }) != true {
                knownExternalCallPorts.removeAll { $0.uid == id }
                refreshRouteDescription()
            }
            errorMessage = "音频输出未切换，请重新选择。" + (lastError.map { "（\($0.localizedDescription)）" } ?? "")
            Task { await AgentVerboseTraceRecorder.shared.recordFailure(category: "audio-route", phase: "unconfirmed",
                error: lastError ?? NSError(domain: "AirSIM.AudioRoute", code: 2)) }
        }
    }

    func waitForCallRouteSelection() async {
        await callRouteSelectionTask?.value
    }

    private func applyCallRoute(_ id: String) async throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else {
            throw NSError(domain: "AirSIM.AudioRoute", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "通话音频会话尚未就绪"])
        }
        if id == "receiver" {
            bluetoothSuppressedForReceiver = true
            if session.categoryOptions.contains(.allowBluetoothHFP) || session.categoryOptions.contains(.allowBluetoothA2DP) {
                try session.setCategory(.playAndRecord, mode: session.mode,
                    options: session.categoryOptions.subtracting([.allowBluetoothHFP, .allowBluetoothA2DP]))
            }
        } else {
            restoreBluetoothAvailability()
            if !session.categoryOptions.contains(.allowBluetoothHFP) {
                try session.setCategory(.playAndRecord, mode: session.mode,
                    options: session.categoryOptions.union(.allowBluetoothHFP))
            }
        }
        if id == "speaker" {
            try session.setPreferredInput(nil)
            try session.overrideOutputAudioPort(.speaker)
        } else {
            guard let port = session.availableInputs?.first(where: {
                id == "receiver" ? $0.portType == .builtInMic : $0.uid == id
            }) else { throw NSError(domain: "AirSIM.AudioRoute", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "设备已断开，请重新选择音频输出"]) }
            // Releasing the override AFTER choosing Bluetooth can restore the previous
            // input again. Clear it first, then establish the requested input/output pair.
            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(port)
        }
    }

    private func restoreBluetoothAvailability() {
        guard bluetoothSuppressedForReceiver else { return }
        bluetoothSuppressedForReceiver = false
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else { return }
        let wasSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        try? session.setCategory(.playAndRecord, mode: session.mode,
            options: session.categoryOptions.union(.allowBluetoothHFP))
        if wasSpeaker { try? session.overrideOutputAudioPort(.speaker) }
    }

    private func currentCallRouteID() -> String? {
        let session = AVAudioSession.sharedInstance()
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) { return "speaker" }
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) { return "receiver" }
        let external = session.currentRoute.outputs.contains { ![.builtInReceiver, .builtInSpeaker].contains($0.portType) }
        return external ? session.currentRoute.inputs.first(where: { $0.portType != .builtInMic })?.uid : nil
    }

    func prepareForSystemRouteSelection() {
        cancelCallRouteSelection(clearIntent: true)
        restoreBluetoothAvailability()
        systemRouteSelectionActive = true
        speakerRouteRetryTask?.cancel(); speakerRouteRetryTask = nil
        speakerRoutePending = false
        // Observing a route change must never itself clear the user's preferred input.
    }

    func resetSpeakerPreferenceForNewCall() {
        cancelCallRouteSelection(clearIntent: true)
        restoreBluetoothAvailability()
        knownExternalCallPorts = []
        systemRouteSelectionActive = false
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = nil
        requestedSpeakerOverride = false
        speakerRoutePending = false
        refreshRouteDescription()
    }

    /// CallKit 的 didActivate 与 AVAudioEngine 真正启动之间存在短暂窗口。
    /// 在窗口内切换会得到 OSStatus -50，因此把用户选择保留并做有界重试。
    func retryRequestedSpeakerRoute() {
        if let id = requestedCallRouteID { selectCallRoute(id); return }
        guard !systemRouteSelectionActive else { return }
        let requested = requestedSpeakerOverride
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if requestedSpeakerOverride == requested {
                    speakerRoutePending = false
                    speakerRouteRetryTask = nil
                }
            }
            for delay in SpeakerRoutePolicy.retryDelays {
                guard !Task.isCancelled, requestedSpeakerOverride == requested else { return }
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, requestedSpeakerOverride == requested else { return }
                do {
                    try overrideSpeakerRoute(requested)
                    // API 返回只表示系统接受了请求；currentRoute 的切换是异步的。
                    // 等待一个很短的确认窗口，再以真实输出端口决定按钮高亮。
                    try? await Task.sleep(for: .seconds(SpeakerRoutePolicy.routeVerificationDelay))
                    guard !Task.isCancelled, requestedSpeakerOverride == requested else { return }
                    refreshRouteDescription()
                    if SpeakerRoutePolicy.routeMatches(
                        requestedSpeaker: requested,
                        currentRouteIsSpeaker: speakerEnabled
                    ) {
                        return
                    }
                } catch {
                    // 音频会话还没由 CallKit 激活时保留选择，等待下一次短重试。
                }
            }
            refreshRouteDescription()
        }
    }

    /// 合并模块侧 D5/D6 统计，避免把 TCP 连通误判为实际存在语音。
    func updateModuleDiagnostics(_ config: MaVoAudioHostConfig) {
        var details: [String] = []
        if let routeError = config.routeError, !routeError.isEmpty {
            details.append("模块语音桥错误：\(routeError)")
        } else if config.routeRunning != true {
            details.append("模块 PCM 未启动")
        } else if config.routeSessionReady == false || config.routeReady == false {
            details.append("模块语音路由尚未就绪")
        }
        if let statistics = config.statistics, config.statisticsAvailable == true {
            details.append("D5 ↑\(statistics.uplinkBytes)B 峰值\(statistics.uplinkPeak) · D6 ↓\(statistics.downlinkBytes)B 峰值\(statistics.downlinkPeak)")
        } else if config.routeRunning == true {
            details.append("模块 PCM 已启动，等待首个统计周期")
        }
        // 只显示最后一条日志，保留真正的启动失败原因，同时避免通话页被日志刷屏。
        if let lastLog = config.logTail?.last, !lastLog.isEmpty {
            details.append("日志：\(lastLog)")
        }
        moduleDiagnosticDescription = details.joined(separator: "；")
    }

    func deactivate(preservingSharedSession: Bool = false, preservingCallPreferences: Bool = false) {
        audioHealthTask?.cancel(); audioHealthTask = nil
        levelMeter.endSession()
        lastDownlinkUptime = nil; audioHealthWarning = nil
        audioHealthText = "当前没有通话音频会话"
        bridgeHealth = PCMBridgeHealth(); lastHealthPhase = nil
        earlyPlaybackRecoveryTask?.cancel()
        earlyPlaybackRecoveryTask = nil
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        playbackGeneration &+= 1
        if active { recordStartup("stopped") }
        sessionOwner = nil
        let callKitManagedSession = sessionActivationManagedByCallKit
        sessionActivationManagedByCallKit = false
        cancelCallRouteSelection(clearIntent: !preservingCallPreferences)
        if !preservingCallPreferences {
            restoreBluetoothAvailability()
            knownExternalCallPorts = []
            muted = false
            requestedSpeakerOverride = false
            systemRouteSelectionActive = false
        }
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = nil
        speakerRoutePending = false
        stopCallTone(deactivateSession: !preservingSharedSession)
        transport?.stop()
        transport = nil
        encoder = nil
        if let engine {
            if captureInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        captureInstalled = false
        receiveOnly = false
        earlyMediaLease = nil
        earlyMediaClockOffset = 0
        hasReceivedEarlyMedia = false
        player?.stop()
        player = nil
        engine = nil
        playbackQueue.reset()
        if !preservingSharedSession {
            do {
                let session = AVAudioSession.sharedInstance()
                // 清除本次通话的外放覆盖，避免影响下一次通话或其他 App。
                if !preservingCallPreferences { try session.overrideOutputAudioPort(.none) }
                if !callKitManagedSession, !CallKitController.shared.audioSessionIsActive {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        active = false
        transportReady = false
        routeDescription = ""
        diagnosticDescription = ""
        moduleDiagnosticDescription = ""
        refreshRouteDescription()
    }

    private func playCallTone(_ tone: CallTone, looping: Bool) {
        guard currentCallTone != tone || !toneOutput.isPlaying else { return }
        stopCallTone()

        do {
            let routesLikeCall = tone == .outgoingWaiting
            if routesLikeCall, !sessionActivationManagedByCallKit {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: preferredCallCategoryOptions)
                try session.setActive(true)
                // Play the waiting tone even if the route is not ready yet.
                if !systemRouteSelectionActive { try? overrideSpeakerRoute(requestedSpeakerOverride) }
            }
            try toneOutput.play(SynthesizedCallTone.wavData(for: tone), looping: looping, volume: tone.volume,
                                configureSession: !sessionActivationManagedByCallKit && !routesLikeCall)
            currentCallTone = tone
            if routesLikeCall { retryRequestedSpeakerRoute() }
        } catch {
            toneOutput.stop(deactivateSession: !sessionActivationManagedByCallKit)
            currentCallTone = nil
            errorMessage = "无法播放通话提示音：\(error.localizedDescription)"
        }
    }

    private func configureCallAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat 使用 VoiceProcessingIO，为听筒和扬声器通话提供系统回声消除。
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: preferredCallCategoryOptions
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
    }

    private func startAudioHealthMonitor() {
        audioHealthTask?.cancel()
        let owner = sessionOwner
        if playbackRecoveryOwner != owner {
            playbackRecoveryBudget = PlaybackRecoveryBudget(); playbackRecoveryOwner = owner
        }
        audioHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.active, self.sessionOwner == owner else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard !self.sessionActivationManagedByCallKit || CallKitController.shared.audioSessionIsActive else {
                    self.audioHealthText = "等待系统重新激活通话音频"; self.audioHealthWarning = nil
                    continue
                }
                let assessment = self.bridgeHealth.assess(now: now,
                    engineRunning: self.engine?.isRunning == true,
                    playerPlaying: self.player?.isPlaying == true, receiveOnly: self.receiveOnly)
                self.audioHealthText = assessment.text; self.audioHealthWarning = assessment.warning
                if self.lastHealthPhase != assessment.phase {
                    self.lastHealthPhase = assessment.phase
                    let fields = ["state": assessment.phase.rawValue,
                        "reconnects": String(self.bridgeHealth.reconnects),
                        "playback_recovery_attempts": String(self.bridgeHealth.recoveryAttempts),
                        "last_failure_phase": self.bridgeHealth.lastFailurePhase ?? "none",
                        "recovery_ms": String(Int((self.bridgeHealth.lastRecoveryDuration ?? 0) * 1000))]
                    let recovered = assessment.phase == .flowing && (self.bridgeHealth.recoveryAttempts > 0 || self.bridgeHealth.reconnects > 0)
                    Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "APP", category: "audio",
                        phase: recovered ? "bridge_recovery_verified" : "bridge_health", title: "音频桥状态", fields: fields,
                        isFailure: assessment.phase == .playbackFailed || assessment.phase == .failed) }
                }
                if assessment.repairPlayback {
                    if self.playbackRecoveryBudget.claim(now: now) {
                        self.recordStartup("local_playback_recovery_attempt")
                        self.recoverLocalPlayback()
                    } else if self.playbackRecoveryBudget.attempts >= 3 {
                        self.audioHealthWarning = "自动播放修复已达上限，尚未恢复，请检查音频输出或重新呼叫"
                        self.audioHealthText = self.audioHealthWarning!
                    }
                }
            }
        }
    }
    func recoverLocalPlayback() {
        guard active, let engine, let player else { return }
        guard !sessionActivationManagedByCallKit || CallKitController.shared.audioSessionIsActive else { return }
        bridgeHealth.repairing(now: ProcessInfo.processInfo.systemUptime)
        do {
            // A running player can still have a stalled schedule. Reset only its queue.
            if engine.isRunning && player.isPlaying {
                playbackGeneration &+= 1; player.stop(); playbackQueue.reset()
            }
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying { player.play() }
            audioHealthText = "已执行播放修复，正在验证新数据与播放回调"
            audioHealthWarning = nil
        } catch {
            Task { await AgentVerboseTraceRecorder.shared.recordFailure(category: "audio", phase: "playback_recovery", error: error) }
            audioHealthWarning = "本机播放恢复失败：\(error.localizedDescription)"
            audioHealthText = audioHealthWarning ?? "恢复失败"
        }
    }

    private func handleTransportEvent(_ event: NetworkPCMTransport.Event) {
        switch event {
        case .networkReady:
            bridgeHealth.networkReady()
        case let .reconnecting(attempt, delay):
            transportReady = false; bridgeHealth.reconnect(now: ProcessInfo.processInfo.systemUptime)
            audioHealthText = "音频重连中（第\(attempt)次），等待重新握手与数据验证"
            audioHealthWarning = nil
            Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "APP", category: "audio",
                phase: "transport_recovery", title: "音频连接恢复", fields: ["attempt": String(attempt), "delay_ms": String(Int(delay * 1000))]) }
        case .connected:
            bridgeHealth.handshake(now: ProcessInfo.processInfo.systemUptime)
            startAudioHealthMonitor()
            recordStartup("pcm_ready")
            transportReady = true
            diagnosticDescription = "\(DeviceContext.displayName) PCM 已握手，等待语音数据"
            refreshRouteDescription()
            errorMessage = nil
        case let .statistics(statistics):
            let now = ProcessInfo.processInfo.systemUptime
            if statistics.uplinkBytes > observedUplinkBytes { bridgeHealth.uplink(now: now) }
            if statistics.downlinkBytes > observedDownlinkBytes { bridgeHealth.downlink(now: now) }
            observedUplinkBytes = statistics.uplinkBytes; observedDownlinkBytes = statistics.downlinkBytes
            let fields = ["engine_running": String(engine?.isRunning == true),
                "player_playing": String(player?.isPlaying == true),
                "uplink_bytes": String(statistics.uplinkBytes), "uplink_peak": String(statistics.uplinkPeak),
                "downlink_bytes": String(statistics.downlinkBytes), "downlink_peak": String(statistics.downlinkPeak),
                "capture_buffers": String(encoder?.capturedBuffers ?? 0),
                "input_format": receiveOnly ? "recvonly (no input node)" : (engine?.inputNode.outputFormat(forBus: 0).description ?? "none"),
                "output_format": engine?.outputNode.inputFormat(forBus: 0).description ?? "none",
                "system_output_volume": String(AVAudioSession.sharedInstance().outputVolume),
                "player_volume": String(player?.volume ?? 0),
                "player_render_sample": String(player?.lastRenderTime?.sampleTime ?? -1),
                "input_route": AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue).joined(separator: ","),
                "output_route": AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")]
            Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "APP", category: "vowlan",
                phase: "media_statistics", title: "VoWLAN 实际音频状态", fields: fields) }
            let handshakeState = transportReady ? "PCM 已握手" : "PCM 尚未握手"
            let playbackDrops = playbackQueue.droppedFrames > 0
                ? " · 播放丢弃\(playbackQueue.droppedFrames)帧"
                : ""
            diagnosticDescription = "\(DeviceContext.displayName) \(handshakeState) ↑\(statistics.uplinkBytes)B 峰值\(statistics.uplinkPeak) · ↓\(statistics.downlinkBytes)B 峰值\(statistics.downlinkPeak)\(playbackDrops)"
            refreshRouteDescription()
        case let .status(message):
            // 连接状态单独显示，避免把“尚未握手”误读成模块已经拒绝握手。
            diagnosticDescription = "\(DeviceContext.displayName) PCM：\(message)"
        case let .failed(message):
            bridgeHealth.failed()
            Task { await AgentVerboseTraceRecorder.shared.recordFailure(category: "audio", phase: "transport_recovery_exhausted", error: NSError(domain: "AirSIM.PCM", code: 1, userInfo: [NSLocalizedDescriptionKey: message])) }
            recordStartup("failed")
            transportReady = false
            routeDescription = "网络语音未连接"
            diagnosticDescription = "\(DeviceContext.displayName) PCM 连接失败：\(message)"
            errorMessage = message
        case .closed:
            transportReady = false
        }
    }

    private func refreshRouteDescription() {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
        let output = session.currentRoute.outputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
        let inputs = session.availableInputs?.map(\.portName).joined(separator: ", ") ?? "无"
        let routedToSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        let freshExternal = (session.availableInputs ?? []).filter { $0.portType != .builtInMic }
        if session.categoryOptions.contains(.allowBluetoothHFP) {
            if !freshExternal.isEmpty || !changingCallRoute { knownExternalCallPorts = freshExternal }
        } else {
            knownExternalCallPorts = freshExternal + knownExternalCallPorts.filter { port in
                port.portType == .bluetoothHFP && !freshExternal.contains { $0.uid == port.uid }
            }
        }
        let externalInputs = !knownExternalCallPorts.isEmpty
        let externalOutputs = session.currentRoute.outputs.contains { ![.builtInReceiver, .builtInSpeaker].contains($0.portType) }
        hasExternalCallRoutes = externalInputs || externalOutputs
        if let port = session.currentRoute.outputs.first {
            switch port.portType {
            case .builtInSpeaker: callOutputName = "扬声器"
            case .builtInReceiver: callOutputName = "iPhone"
            default: callOutputName = port.portName
            }
        } else { callOutputName = "iPhone" }
        if let port = session.currentRoute.outputs.first {
            if port.portType == .builtInReceiver { callOutputIcon = "iphone" }
            else if port.portType == .builtInSpeaker { callOutputIcon = "speaker.wave.2.fill" }
            else { callOutputIcon = CallHeadphoneIcon.symbol(for: port.portName) }
        } else { callOutputIcon = "iphone" }
        let external = knownExternalCallPorts
        let outputIDs = Set(session.currentRoute.outputs.map(\.uid))
        let inputIDs = Set(session.currentRoute.inputs.map(\.uid))
        let selectedExternalID = external.first(where: { outputIDs.contains($0.uid) })?.uid
            ?? (externalOutputs ? external.first(where: { inputIDs.contains($0.uid) })?.uid : nil)
            ?? (externalOutputs ? external.first(where: { port in
                external.filter { $0.portName == port.portName }.count == 1 &&
                session.currentRoute.outputs.contains { $0.portName == port.portName }
            })?.uid : nil)
        callRouteChoices = [
            .init(id: "speaker", title: "扬声器", icon: "speaker.wave.2.fill", selected: routedToSpeaker),
            .init(id: "receiver", title: "iPhone", icon: "iphone", selected: !externalOutputs && !routedToSpeaker)
        ] + external.map { port in
            .init(id: port.uid, title: port.portName,
                  icon: CallHeadphoneIcon.symbol(for: port.portName),
                  selected: externalOutputs && port.uid == selectedExternalID && !routedToSpeaker)
        }
        if speakerEnabled != routedToSpeaker {
            speakerEnabled = routedToSpeaker
        }
        speakerRoutePending = speakerRouteRetryTask != nil && !SpeakerRoutePolicy.routeMatches(
            requestedSpeaker: requestedSpeakerOverride,
            currentRouteIsSpeaker: routedToSpeaker
        )
        routeDescription = receiveOnly ? "仅接收 → \(output.isEmpty ? "无输出" : output)"
            : "\(input.isEmpty ? "无输入" : input) ↔ 网络 PCM ↔ \(output.isEmpty ? "无输出" : output)（可用输入：\(inputs)）"
        IPhoneCloudCallSession.shared.recordAudioRoute(output.isEmpty ? "unknown" : output)
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshRouteDescription()
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)
            .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0.uintValue) }
        // Own route requests can switch Bluetooth profiles and emit device-change
        // events. Do not turn those notifications into a new selection or clear input.
        if changingCallRoute || (!active && requestedCallRouteID != nil) { return }
        if bluetoothSuppressedForReceiver, requestedCallRouteID == "receiver",
           currentCallRouteID() == "receiver" { return }
        if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
            prepareForSystemRouteSelection()
        } else if reason == .override || reason == .routeConfigurationChange,
                  requestedCallRouteID != nil, currentCallRouteID() != requestedCallRouteID {
            // A later choice in CallKit / Control Center takes precedence.
            prepareForSystemRouteSelection()
        }
        guard speakerRouteRetryTask == nil else { return }
        if reason == .override && speakerEnabled != requestedSpeakerOverride {
            systemRouteSelectionActive = true
        }
        if systemRouteSelectionActive {
            requestedSpeakerOverride = speakerEnabled
            speakerRoutePending = false
            return
        }
        requestedSpeakerOverride = SpeakerRoutePolicy.requestedSpeakerAfterSystemRouteChange(
            requestedSpeaker: requestedSpeakerOverride,
            observedRouteIsSpeaker: speakerEnabled
        )
        speakerRoutePending = false
    }

    private func schedulePlayback(_ pcm: Data) {
        if let owner = sessionOwner, active {
            levelMeter.record(pcm, direction: .downlink, owner: owner)
        }
        if !pcm.isEmpty {
            lastDownlinkUptime = ProcessInfo.processInfo.systemUptime
            bridgeHealth.downlink(now: ProcessInfo.processInfo.systemUptime)
        }
        recoverEarlyPlaybackIfNeeded()
        if receiveOnly, engine?.isRunning == false { return }
        guard active, let player, !pcm.isEmpty else { return }
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, playbackQueue.reserve(frames: frames) else { return }
        guard let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 8_000,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ),
              let output = buffer.floatChannelData?[0] else {
            playbackQueue.complete(frames: frames)
            return
        }

        buffer.frameLength = AVAudioFrameCount(frames)
        if !recordedFirstDownlink {
            recordedFirstDownlink = true
            if receiveOnly {
                stopCallTone(deactivateSession: false)
                hasReceivedEarlyMedia = true
            }
            recordStartup("first_downlink")
        }
        pcm.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frame in 0 ..< frames {
                let bits = UInt16(bytes[frame * 2]) |
                    UInt16(bytes[frame * 2 + 1]) << 8
                output[frame] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.playbackQueue.complete(frames: frames)
                self.bridgeHealth.rendered(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Hardware route changes stop a receive-only engine without closing PCM.
    /// Reconnect to the new output format while keeping its call-bound transport.
    private func recoverEarlyPlaybackIfNeeded() {
        guard active, receiveOnly, let owner = sessionOwner, let engine, let player,
              !engine.isRunning, earlyPlaybackRecoveryTask == nil else { return }
        earlyPlaybackRecoveryTask = Task { @MainActor [weak self, weak engine, weak player] in
            guard let self, let engine, let player else { return }
            defer {
                if self.sessionOwner == owner { self.earlyPlaybackRecoveryTask = nil }
            }
            for delay in [0.0, 0.1, 0.3, 0.8] {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard !Task.isCancelled, self.active, self.receiveOnly,
                      self.sessionOwner == owner, self.engine === engine else { return }
                do {
                    player.stop()
                    engine.stop()
                    self.playbackGeneration &+= 1
                    self.playbackQueue.reset()
                    engine.disconnectNodeOutput(player)
                    engine.disconnectNodeOutput(engine.mainMixerNode)
                    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                        sampleRate: 8_000, channels: 1, interleaved: false) else {
                        throw VoiceAudioError.invalidPlaybackFormat
                    }
                    try CallAudioGraph.connectPlayback(player, engine: engine, format: format)
                    engine.prepare()
                    try engine.start()
                    player.play()
                    self.recordStartup("early_playback_route_recovered")
                    self.refreshRouteDescription()
                    return
                } catch {
                    if delay == 0.8 {
                        self.errorMessage = "接通前音频输出恢复失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

struct PlaybackQueueTracker {
    let maximumFrames: Int
    private(set) var scheduledFrames = 0
    private(set) var droppedFrames = 0

    mutating func reserve(frames: Int) -> Bool {
        guard frames > 0 else { return false }
        guard scheduledFrames + frames <= maximumFrames else {
            droppedFrames += frames
            return false
        }
        scheduledFrames += frames
        return true
    }

    mutating func complete(frames: Int) {
        scheduledFrames = max(0, scheduledFrames - max(0, frames))
    }

    mutating func reset() {
        scheduledFrames = 0
        droppedFrames = 0
    }
}

struct PCMFrameAccumulator {
    let frameBytes: Int
    private var bytes = Data()

    init(frameBytes: Int) {
        self.frameBytes = frameBytes
    }

    var pendingByteCount: Int { bytes.count }

    mutating func append(_ data: Data) -> Data? {
        guard frameBytes > 0, !data.isEmpty else { return nil }
        bytes.append(data)
        let completeByteCount = (bytes.count / frameBytes) * frameBytes
        guard completeByteCount > 0 else { return nil }
        let batch = Data(bytes.prefix(completeByteCount))
        bytes.removeFirst(completeByteCount)
        return batch
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: false)
    }
}

/// 通话等待阶段使用的声音类型；关联值同时用于检测用户是否切换了来电铃声。
private enum CallTone: Equatable {
    case incoming(String)
    case outgoingWaiting
    case outgoingEnded
    case preview(String)

    var ringtoneName: String {
        switch self {
        case let .incoming(name), let .preview(name): return name
        case .outgoingWaiting: return "呼出等待"
        case .outgoingEnded: return "呼叫结束"
        }
    }

    var volume: Float {
        switch self {
        case .outgoingWaiting, .outgoingEnded: return 0.55
        case .incoming, .preview: return 0.85
        }
    }
}

/// 运行时合成短促、无版权依赖的 PCM 铃声，并封装为 AVAudioPlayer 可读取的 WAV。
private enum SynthesizedCallTone {
    private struct Segment {
        let frequencies: [Double]
        let duration: Double
        let amplitude: Double

        static func silence(_ duration: Double) -> Segment {
            Segment(frequencies: [], duration: duration, amplitude: 0)
        }
    }

    private static let sampleRate = 16_000

    static func wavData(for tone: CallTone) -> Data {
        let segments = pattern(for: tone)
        var samples = [Int16]()
        samples.reserveCapacity(Int(segments.reduce(0) { $0 + $1.duration } * Double(sampleRate)))

        for segment in segments {
            let sampleCount = max(1, Int(segment.duration * Double(sampleRate)))
            let envelopeSamples = min(sampleCount / 2, sampleRate / 100)
            for index in 0..<sampleCount {
                guard !segment.frequencies.isEmpty else {
                    samples.append(0)
                    continue
                }
                let time = Double(index) / Double(sampleRate)
                let wave = segment.frequencies.reduce(0.0) {
                    $0 + sin(2 * .pi * $1 * time)
                } / Double(segment.frequencies.count)
                // 每段两端加入 10 ms 淡入淡出，避免波形截断产生爆音。
                let edge = min(index, sampleCount - index - 1)
                let envelope = envelopeSamples > 0
                    ? min(1, Double(edge) / Double(envelopeSamples))
                    : 1
                let value = max(-1, min(1, wave * segment.amplitude * envelope))
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        return encodeWAV(samples)
    }

    private static func pattern(for tone: CallTone) -> [Segment] {
        if case .outgoingEnded = tone {
            // A neutral local two-note cue, never a simulated carrier announcement.
            return [Segment(frequencies: [660], duration: 0.12, amplitude: 0.3),
                    .silence(0.08), Segment(frequencies: [440], duration: 0.2, amplitude: 0.3)]
        }
        if case .outgoingWaiting = tone {
            // 425 Hz、1 秒响 4 秒停，接近国内常见呼叫等待节奏。
            return [
                Segment(frequencies: [425], duration: 1.0, amplitude: 0.34),
                .silence(4.0),
            ]
        }

        switch tone.ringtoneName {
        case "Signal":
            return [
                Segment(frequencies: [880], duration: 0.16, amplitude: 0.38), .silence(0.12),
                Segment(frequencies: [880], duration: 0.16, amplitude: 0.38), .silence(0.12),
                Segment(frequencies: [1_176], duration: 0.3, amplitude: 0.34), .silence(1.5),
            ]
        case "Beacon":
            return [
                Segment(frequencies: [523, 784], duration: 0.32, amplitude: 0.38), .silence(0.16),
                Segment(frequencies: [659, 988], duration: 0.32, amplitude: 0.38), .silence(0.16),
                Segment(frequencies: [784, 1_046], duration: 0.48, amplitude: 0.34), .silence(1.5),
            ]
        case "系统默认":
            return [
                Segment(frequencies: [440, 480], duration: 0.8, amplitude: 0.38), .silence(0.35),
                Segment(frequencies: [440, 480], duration: 0.8, amplitude: 0.38), .silence(2.0),
            ]
        default:
            return [
                Segment(frequencies: [523, 659], duration: 0.3, amplitude: 0.38), .silence(0.1),
                Segment(frequencies: [659, 784], duration: 0.3, amplitude: 0.38), .silence(0.1),
                Segment(frequencies: [784, 1_046], duration: 0.45, amplitude: 0.34), .silence(0.18),
                Segment(frequencies: [659, 784], duration: 0.3, amplitude: 0.34), .silence(1.6),
            ]
        }
    }

    private static func encodeWAV(_ samples: [Int16]) -> Data {
        let pcmByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data()
        data.reserveCapacity(44 + Int(pcmByteCount))
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + pcmByteCount, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(pcmByteCount, to: &data)
        for sample in samples { append(UInt16(bitPattern: sample), to: &data) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

/// 维护低延迟 TCP 字节流；每次连接尝试都生成新的认证握手。
final class NetworkPCMTransport: @unchecked Sendable {
    enum Event: Sendable {
        case connected
        case networkReady
        case reconnecting(attempt: Int, delay: TimeInterval)
        case statistics(NetworkPCMStatistics)
        case status(String)
        case failed(String)
        case closed
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let handshakeSequence: PCMHandshakeSequence
    private let requiresWiFi: Bool
    private let usesSystemRouting: Bool
    private let usesTLS: Bool
    private let receiveOnly: Bool
    private let isOverlayHost: Bool
    private let queue = DispatchQueue(label: "com.jieden.airsim.network-pcm")
    private let onPCM: @Sendable (Data) -> Void
    private let onEvent: @Sendable (Event) -> Void
    private let uptime: @Sendable () -> UInt64
    private var connection: NWConnection?
    private var generation = 0
    private var stopped = false
    private var readyForPCM = false
    private var pcmAccumulator = PCMFrameAccumulator(frameBytes: 320)
    private var deadline: UInt64 = 0
    private var uplinkBytes: UInt64 = 0
    private var uplinkPeak = 0
    private var downlinkBytes: UInt64 = 0
    private var downlinkPeak = 0
    private var nextStatisticsEmission: UInt64 = 0
    private var fallbackAttempted = false
    private var lastFailureMessage = ""
    private var reconnectBudget = PCMReconnectBudget()
    private var connectedAt: UInt64?
    private var connectionUpBaseline: UInt64 = 0
    private var connectionDownBaseline: UInt64 = 0

    private static let acknowledgement = Data("AIRSIMREADY".utf8)
    // 模块首次加载语音驱动、ACDB 校准和 D4 route session 最坏需要约 35 秒。
    private static let coldStartRetryWindowNanoseconds: UInt64 = 45_000_000_000

    init(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        handshakeSequence: PCMHandshakeSequence,
        requiresWiFi: Bool,
        usesSystemRouting: Bool,
        usesTLS: Bool,
        isOverlayHost: Bool,
        receiveOnly: Bool = false,
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        onPCM: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.host = host
        self.port = port
        self.handshakeSequence = handshakeSequence
        self.requiresWiFi = requiresWiFi
        self.usesSystemRouting = usesSystemRouting
        self.usesTLS = usesTLS
        self.isOverlayHost = isOverlayHost
        self.receiveOnly = receiveOnly
        self.uptime = uptime
        self.onPCM = onPCM
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            stopped = false
            uplinkBytes = 0
            uplinkPeak = 0
            downlinkBytes = 0
            downlinkPeak = 0
            nextStatisticsEmission = 0
            fallbackAttempted = false
            reconnectBudget.reset()
            lastFailureMessage = ""
            deadline = uptime()
                + Self.coldStartRetryWindowNanoseconds
            startAttempt()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            readyForPCM = false
            generation += 1
            connection?.cancel()
            connection = nil
            pcmAccumulator.reset()
            onEvent(.closed)
        }
    }

    func sendPCM(_ pcm: Data) {
        guard !receiveOnly, !pcm.isEmpty else { return }
        queue.async { [self] in
            guard readyForPCM, let connection else { return }
            let attempt = generation
            connection.send(content: pcm, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped, self.generation == attempt else { return }
                    if let error {
                        self.retryOrFail("麦克风上行发送失败：\(error.localizedDescription)", attempt: attempt)
                        return
                    }
                    self.uplinkBytes += UInt64(pcm.count)
                    self.uplinkPeak = max(self.uplinkPeak, Self.peak(of: pcm))
                    self.emitStatisticsIfNeeded()
                }
            })
        }
    }

    private func startAttempt() {
        guard !stopped else { return }
        generation += 1
        let attempt = generation
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let parameters = NWParameters(tls: usesTLS ? NWProtocolTLS.Options() : nil, tcp: tcp)
        if requiresWiFi {
            parameters.requiredInterfaceType = .wifi
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        readyForPCM = false
        connectedAt = nil
        connectionUpBaseline = uplinkBytes; connectionDownBaseline = downlinkBytes
        pcmAccumulator.reset()
        onEvent(.status(usesTLS ? "正在通过自建 TLS 网关连接音频" : isOverlayHost ? "正在通过 VPN 直连 PCM" : (requiresWiFi ? "正在通过 VoWLAN 连接 PCM" : "正在回退到普通 TCP 连接 PCM")))
        connection.pathUpdateHandler = { [weak self, weak connection] path in
            guard let self, connection != nil else { return }
            self.queue.async {
                guard !self.stopped, self.generation == attempt else { return }
                let interfaces = path.availableInterfaces.map { String(describing: $0.type) }.joined(separator: ",")
                let route = path.status == .satisfied ? "可用" : "不可用"
                self.onEvent(.status("PCM 网络路径\(route)：\(interfaces.isEmpty ? "未知接口" : interfaces)"))
            }
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.queue.async {
                guard !self.stopped, self.generation == attempt else { return }
                switch state {
                case .ready:
                    self.onEvent(.networkReady)
                    self.sendHandshake(connection, attempt: attempt)
                case let .waiting(error):
                    // NWConnection 在模块 helper 冷启动时会短暂报告 POSIX 61；
                    // 这是可恢复状态，不能把底层错误原样暴露成通话失败。
                    self.onEvent(.status(self.transientStatus(for: error)))
                case let .failed(error):
                    self.retryOrFail(error.localizedDescription, attempt: attempt, allowFallback: !self.usesSystemRouting)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.stopped, self.generation == attempt,
                  !self.readyForPCM else { return }
            self.retryOrFail("连接 VoWLAN PCM 超时", attempt: attempt, allowFallback: !self.usesSystemRouting)
        }
    }

    private func sendHandshake(_ connection: NWConnection, attempt: Int) {
        let handshake: Data
        do {
            handshake = try handshakeSequence.next()
        } catch {
            retryOrFail("PCM 认证握手生成失败：\(error.localizedDescription)", attempt: attempt)
            return
        }
        connection.send(content: handshake, completion: .contentProcessed {
            [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.queue.async {
                guard !self.stopped, self.generation == attempt else { return }
                if let error {
                    self.retryOrFail(error.localizedDescription, attempt: attempt, allowFallback: !self.fallbackAttempted)
                } else {
                    self.receiveAcknowledgement(connection, attempt: attempt)
                }
            }
        })
    }

    private func receiveAcknowledgement(_ connection: NWConnection, attempt: Int) {
        connection.receive(
            minimumIncompleteLength: Self.acknowledgement.count,
            maximumLength: 4_096
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            self.queue.async {
                guard !self.stopped, self.generation == attempt else { return }
                if let error {
                    self.retryOrFail(error.localizedDescription, attempt: attempt, allowFallback: !self.fallbackAttempted)
                    return
                }
                guard var data, data.count >= Self.acknowledgement.count,
                      data.prefix(Self.acknowledgement.count) == Self.acknowledgement else {
                    self.retryOrFail("模块网络 PCM 握手无效", attempt: attempt, allowFallback: !self.fallbackAttempted)
                    return
                }
                data.removeFirst(Self.acknowledgement.count)
                self.readyForPCM = true
                self.connectedAt = self.uptime()
                self.onEvent(.connected)
                self.emitStatisticsIfNeeded(force: true)
                if !data.isEmpty { self.consumeDownlink(data) }
                if isComplete {
                    self.retryOrFail("模块网络 PCM 已断开", attempt: attempt)
                } else {
                    self.receiveLoop(connection, attempt: attempt)
                }
            }
        }
    }

    private func receiveLoop(_ connection: NWConnection, attempt: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            self.queue.async {
                guard !self.stopped, self.generation == attempt else { return }
                if let data, !data.isEmpty { self.consumeDownlink(data) }
                if let error {
                    self.retryOrFail(error.localizedDescription, attempt: attempt, allowFallback: !self.fallbackAttempted)
                } else if isComplete {
                    self.retryOrFail("模块网络 PCM 已断开", attempt: attempt, allowFallback: !self.fallbackAttempted)
                } else {
                    self.receiveLoop(connection, attempt: attempt)
                }
            }
        }
    }

    private func consumeDownlink(_ data: Data) {
        downlinkBytes += UInt64(data.count)
        downlinkPeak = max(downlinkPeak, Self.peak(of: data))
        emitStatisticsIfNeeded()
        // 一次 Network.framework 回调中的完整 20 ms 帧合并后再跨到主线程，
        // 避免每个小帧各创建一个 MainActor task 造成播放调度抖动。
        if let batch = pcmAccumulator.append(data) { onPCM(batch) }
    }

    private func emitStatisticsIfNeeded(force: Bool = false) {
        let now = uptime()
        guard force || now >= nextStatisticsEmission else { return }
        nextStatisticsEmission = now + 1_000_000_000
        onEvent(.statistics(NetworkPCMStatistics(
            uplinkBytes: uplinkBytes,
            uplinkPeak: uplinkPeak,
            downlinkBytes: downlinkBytes,
            downlinkPeak: downlinkPeak
        )))
    }

    private static func peak(of pcm: Data) -> Int {
        pcm.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
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

    private func retryOrFail(_ message: String, attempt: Int, allowFallback: Bool = false) {
        guard generation == attempt else { return }
        guard !stopped else { return }
        let now = uptime()
        // A healthy established call gets a new recovery window even after hours.
        // ACK-only flapping cannot reset the retry budget.
        if let connectedAt, now >= connectedAt + 5_000_000_000,
           downlinkBytes > connectionDownBaseline,
           receiveOnly || uplinkBytes > connectionUpBaseline {
            deadline = now + Self.coldStartRetryWindowNanoseconds
            reconnectBudget.reset()
        }
        lastFailureMessage = message
        readyForPCM = false
        generation += 1 // invalidate old receive/send/timeout callbacks immediately
        let scheduledGeneration = generation
        connection?.cancel(); connection = nil; pcmAccumulator.reset()
        if allowFallback { fallbackAttempted = true }
        guard now < deadline, let delay = reconnectBudget.nextDelay() else {
            onEvent(.failed("音频桥重连未恢复，请检查安卓连接与音频桥诊断"))
            return
        }
        onEvent(.reconnecting(attempt: reconnectBudget.attempts, delay: delay))
        onEvent(.status(transientStatus(for: message)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.generation == scheduledGeneration else { return }
            guard self.uptime() < self.deadline else {
                self.onEvent(.failed("音频桥重连超时，请检查安卓连接与音频桥诊断")); return
            }
            self.startAttempt()
        }
    }

    /// 将启动阶段的底层连接错误压缩为用户可理解的可恢复状态。
    private func transientStatus(for error: NWError) -> String {
        transientStatus(for: error.localizedDescription)
    }

    private func transientStatus(for message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("connection refused") || normalized.contains("错误 61") {
            return "模块语音桥启动中，正在重试连接…"
        }
        return "模块语音桥启动中，正在重试网络 PCM…"
    }
}

struct NetworkPCMStatistics: Sendable {
    let uplinkBytes: UInt64
    let uplinkPeak: Int
    let downlinkBytes: UInt64
    let downlinkPeak: Int
}

/// 对麦克风做语音带限与线性降采样，输出模块需要的 8 kHz PCM16LE。
final class VoicePCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var conditioner = VoiceCaptureConditioner()
    private var samples: [Float] = []
    private var position = 0.0
    private var sampleRate = 0.0
    private var muted = false
    private var bufferCount: UInt64 = 0
    var capturedBuffers: UInt64 { lock.withLock { bufferCount } }

    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data {
        lock.withLock { bufferCount &+= 1 }
        guard let input = buffer.floatChannelData?[0] else { return Data() }
        let frameCount = Int(buffer.frameLength)
        let copied = Array(UnsafeBufferPointer(start: input, count: frameCount))
        let rate = buffer.format.sampleRate

        lock.lock()
        defer { lock.unlock() }
        if sampleRate != rate {
            sampleRate = rate
            samples.removeAll(keepingCapacity: true)
            position = 0
            conditioner.reset(sampleRate: rate)
        }
        samples.append(contentsOf: conditioner.process(copied, sampleRate: rate))
        let step = rate / 8_000
        var pcm = Data()
        pcm.reserveCapacity(frameCount / max(1, Int(step)) * 2 + 4)

        while position + 1 < Double(samples.count) {
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let value = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
            let scaled = muted ? Int16(0) : Int16(max(-1, min(1, value)) * 32_767)
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            position += step
        }
        let consumed = max(0, min(Int(position), samples.count - 1))
        if consumed > 0 {
            samples.removeFirst(consumed)
            position -= Double(consumed)
        }
        return pcm
    }
}

/// 两级低通避免降采样混叠，高通去除直流与桌面低频振动。
private struct VoiceCaptureConditioner {
    private var sampleRate = 0.0
    private var previousInput: Float = 0
    private var highPassOutput: Float = 0
    private var lowPassStage1: Float = 0
    private var lowPassStage2: Float = 0

    mutating func process(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        if self.sampleRate != sampleRate { reset(sampleRate: sampleRate) }
        let timeStep = 1 / sampleRate
        let highPassRC = 1 / (2 * Double.pi * 80)
        let highPassAlpha = Float(highPassRC / (highPassRC + timeStep))
        let lowPassCutoff = min(3_400, sampleRate * 0.45)
        let lowPassAlpha = Float(1 - exp(-2 * Double.pi * lowPassCutoff / sampleRate))
        return samples.map { sample in
            highPassOutput = highPassAlpha * (highPassOutput + sample - previousInput)
            previousInput = sample
            lowPassStage1 += lowPassAlpha * (highPassOutput - lowPassStage1)
            lowPassStage2 += lowPassAlpha * (lowPassStage1 - lowPassStage2)
            return max(-1, min(1, lowPassStage2))
        }
    }

    mutating func reset(sampleRate: Double = 0) {
        self.sampleRate = sampleRate
        previousInput = 0
        highPassOutput = 0
        lowPassStage1 = 0
        lowPassStage2 = 0
    }
}

enum VoiceAudioError: LocalizedError {
    case microphoneUnavailable
    case invalidPlaybackFormat
    case tonePlaybackFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "没有可用的麦克风输入设备"
        case .invalidPlaybackFormat: return "无法创建 8 kHz 通话播放格式"
        case .tonePlaybackFailed: return "系统拒绝启动提示音播放器"
        }
    }
}

/// Measures existing PCM buffers. The view samples levels without publishing
/// per-frame changes through AppModel or retaining any speech samples.
final class CallAudioLevelMeter: @unchecked Sendable {
    enum Direction { case uplink, downlink }
    struct Snapshot {
        let uplink: Double
        let downlink: Double
        let uplinkMuted: Bool
    }
    private struct Reading {
        var amplitude: Double = 0
        var uptime: TimeInterval = 0
    }
    private let lock = NSLock()
    private var owner: UUID?
    private var uplink = Reading()
    private var downlink = Reading()
    private var uplinkMuted = false

    func beginSession(_ owner: UUID, uplinkMuted: Bool) {
        lock.withLock {
            self.owner = owner
            self.uplinkMuted = uplinkMuted
            uplink = Reading()
            downlink = Reading()
        }
    }

    func endSession() {
        lock.withLock {
            owner = nil
            uplink = Reading()
            downlink = Reading()
            uplinkMuted = false
        }
    }

    func setUplinkMuted(_ muted: Bool) {
        lock.withLock {
            uplinkMuted = muted
            if muted { uplink = Reading() }
        }
    }

    func record(_ pcm: Data, direction: Direction, owner: UUID,
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let count = pcm.count / 2
        guard count > 0 else { return }
        let energy = pcm.withUnsafeBytes { bytes -> Double in
            var sum = 0.0
            for index in 0..<count {
                let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
                let sample = Double(Int16(bitPattern: bits)) / 32_768
                sum += sample * sample
            }
            return sqrt(sum / Double(count))
        }
        lock.withLock {
            guard self.owner == owner else { return }
            if direction == .uplink && uplinkMuted { return }
            let previous = direction == .uplink ? uplink : downlink
            let elapsed = max(0, uptime - previous.uptime)
            let reading = Reading(amplitude: max(energy, previous.amplitude * exp(-elapsed / 0.12)),
                                  uptime: uptime)
            if direction == .uplink { uplink = reading }
            else { downlink = reading }
        }
    }

    func snapshot(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.withLock {
            guard owner != nil else { return .init(uplink: 0, downlink: 0, uplinkMuted: false) }
            return .init(uplink: uplinkMuted ? 0 : level(uplink, at: uptime),
                         downlink: level(downlink, at: uptime), uplinkMuted: uplinkMuted)
        }
    }

    private func level(_ reading: Reading, at uptime: TimeInterval) -> Double {
        let age = max(0, uptime - reading.uptime)
        guard age < 0.45, reading.amplitude > 0 else { return 0 }
        let amplitude = reading.amplitude * exp(-age / 0.12)
        let decibels = 20 * log10(amplitude)
        return max(0, min(1, (decibels + 60) / 60))
    }
}
