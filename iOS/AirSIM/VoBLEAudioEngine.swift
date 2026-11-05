import AVFoundation
import Foundation

enum VoBLEPlaybackScheduling {
    static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode,
                         completion: @escaping @Sendable () -> Void) {
        // Refill when the player consumes data, not after Voice Processing I/O
        // and the receiver have presented it. The latter includes sink latency
        // and can starve a bounded streaming queue every few buffers.
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { _ in completion() }
    }
}

@MainActor
final class VoBLEAudioEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var errorMessage: String?

    private let transport: VoBLEGATTMediaTransport
    private let enableVoiceProcessing: (AVAudioEngine) throws -> Void
    private let installInputTap: (AVAudioInputNode, AVAudioFormat?, @escaping AVAudioNodeTapBlock) throws -> Void
    private var gate = VoBLEAudioStartGate()
    var callKitAudioActive: Bool { gate.callKitAudioActive }
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var encoder: VoicePCMEncoder?
    private var playbackTask: Task<Void, Never>?
    private var playbackGeneration = UUID()
    private var playbackQueue = PlaybackQueueTracker(maximumFrames: 480)
    private var pendingCapture = Data()
    private var muted = false
    private(set) var receiveOnly = false
    private var captureInstalled = false
    var onEarlyPlayback: (() -> Void)?
#if DEBUG
    private var capturedFrames = 0
    private var playedFrames = 0
#endif

    func prepareForCall(managedByCallKit: Bool, callKitAudioActive: Bool, receiveOnly: Bool = false) async throws {
        if self.receiveOnly != receiveOnly { stopEngine(); gate.mediaReady = false }
        self.receiveOnly = receiveOnly
        if !receiveOnly {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        }
        guard granted else { throw VoiceAudioError.microphoneUnavailable }
        }
        gate.callKitAudioActive = callKitAudioActive
        if !managedByCallKit {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(receiveOnly ? .playback : .playAndRecord, mode: receiveOnly ? .default : .voiceChat, options: receiveOnly ? [] : [.allowBluetoothHFP])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            try session.overrideOutputAudioPort(.none)
            gate.appAudioSessionActive = true
        }
        updateRunningState()
    }

    init(transport: VoBLEGATTMediaTransport,
         enableVoiceProcessing: @escaping (AVAudioEngine) throws -> Void = {
             try $0.inputNode.setVoiceProcessingEnabled(true)
         }, installInputTap: @escaping (AVAudioInputNode, AVAudioFormat?, @escaping AVAudioNodeTapBlock) throws -> Void = {
             try CallAudioGraph.installCapture($0, format: $1, block: $2)
         }) {
        self.transport = transport
        self.enableVoiceProcessing = enableVoiceProcessing
        self.installInputTap = installInputTap
    }

    func setMediaReady(_ ready: Bool) {
        gate.mediaReady = ready
#if DEBUG
        print("[AirSIM VoBLE Audio] mediaReady=\(ready) callKitActive=\(gate.callKitAudioActive) appActive=\(gate.appAudioSessionActive)")
#endif
        updateRunningState()
    }

    func setCallKitAudioActive(_ active: Bool) {
        gate.callKitAudioActive = active
#if DEBUG
        print("[AirSIM VoBLE Audio] callKitActive=\(active) mediaReady=\(gate.mediaReady) appActive=\(gate.appAudioSessionActive)")
#endif
        updateRunningState()
    }

    func setMuted(_ value: Bool) {
        muted = value
        encoder?.setMuted(value)
    }

    func stop() {
        let deactivateAppSession = gate.appAudioSessionActive
        gate = VoBLEAudioStartGate()
        stopEngine()
        if deactivateAppSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func updateRunningState() {
        if gate.canStart {
            if !running { startEngine() }
        } else if running { stopEngine() }
    }

    private func startEngine() {
        var phase = "enable_voice_processing"
        do {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let encoder = VoicePCMEncoder()
            encoder.setMuted(muted)
            engine.attach(player)
            // VoiceProcessingIO replaces the I/O nodes. Configure it before
            // connecting the fixed-rate player graph (otherwise AVFAudio can
            // raise an Objective-C exception, which Swift catch cannot handle).
            if !receiveOnly { try enableVoiceProcessing(engine) }
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
                channels: 1, interleaved: false) else {
                throw VoiceAudioError.invalidPlaybackFormat
            }
            phase = "connect_playback"
            try CallAudioGraph.connectPlayback(player, engine: engine, format: format)
            var inputRate: Double = 0
            if !receiveOnly {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0 else { throw VoiceAudioError.microphoneUnavailable }
            phase = "install_capture_tap"
            try installInputTap(input, nil) {
                [weak self, weak encoder] buffer, _ in
                guard let encoded = encoder?.encode(buffer), !encoded.isEmpty else { return }
                Task { @MainActor [weak self] in self?.acceptCaptured(encoded) }
            }
            captureInstalled = true
            inputRate = inputFormat.sampleRate
            }
            phase = "start_engine"
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine; self.player = player; self.encoder = encoder
            playbackGeneration = UUID()
            playbackQueue.reset()
            running = true; errorMessage = nil
            Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "voble",
                phase: "engine_ready", title: "蓝牙语音引擎已启动",
                fields: ["input_rate": String(inputRate)]) }
#if DEBUG
            capturedFrames = 0
            playedFrames = 0
            print("[AirSIM VoBLE Audio] started inputRate=\(inputRate) route=\(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))")
#endif
            playbackTask = Task { @MainActor [weak self] in
                var diagnosticTicks = 0
#if DEBUG
                var ticks = 0
#endif
                while !Task.isCancelled {
                    // This task only primes/restarts a starved player. Normal
                    // replenishment follows the audio clock via completion,
                    // not a drifting 20 ms MainActor timer.
                    self?.fillPlaybackQueue()
                    diagnosticTicks += 1
                    if diagnosticTicks % 200 == 0, let self {
                        let fields = ["engine_running": String(self.engine?.isRunning == true),
                            "player_playing": String(self.player?.isPlaying == true),
                            "capture_buffers": String(self.encoder?.capturedBuffers ?? 0),
                            "input_format": self.receiveOnly ? "recvonly" : (self.engine?.inputNode.outputFormat(forBus: 0).description ?? "none"),
                            "output_format": self.engine?.outputNode.inputFormat(forBus: 0).description ?? "none",
                            "system_output_volume": String(AVAudioSession.sharedInstance().outputVolume),
                            "player_volume": String(self.player?.volume ?? 0),
                            "player_render_sample": String(self.player?.lastRenderTime?.sampleTime ?? -1),
                            "queued_frames": String(self.transport.queuedFrameCount),
                            "dropped_frames": String(self.transport.droppedFrameCount),
                            "jitter_frames": String(self.transport.jitterTargetFrames),
                            "media": self.transport.diagnosticSummary,
                            "input_route": AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue).joined(separator: ","),
                            "output_route": AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")]
                        await AgentVerboseTraceRecorder.shared.recordEvent(source: "APP", category: "voble",
                            phase: "media_statistics", title: "VoBLE 实际音频状态", fields: fields)
                    }
#if DEBUG
                    ticks += 1
                    if ticks % 100 == 0, let self {
                        print("[AirSIM VoBLE Audio] stats engineRunning=\(self.engine?.isRunning == true) captured=\(self.capturedFrames) played=\(self.playedFrames) dropped=\(self.transport.droppedFrameCount) \(self.transport.diagnosticSummary)")
                    }
#endif
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        } catch {
            let failedPhase = phase
            Task { await AgentVerboseTraceRecorder.shared.recordFailure(category: "voble", phase: failedPhase, error: error) }
            stopEngine()
            errorMessage = "无法启动蓝牙通话音频：\(error.localizedDescription)"
            Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "voble",
                phase: "engine_failed", title: "蓝牙语音引擎启动失败",
                fields: ["error_domain": (error as NSError).domain,
                         "error_code": String((error as NSError).code)], isFailure: true) }
#if DEBUG
            print("[AirSIM VoBLE Audio] start_failed \(error.localizedDescription)")
#endif
        }
    }

    private func acceptCaptured(_ data: Data) {
        guard !receiveOnly else { return }
        pendingCapture.append(data)
        while pendingCapture.count >= 320 {
            transport.enqueueCapturedPCM(Data(pendingCapture.prefix(320)))
#if DEBUG
            capturedFrames += 1
#endif
            pendingCapture.removeFirst(320)
        }
    }

    private func fillPlaybackQueue() {
        while running, playbackQueue.scheduledFrames < playbackQueue.maximumFrames {
            guard let frame = transport.dequeuePlayback() else { return }
            schedulePlayback(frame)
        }
    }

    private func schedulePlayback(_ frame: VoBLEPlaybackFrame) {
        guard running, let player else { return }
        if receiveOnly { onEarlyPlayback?() }
        let samples = frame.pcm.count / 2
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
            channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)),
              let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples)
        frame.pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<samples {
                let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
                output[index] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        guard playbackQueue.reserve(frames: samples) else { return }
        let generation = playbackGeneration
        VoBLEPlaybackScheduling.schedule(buffer, on: player) {
            [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.playbackGeneration == generation else { return }
                self.playbackQueue.complete(frames: samples)
                self.fillPlaybackQueue()
            }
        }
#if DEBUG
        playedFrames += 1
#endif
        if !player.isPlaying { player.play() }
    }

    private func stopEngine() {
#if DEBUG
        if running { print("[AirSIM VoBLE Audio] stopped") }
#endif
        playbackTask?.cancel(); playbackTask = nil
        playbackGeneration = UUID()
        playbackQueue.reset()
        pendingCapture.removeAll(keepingCapacity: true)
        if let engine {
            if captureInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        captureInstalled = false
        player?.stop(); player = nil; engine = nil; encoder = nil; running = false
    }
}
