import AVFoundation
import CallKit
import Foundation

enum VirtualCallTTSError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "虚拟来电没有可播报的内容"
        }
    }
}

/// Dashboard 虚拟来电的本地媒体源。CallKit 仍负责系统来电生命周期与音频路由，
/// 但接听/挂断不会向模块发送 AT，也不会建立公网 PCM 会话。
@MainActor
final class VirtualCallTTSController: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VirtualCallTTSController()

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var call: IncomingVoIPCall?
    private var started = false

    var isPrepared: Bool { call?.isVirtual == true }

    private override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func prepare(_ incoming: IncomingVoIPCall) throws {
        guard incoming.isVirtual, incoming.ttsText?.isEmpty == false else {
            throw VirtualCallTTSError.invalidPayload
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        call = incoming
        started = false
    }

    /// 只能在 CXProvider 激活 CallKit 的 AVAudioSession 后开始播报。
    func start() {
        guard !started, let text = call?.ttsText else { return }
        started = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.preUtteranceDelay = 0.18
        synthesizer.speak(utterance)
    }

    func setMuted(_ muted: Bool) {
        if muted {
            _ = synthesizer.pauseSpeaking(at: .immediate)
        } else if synthesizer.isPaused {
            _ = synthesizer.continueSpeaking()
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        call = nil
        started = false
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard VirtualCallTTSController.shared.isPrepared else { return }
            // 播报完成等同远端结束；CallKit 收起后由 didDeactivate 清理媒体状态。
            CallKitController.shared.reportCurrentCallEnded(reason: .remoteEnded)
        }
    }
}
