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

    /// Whether the iPhone tells Android to end the carrier call. A queued answer, or one
    /// whose outcome Android could not confirm, could otherwise pick up a call nobody
    /// is on; a refused call keeps ringing; the device that answered elsewhere must
    /// never be hung up.
    var endsAndroidCall: Bool {
        switch self {
        case .cloudUnreachable, .cloudUnavailable, .androidOffline, .androidUnresponsive,
             .androidAnswerFailed: return true
        case let .androidNoAudio(callAnswered): return callAnswered
        case .answeredElsewhere: return false
        }
    }

    var notifies: Bool { self != .answeredElsewhere }
}

enum CloudAnswerSignal: Equatable, Sendable {
    /// The cloud answer itself began; a local route may have been tried first.
    case cloudAnswerStarted
    case earlyReceipt(agentConnected: Bool)
    /// The Relay answered HTTP 429 or 5xx (for example capacity exhausted).
    case relayUnavailable
    /// A Relay or Android status from the media connection. `identified` says the
    /// status names this call in full and is about the answer; a failure status counts
    /// only then. The AVF agent replies to every Relay event it cannot attribute
    /// (`peer_connected`, `owner_claimed`) with an identity-less `action_error`.
    case control(status: String, role: String?, identified: Bool = true)
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
    private var cloudAnswerStarted = false
    /// When Android first reported that the answer failed before picking up.
    private var answerErrorAt: Date?
    /// How long an answer error may be undone by a retry that picks up.
    static let answerErrorGrace: TimeInterval = 5

    var isFinished: Bool { connectedAt != nil || failure != nil }

    init(startedAt: Date) {
        self.startedAt = startedAt
        stageEnteredAt = startedAt
    }

    mutating func apply(_ signal: CloudAnswerSignal, at now: Date) {
        guard !isFinished else { return }
        switch signal {
        case .cloudAnswerStarted:
            // Time spent trying a local route first is not time the cloud had. Only the
            // first start counts, so a replayed answer never extends the limit.
            if !cloudAnswerStarted, stage == .connectingCloud { stageEnteredAt = now }
            cloudAnswerStarted = true
        case let .earlyReceipt(agentConnected):
            advance(to: agentConnected ? .androidAnswering : .waitingForAndroid, at: now)
        case .relayUnavailable:
            // The HTTP early answer is best effort. Once the media connection has shown
            // any progress it is the one that counts, and a late HTTP failure is not final.
            if stage == .connectingCloud { failure = .cloudUnavailable }
        case .downlinkAudio:
            connectedAt = now
        case let .control(status, role, identified):
            switch status {
            case "action_queued": advance(to: .waitingForAndroid, at: now)
            case "action_forwarded": advance(to: .androidAnswering, at: now)
            case "peer_connected":
                if role == "agent", stage == .waitingForAndroid { advance(to: .androidAnswering, at: now) }
            case "answer_ok": advance(to: .connectingVoice, at: now)
            case "active", "pcm_first_frame": connectedAt = now
            case "answer_unavailable" where identified: failure = .androidNoAudio(callAnswered: false)
            case "action_error" where identified:
                if stage == .connectingVoice {
                    failure = .androidNoAudio(callAnswered: true)
                } else if answerErrorAt == nil {
                    // Not final yet: the call may not have been ready, and the next
                    // answer retry (three seconds later) can still pick up.
                    answerErrorAt = now
                }
            case "ownership_lost": failure = .answeredElsewhere
            default: break
            }
        }
    }

    /// Fails the answer once the current stage has lasted its time limit, or once an
    /// answer error Android reported has outlasted the retry.
    mutating func tick(at now: Date) {
        guard !isFinished else { return }
        let stageExpired = now.timeIntervalSince(stageEnteredAt) >= stage.timeout
        if stage < .connectingVoice, let answerErrorAt {
            if stageExpired || now.timeIntervalSince(answerErrorAt) >= Self.answerErrorGrace {
                failure = .androidAnswerFailed
            }
            return
        }
        guard stageExpired else { return }
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

enum CloudAnswerProgressPolicy {
    /// Progress describes cloud answers only. A push carries cloud media even with the
    /// cloud switched off; that answer goes local, and a "cloud unreachable" timeout
    /// would end a call that is connecting over VoWLAN.
    static func shows(bluetoothMode: Bool, cloudEnabled: Bool, hasCloudMedia: Bool, isVirtual: Bool) -> Bool {
        !bluetoothMode && cloudEnabled && hasCloudMedia && !isVirtual
    }

    /// Whether the failed answer may end the system call and the session's call. The
    /// failure stays on screen for a moment first, which can outlive the call: never
    /// end the next call's screen or stop another call's media.
    static func mayEnd(failed: UUID, systemCall: UUID?, sessionCall: UUID?) -> Bool {
        systemCall == failed && (sessionCall == nil || sessionCall == failed)
    }

    /// Whether progress text may be written to the CallKit name line. Once the user's
    /// hang-up is accepted the number has been written back for Recents; the call stays
    /// current while the backend ends it, and a late tick must not overwrite the number.
    static func mayWriteNameLine(isCurrentCall: Bool, systemCallReported: Bool, endAccepted: Bool) -> Bool {
        isCurrentCall && systemCallReported && !endAccepted
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
