import Foundation

enum VoBLEDiagnosticErrorCategory: String, Codable, Sendable {
    case none, bluetooth, authentication, control, pcm, audio, timeout, unknown

    static func classify(_ message: String?) -> Self {
        guard let value = message?.lowercased(), !value.isEmpty else { return .none }
        if value.contains("认证") || value.contains("auth") || value.contains("key") { return .authentication }
        if value.contains("pcm") || value.contains("媒体") { return .pcm }
        if value.contains("audio") || value.contains("音频") { return .audio }
        if value.contains("超时") || value.contains("timeout") { return .timeout }
        if value.contains("control") || value.contains("命令") { return .control }
        if value.contains("蓝牙") || value.contains("bluetooth") { return .bluetooth }
        return .unknown
    }
}

struct VoBLEDiagnosticsSnapshot: Equatable, Sendable {
    let selectedMode: String
    let connection: String
    let peerAuthenticated: Bool
    let agentType: String
    let pcmReady: Bool
    let codec: String
    let queuedFrames: Int
    let droppedFrames: Int
    let jitterFrames: Int
    let lastError: VoBLEDiagnosticErrorCategory

    var sanitizedFields: [String: String] {
        [
            "mode": selectedMode,
            "connection": connection,
            "peer_authenticated": String(peerAuthenticated),
            "agent_type": agentType,
            "pcm_ready": String(pcmReady),
            "codec": codec,
            "queued_frames": String(queuedFrames),
            "dropped_frames": String(droppedFrames),
            "jitter_frames": String(jitterFrames),
            "last_error": lastError.rawValue,
        ]
    }

    static func sanitize(_ values: [String: String]) -> [String: String] {
        let forbidden = ["number", "phone", "secret", "nonce", "tag", "payload", "key"]
        return values.filter { key, _ in
            !forbidden.contains(where: { key.lowercased().contains($0) })
        }.mapValues { value in String(value.prefix(96)) }
    }
}

struct VoBLERecoveryPolicy: Equatable, Sendable {
    let identity: VoBLEMediaSessionIdentity
    let deadline: Date

    init(identity: VoBLEMediaSessionIdentity, disconnectedAt: Date, grace: TimeInterval = 3) {
        self.identity = identity
        deadline = disconnectedAt.addingTimeInterval(grace)
    }

    func accepts(_ candidate: VoBLEMediaSessionIdentity, at date: Date) -> Bool {
        candidate == identity && date <= deadline
    }
}
