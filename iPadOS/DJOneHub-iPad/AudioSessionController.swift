import AVFoundation
import Network

enum PCMRoute: Equatable, Sendable {
    case moduleLocal
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)

    var host: String {
        switch self {
        case .moduleLocal: return "192.168.225.1"
        case let .vowlan(endpoint, _): return endpoint.host
        }
    }

    var port: UInt16 {
        switch self {
        case .moduleLocal: return 7_580
        case let .vowlan(endpoint, _): return endpoint.pcmPort
        }
    }

    var requiresWiFi: Bool {
        if case .vowlan = self { return true }
        return false
    }

    func handshake() throws -> Data {
        switch self {
        case .moduleLocal: return Data("DJ1PCM1\n".utf8)
        case let .vowlan(_, credential): return try VoWLANPCMHandshake.make(credential: credential)
        }
    }
}

enum VoWLANPCMHandshake {
    static func make(
        credential: VoWLANCredential,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        nonce: String = VoWLANRequestSigner.makeNonce()
    ) throws -> Data {
        let signed = try VoWLANRequestSigner(secret: credential.secret).sign(
            method: "PCM", path: "/v1/pcm", body: Data(), timestamp: timestamp, nonce: nonce
        )
        return Data("DJ1VWL1 \(signed.timestamp) \(signed.nonce) \(signed.signature)\n".utf8)
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

/// 管理 iPhone/iPad 内置麦克风、扬声器与模块 ECM 网络 PCM 之间的双向通话音频。
@MainActor
final class AudioSessionController: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var routeDescription = ""
    @Published private(set) var transportReady = false
    @Published private(set) var diagnosticDescription = ""
    @Published private(set) var moduleDiagnosticDescription = ""
    @Published private(set) var speakerEnabled = false
    @Published private(set) var speakerRoutePending = false
    @Published var errorMessage: String?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var transport: NetworkPCMTransport?
    private var encoder: VoicePCMEncoder?
    private var callTonePlayer: AVAudioPlayer?
    private var currentCallTone: CallTone?
    private var muted = false
    private var requestedSpeakerOverride = false
    private var speakerRouteRetryTask: Task<Void, Never>?
    private var sessionActivationManagedByCallKit = false
    private var routeChangeObserver: NSObjectProtocol?
    private var playbackQueue = PlaybackQueueTracker(maximumFrames: 4_000)

    init() {
        // CallKit、蓝牙或系统控制中心都可能改变输出路由，按钮状态必须跟随真实会话。
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleRouteChange(notification) }
        }
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
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
        route: PCMRoute = .moduleLocal,
        sessionAlreadyActive: Bool = false
    ) async -> Bool {
        guard !active else { return true }
        let permission = await requestMicrophonePermission()
        guard permission else {
            errorMessage = "需要麦克风权限才能进行双向通话"
            return false
        }

        do {
            let session = AVAudioSession.sharedInstance()
            sessionActivationManagedByCallKit = sessionAlreadyActive
            try configureCallAudioSession()
            if !sessionAlreadyActive {
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
            // 每次通话默认使用听筒；仅在用户主动开启扬声器后覆盖输出路由。
            try session.overrideOutputAudioPort(requestedSpeakerOverride ? .speaker : .none)
            refreshRouteDescription()

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let encoder = VoicePCMEncoder()
            // 用户可能在权限弹窗或音频启动期间切换静音，新编码器必须继承期望状态。
            encoder.setMuted(muted)
            let transport = NetworkPCMTransport(
                host: NWEndpoint.Host(route.host),
                port: NWEndpoint.Port(rawValue: route.port)!,
                handshake: try route.handshake(),
                requiresWiFi: route.requiresWiFi,
                onPCM: { [weak self] pcm in
                    Task { @MainActor [weak self] in self?.schedulePlayback(pcm) }
                },
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in self?.handleTransportEvent(event) }
                }
            )

            engine.attach(player)
            guard let playbackFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 8_000,
                channels: 1,
                interleaved: false
            ) else {
                throw VoiceAudioError.invalidPlaybackFormat
            }
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

            let input = engine.inputNode
            // voiceChat 只声明用途；显式启用 VoiceProcessingIO 才能获得回声消除与自动增益。
            try input.setVoiceProcessingEnabled(true)
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate >= 8_000 else {
                throw VoiceAudioError.microphoneUnavailable
            }
            input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) {
                buffer, _ in
                let pcm = encoder.encode(buffer)
                if !pcm.isEmpty { transport.sendPCM(pcm) }
            }

            engine.prepare()
            try engine.start()
            player.play()

            self.engine = engine
            self.player = player
            self.encoder = encoder
            self.transport = transport
            playbackQueue.reset()
            active = true
            transportReady = false
            routeDescription = route.requiresWiFi ? "正在连接 VoWLAN 语音…" : "正在连接模块网络语音…"
            diagnosticDescription = "\(DeviceContext.displayName) PCM 尚未握手"
            moduleDiagnosticDescription = ""
            errorMessage = nil
            retryRequestedSpeakerRoute()
            transport.start()
            return true
        } catch {
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
    }

    /// 根据模块通话状态播放来电铃声或呼出等待音，接通后立即让位给网络 PCM。
    func updateCallTone(for call: CallRecord?) {
        guard !active else {
            stopCallTone()
            return
        }
        guard let call else {
            // 设置页试听不属于通话状态，空闲轮询不能提前将它停止。
            if case .preview? = currentCallTone { return }
            stopCallTone()
            return
        }

        if call.direction == "incoming", ["incoming", "waiting"].contains(call.state) {
            let ringtone = UserDefaults.standard.string(forKey: "djonehub.ringtone") ?? "Hero"
            playCallTone(.incoming(ringtone), looping: true)
        } else if call.direction != "incoming", ["dialing", "alerting"].contains(call.state) {
            playCallTone(.outgoingWaiting, looping: true)
        } else {
            stopCallTone()
        }
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

    func stopCallTone(deactivateSession: Bool = true) {
        let hadTone = callTonePlayer != nil || currentCallTone != nil
        callTonePlayer?.stop()
        callTonePlayer = nil
        currentCallTone = nil
        // 空闲轮询会反复调用本方法；没有铃声时绝不能停用后台待机正在使用的会话。
        // CallKit 的 didActivate 回调之后，音频会话也只能由系统释放。
        guard hadTone, deactivateSession, !active, !sessionActivationManagedByCallKit else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// 切换当前通话的输出路由；关闭扬声器时交还给系统选择听筒或已连接的蓝牙设备。
    func setSpeakerEnabled(_ enabled: Bool) {
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

    func resetSpeakerPreferenceForNewCall() {
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = nil
        requestedSpeakerOverride = false
        speakerRoutePending = false
        refreshRouteDescription()
    }

    /// CallKit 的 didActivate 与 AVAudioEngine 真正启动之间存在短暂窗口。
    /// 在窗口内切换会得到 OSStatus -50，因此把用户选择保留并做有界重试。
    func retryRequestedSpeakerRoute() {
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
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(
                        requested ? .speaker : .none
                    )
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

    func deactivate() {
        let callKitManagedSession = sessionActivationManagedByCallKit
        sessionActivationManagedByCallKit = false
        muted = false
        requestedSpeakerOverride = false
        speakerRouteRetryTask?.cancel()
        speakerRouteRetryTask = nil
        speakerRoutePending = false
        stopCallTone()
        transport?.stop()
        transport = nil
        encoder = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        player?.stop()
        player = nil
        engine = nil
        playbackQueue.reset()
        do {
            let session = AVAudioSession.sharedInstance()
            // 清除本次通话的外放覆盖，避免影响下一次通话或其他 App。
            try session.overrideOutputAudioPort(.none)
            if !callKitManagedSession {
                try session.setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        active = false
        transportReady = false
        routeDescription = ""
        diagnosticDescription = ""
        moduleDiagnosticDescription = ""
        refreshRouteDescription()
    }

    private func playCallTone(_ tone: CallTone, looping: Bool) {
        guard currentCallTone != tone || callTonePlayer?.isPlaying != true else { return }
        stopCallTone()

        do {
            let session = AVAudioSession.sharedInstance()
            // 模块来电属于电话提醒，使用 playback 确保手机静音时仍能听到，并压低其他音频。
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: SynthesizedCallTone.wavData(for: tone))
            player.numberOfLoops = looping ? -1 : 0
            player.volume = tone.volume
            player.prepareToPlay()
            guard player.play() else { throw VoiceAudioError.tonePlaybackFailed }
            callTonePlayer = player
            currentCallTone = tone
        } catch {
            callTonePlayer = nil
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
            options: [.allowBluetoothHFP]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
    }

    private func handleTransportEvent(_ event: NetworkPCMTransport.Event) {
        switch event {
        case .connected:
            transportReady = true
            diagnosticDescription = "\(DeviceContext.displayName) PCM 已握手，等待语音数据"
            refreshRouteDescription()
            errorMessage = nil
        case let .statistics(statistics):
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
        if speakerEnabled != routedToSpeaker {
            speakerEnabled = routedToSpeaker
        }
        speakerRoutePending = speakerRouteRetryTask != nil && !SpeakerRoutePolicy.routeMatches(
            requestedSpeaker: requestedSpeakerOverride,
            currentRouteIsSpeaker: routedToSpeaker
        )
        routeDescription = "\(input.isEmpty ? "无输入" : input) ↔ 网络 PCM ↔ \(output.isEmpty ? "无输出" : output)（可用输入：\(inputs)）"
        IPhoneCloudCallSession.shared.recordAudioRoute(output.isEmpty ? "unknown" : output)
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshRouteDescription()
        guard speakerRouteRetryTask == nil else { return }
        requestedSpeakerOverride = SpeakerRoutePolicy.requestedSpeakerAfterSystemRouteChange(
            requestedSpeaker: requestedSpeakerOverride,
            observedRouteIsSpeaker: speakerEnabled
        )
        speakerRoutePending = false
    }

    private func schedulePlayback(_ pcm: Data) {
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
        pcm.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frame in 0 ..< frames {
                let bits = UInt16(bytes[frame * 2]) |
                    UInt16(bytes[frame * 2 + 1]) << 8
                output[frame] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackQueue.complete(frames: frames)
            }
        }
        if !player.isPlaying { player.play() }
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
    case preview(String)

    var ringtoneName: String {
        switch self {
        case let .incoming(name), let .preview(name): return name
        case .outgoingWaiting: return "呼出等待"
        }
    }

    var volume: Float {
        switch self {
        case .outgoingWaiting: return 0.55
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

/// 维护一个带固定握手的低延迟 TCP 字节流；连接仅指向模块 ECM 私网地址。
private final class NetworkPCMTransport: @unchecked Sendable {
    enum Event: Sendable {
        case connected
        case statistics(NetworkPCMStatistics)
        case status(String)
        case failed(String)
        case closed
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let handshake: Data
    private let requiresWiFi: Bool
    private let queue = DispatchQueue(label: "com.jieden.djonehub.network-pcm")
    private let onPCM: @Sendable (Data) -> Void
    private let onEvent: @Sendable (Event) -> Void
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

    private static let acknowledgement = Data("DJ1READY".utf8)
    // 模块首次加载语音驱动、ACDB 校准和 D4 route session 最坏需要约 35 秒。
    private static let coldStartRetryWindowNanoseconds: UInt64 = 45_000_000_000

    init(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        handshake: Data,
        requiresWiFi: Bool,
        onPCM: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.host = host
        self.port = port
        self.handshake = handshake
        self.requiresWiFi = requiresWiFi
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
            lastFailureMessage = ""
            deadline = DispatchTime.now().uptimeNanoseconds
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
        guard !pcm.isEmpty else { return }
        queue.async { [self] in
            guard readyForPCM, let connection else { return }
            uplinkBytes += UInt64(pcm.count)
            uplinkPeak = max(uplinkPeak, Self.peak(of: pcm))
            emitStatisticsIfNeeded()
            connection.send(content: pcm, completion: .contentProcessed { _ in })
        }
    }

    private func startAttempt() {
        guard !stopped else { return }
        generation += 1
        let attempt = generation
        let useWiredInterface = !requiresWiFi && !fallbackAttempted
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // 首选 USB ECM；部分 iOS 版本把 USB 网卡报告为 other，失败后再放宽接口筛选。
        if requiresWiFi {
            parameters.requiredInterfaceType = .wifi
        } else if useWiredInterface {
            parameters.requiredInterfaceType = .wiredEthernet
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        readyForPCM = false
        onEvent(.status(requiresWiFi ? "正在通过 VoWLAN 连接 PCM" : (useWiredInterface ? "正在通过 USB 网卡连接 PCM" : "正在回退到普通 TCP 连接 PCM")))
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
                    self.sendHandshake(connection, attempt: attempt)
                case let .waiting(error):
                    // NWConnection 在模块 helper 冷启动时会短暂报告 POSIX 61；
                    // 这是可恢复状态，不能把底层错误原样暴露成通话失败。
                    self.onEvent(.status(self.transientStatus(for: error)))
                case let .failed(error):
                    self.retryOrFail(error.localizedDescription, attempt: attempt, allowFallback: useWiredInterface)
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
            self.retryOrFail("连接模块网络 PCM 超时", attempt: attempt, allowFallback: useWiredInterface)
        }
    }

    private func sendHandshake(_ connection: NWConnection, attempt: Int) {
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
                // 每次成功握手都重新开启恢复窗口，避免长通话在首次 45 秒窗口后断线即永久静音。
                self.deadline = DispatchTime.now().uptimeNanoseconds
                    + Self.coldStartRetryWindowNanoseconds
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
        let now = DispatchTime.now().uptimeNanoseconds
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
        lastFailureMessage = message
        readyForPCM = false
        connection?.cancel()
        connection = nil
        if allowFallback && !fallbackAttempted {
            // USB ECM 在不同 iOS 版本上的接口类型标识不一致；只切换 Network.framework
            // 的接口筛选，不改变目标地址，避免把控制链路误切到公网。
            fallbackAttempted = true
            onEvent(.status("USB 网卡连接失败，正在重试 PCM"))
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.startAttempt() }
            return
        }
        if !stopped, DispatchTime.now().uptimeNanoseconds < deadline {
            // 连接拒绝通常只表示模块语音桥还在启动；保留重试，但不显示 NWError。
            onEvent(.status(transientStatus(for: message)))
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.startAttempt()
            }
        } else if !stopped {
            onEvent(.failed("等待模块语音桥就绪超时，请保持模块接入后重试通话"))
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

private struct NetworkPCMStatistics: Sendable {
    let uplinkBytes: UInt64
    let uplinkPeak: Int
    let downlinkBytes: UInt64
    let downlinkPeak: Int
}

/// 对麦克风做语音带限与线性降采样，输出模块需要的 8 kHz PCM16LE。
private final class VoicePCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var conditioner = VoiceCaptureConditioner()
    private var samples: [Float] = []
    private var position = 0.0
    private var sampleRate = 0.0
    private var muted = false

    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data {
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

private enum VoiceAudioError: LocalizedError {
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
