import Foundation

/// Progress of one cloud answer, from CallKit accepting it to voice or a failure.
/// Foundation-only so the exact production file is checked by
/// iOS/scripts/test-cloud-answer-progress.sh without Xcode.
enum CloudAnswerStage: Int, Comparable, CaseIterable, Sendable {
    case connectingCloud = 1
    case waitingForAndroid
    case androidAnswering
    case connectingVoice

    static func < (lhs: CloudAnswerStage, rhs: CloudAnswerStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .connectingCloud: return "正在连接云端"
        case .waitingForAndroid: return "正在等待安卓端响应"
        case .androidAnswering: return "安卓端正在接听"
        case .connectingVoice: return "正在接通语音"
        }
    }

    var detail: String {
        switch self {
        case .connectingCloud: return "iPhone 正在连上云端"
        case .waitingForAndroid: return "安卓端连上云端后会立即接听"
        case .androidAnswering: return "接听指令已发给安卓端"
        case .connectingVoice: return "电话已接起，马上就能说话"
        }
    }

    /// Text for the CallKit name line, which never shows the caller's name.
    var shortLabel: String {
        switch self {
        case .connectingCloud: return "连接云端"
        case .waitingForAndroid: return "等待安卓端"
        case .androidAnswering: return "安卓端接听中"
        case .connectingVoice: return "接通语音中"
        }
    }

    /// How long a stage may last before the answer counts as failed.
    var timeout: TimeInterval { self == .connectingVoice ? 15 : 10 }
}

enum CloudAnswerFailure: Equatable, Sendable {
    case cloudUnreachable
    case cloudUnavailable
    case androidOffline
    case androidUnresponsive
    /// `callAnswered` is false when Android refused to pick up (the call keeps
    /// ringing there) and true when the carrier call is already answered but silent.
    case androidNoAudio(callAnswered: Bool)
    case androidAnswerFailed
    case answeredElsewhere

    var title: String {
        switch self {
        case .cloudUnreachable: return "无法连接云端"
        case .cloudUnavailable: return "云端暂时不可用"
        case .androidOffline: return "安卓端未上线"
        case .androidUnresponsive: return "安卓端没有响应"
        case .androidNoAudio: return "安卓端无法传送语音"
        case .androidAnswerFailed: return "安卓端未能接起电话"
        case .answeredElsewhere: return "已在其他设备接听"
        }
    }

    var advice: String? {
        switch self {
        case .cloudUnreachable: return "检查 iPhone 的网络"
        case .cloudUnavailable: return "稍后回拨对方"
        case .androidOffline, .androidUnresponsive: return "检查安卓端的网络，确认 AirSIM 在运行"
        case .androidNoAudio: return "在安卓端启动 Shizuku 后回拨"
        case .androidAnswerFailed: return "对方可能已挂断"
        case .answeredElsewhere: return nil
        }
    }

    /// Whether the iPhone tells Android to end the carrier call. A queued answer could
    /// otherwise pick up a call nobody is on; a refused call keeps ringing; the device
    /// that answered elsewhere must never be hung up.
    var endsAndroidCall: Bool {
        switch self {
        case .cloudUnreachable, .cloudUnavailable, .androidOffline, .androidUnresponsive: return true
        case let .androidNoAudio(callAnswered): return callAnswered
        case .androidAnswerFailed, .answeredElsewhere: return false
        }
    }

    var notifies: Bool { self != .answeredElsewhere }
}

enum CloudAnswerSignal: Equatable, Sendable {
    case earlyReceipt(agentConnected: Bool)
    /// The Relay answered HTTP 429 or 5xx (for example capacity exhausted).
    case relayUnavailable
    /// A Relay or Android status from the media connection, already identity-checked.
    case control(status: String, role: String?)
    /// The first downlink voice frame: connected even when ACTIVE was lost.
    case downlinkAudio
}

struct CloudAnswerProgress: Equatable, Sendable {
    static let failedNameLine = "接听失败"
    static let slowDetail = "比平均慢，可能是网络较差"

    let startedAt: Date
    private(set) var stage: CloudAnswerStage = .connectingCloud
    private(set) var stageEnteredAt: Date
    private(set) var connectedAt: Date?
    private(set) var failure: CloudAnswerFailure?

    var isFinished: Bool { connectedAt != nil || failure != nil }

    init(startedAt: Date) {
        self.startedAt = startedAt
        stageEnteredAt = startedAt
    }

    mutating func apply(_ signal: CloudAnswerSignal, at now: Date) {
        guard !isFinished else { return }
        switch signal {
        case let .earlyReceipt(agentConnected):
            advance(to: agentConnected ? .androidAnswering : .waitingForAndroid, at: now)
        case .relayUnavailable:
            failure = .cloudUnavailable
        case .downlinkAudio:
            connectedAt = now
        case let .control(status, role):
            switch status {
            case "action_queued": advance(to: .waitingForAndroid, at: now)
            case "action_forwarded": advance(to: .androidAnswering, at: now)
            case "peer_connected":
                if role == "agent", stage == .waitingForAndroid { advance(to: .androidAnswering, at: now) }
            case "answer_ok": advance(to: .connectingVoice, at: now)
            case "active", "pcm_first_frame": connectedAt = now
            case "answer_unavailable": failure = .androidNoAudio(callAnswered: false)
            case "action_error":
                failure = stage == .connectingVoice ? .androidNoAudio(callAnswered: true) : .androidAnswerFailed
            case "ownership_lost": failure = .answeredElsewhere
            default: break
            }
        }
    }

    /// Fails the answer once the current stage has lasted its time limit.
    mutating func tick(at now: Date) {
        guard !isFinished, now.timeIntervalSince(stageEnteredAt) >= stage.timeout else { return }
        switch stage {
        case .connectingCloud: failure = .cloudUnreachable
        case .waitingForAndroid: failure = .androidOffline
        case .androidAnswering: failure = .androidUnresponsive
        case .connectingVoice: failure = .androidNoAudio(callAnswered: true)
        }
    }

    func waitedSeconds(at now: Date) -> Int { max(0, Int(now.timeIntervalSince(startedAt))) }

    func nameLine(at now: Date) -> String {
        failure == nil ? "\(stage.shortLabel) \(waitedSeconds(at: now)) 秒" : Self.failedNameLine
    }

    func detail(at now: Date, average: Int?) -> String {
        if let average, isSlow(at: now, average: average) { return Self.slowDetail }
        return stage.detail
    }

    func waitedText(at now: Date, average: Int?) -> String {
        let waited = "已等待 \(waitedSeconds(at: now)) 秒"
        guard let average else { return waited }
        return "\(waited) · 平均约 \(average) 秒"
    }

    private mutating func advance(to next: CloudAnswerStage, at now: Date) {
        guard next > stage else { return }
        stage = next
        stageEnteredAt = now
    }

    private func isSlow(at now: Date, average: Int) -> Bool {
        let waited = waitedSeconds(at: now)
        return waited >= 5 && waited > 2 * average
    }
}

/// Seconds from CallKit accepting a cloud answer to voice, kept only on this iPhone.
enum CloudAnswerDurationHistory {
    static let key = "airsim.cloud-answer-durations.v1"
    static let limit = 10
    static let minimumSamples = 3

    static func record(_ seconds: TimeInterval, defaults: UserDefaults = .standard) {
        guard seconds.isFinite, seconds >= 0 else { return }
        var values = defaults.array(forKey: key) as? [Double] ?? []
        values.append(seconds)
        defaults.set(Array(values.suffix(limit)), forKey: key)
    }

    /// The rounded average of the latest answers, or nil until there are enough.
    static func average(defaults: UserDefaults = .standard) -> Int? {
        let values = defaults.array(forKey: key) as? [Double] ?? []
        guard values.count >= minimumSamples else { return nil }
        return Int((values.reduce(0, +) / Double(values.count)).rounded())
    }
}
