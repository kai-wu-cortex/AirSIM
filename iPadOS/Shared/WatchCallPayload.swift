import Foundation

enum WatchCallPhase: String, Codable, Sendable {
    case idle
    case incoming
    case connecting
    case active
    case ended
}

struct WatchCallPayload: Equatable, Sendable {
    let callID: String
    let callUUID: UUID?
    let phase: WatchCallPhase
    let number: String?
    let callerName: String?
    let updatedAt: Date

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "event": "watch_call_state",
            "call_id": callID,
            "call_uuid": callUUID?.uuidString ?? "",
            "phase": phase.rawValue,
            "updated_at": updatedAt.timeIntervalSince1970,
        ]
        if let number, !number.isEmpty { value["number"] = number }
        if let callerName, !callerName.isEmpty { value["caller_name"] = callerName }
        return value
    }

    init(
        callID: String,
        callUUID: UUID?,
        phase: WatchCallPhase,
        number: String?,
        callerName: String?,
        updatedAt: Date
    ) {
        self.callID = callID
        self.callUUID = callUUID
        self.phase = phase
        self.number = number
        self.callerName = callerName
        self.updatedAt = updatedAt
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["event"] as? String == "watch_call_state",
              let phaseValue = dictionary["phase"] as? String,
              let phase = WatchCallPhase(rawValue: phaseValue),
              let updatedAt = dictionary["updated_at"] as? TimeInterval else { return nil }
        let callID = dictionary["call_id"] as? String ?? ""
        let uuidValue = dictionary["call_uuid"] as? String
        self.init(
            callID: callID,
            callUUID: uuidValue.flatMap(UUID.init(uuidString:)),
            phase: phase,
            number: dictionary["number"] as? String,
            callerName: dictionary["caller_name"] as? String,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

enum WatchVoIPPayloadError: LocalizedError {
    case unsupportedEvent
    case missingCallID
    case invalidCallUUID
    case missingSecret
    case invalidMediaURL
    case expired
    case invalidLocalMedia

    var errorDescription: String? {
        switch self {
        case .unsupportedEvent: return "不是有效的手表来电推送"
        case .missingCallID: return "手表来电推送缺少 call_id"
        case .invalidCallUUID: return "手表来电推送缺少有效 call_uuid"
        case .missingSecret: return "手表来电推送缺少媒体密钥"
        case .invalidMediaURL: return "手表来电推送缺少安全媒体地址"
        case .expired: return "手表来电推送已经过期"
        case .invalidLocalMedia: return "手表本地语音参数无效"
        }
    }
}

struct WatchLocalPCMEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16
    let secret: Data

    init?(dictionary: [String: Any]) {
        guard let host = dictionary["pcm_host"] as? String,
              let rawPort = dictionary["pcm_port"] as? Int,
              (1024...65535).contains(rawPort),
              let encoded = dictionary["pcm_secret"] as? String else { return nil }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4,
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) else { return nil }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let secret = Data(base64Encoded: padded), secret.count >= 32 else { return nil }
        self.host = host
        port = UInt16(rawPort)
        self.secret = secret
    }
}

enum WatchCallMedia: Equatable, Sendable {
    case cloud(URL)
    case local(WatchLocalPCMEndpoint)
    /// APNs does not carry the paired VoWLAN secret; fetch it from the paired iPhone on answer.
    case pendingLocal
}

/// Watch 直接接听所需的完整 VoIP 会话。媒体密钥只保存在内存中，
/// 不进入 WatchConnectivity 状态镜像或通知正文。
struct WatchVoIPCall: Equatable, Sendable {
    let callID: String
    let uuid: UUID
    let number: String?
    let callerName: String?
    let expiresAt: Date?
    let media: WatchCallMedia
    let isOutgoing: Bool

    var authenticatedMediaURL: URL? {
        if case let .cloud(url) = media { return url }
        return nil
    }

    var displayName: String { callerName ?? number ?? "AirSIM" }

    init(userInfo: [AnyHashable: Any], now: Date = Date()) throws {
        guard userInfo["event"] as? String == "incoming_call" else {
            throw WatchVoIPPayloadError.unsupportedEvent
        }
        guard let callID = Self.nonEmpty(userInfo["call_id"] as? String) else {
            throw WatchVoIPPayloadError.missingCallID
        }
        guard let rawUUID = userInfo["call_uuid"] as? String,
              let uuid = UUID(uuidString: rawUUID) else {
            throw WatchVoIPPayloadError.invalidCallUUID
        }
        let expiresAt = Self.date(from: userInfo["expires_at"])
        if let expiresAt, expiresAt <= now { throw WatchVoIPPayloadError.expired }
        let media: WatchCallMedia
        if userInfo["media_route"] as? String == "vowlan" {
            let dictionary = Dictionary(uniqueKeysWithValues: userInfo.compactMap { key, value in
                (key as? String).map { ($0, value) }
            })
            guard let endpoint = WatchLocalPCMEndpoint(dictionary: dictionary) else {
                throw WatchVoIPPayloadError.invalidLocalMedia
            }
            media = .local(endpoint)
        } else if userInfo["call_secret"] != nil || userInfo["media_url"] != nil {
            guard let secret = Self.nonEmpty(userInfo["call_secret"] as? String),
                  secret.count >= 24 else { throw WatchVoIPPayloadError.missingSecret }
            guard let rawMediaURL = Self.nonEmpty(userInfo["media_url"] as? String),
                  var components = URLComponents(string: rawMediaURL),
                  components.scheme?.lowercased() == "wss",
                  components.host?.isEmpty == false else {
                throw WatchVoIPPayloadError.invalidMediaURL
            }
            components.queryItems = [
                URLQueryItem(name: "role", value: "watch"),
                URLQueryItem(name: "token", value: secret),
            ]
            guard let url = components.url else { throw WatchVoIPPayloadError.invalidMediaURL }
            media = .cloud(url)
        } else {
            media = .pendingLocal
        }
        self.callID = callID
        self.uuid = uuid
        number = Self.nonEmpty(userInfo["number"] as? String)
        callerName = Self.nonEmpty(userInfo["caller_name"] as? String)
        self.expiresAt = expiresAt
        self.media = media
        isOutgoing = false
    }

    init(outgoingReply: [String: Any]) throws {
        guard outgoingReply["media_route"] as? String == "vowlan"
                || outgoingReply["call_secret"] != nil else {
            throw WatchVoIPPayloadError.missingSecret
        }
        var payload: [AnyHashable: Any] = outgoingReply
        payload["event"] = "incoming_call"
        let parsed = try WatchVoIPCall(userInfo: payload)
        self = WatchVoIPCall(
            callID: parsed.callID,
            uuid: parsed.uuid,
            number: parsed.number,
            callerName: parsed.callerName,
            expiresAt: parsed.expiresAt,
            media: parsed.media,
            isOutgoing: true
        )
    }

    func usingLocalMedia(_ endpoint: WatchLocalPCMEndpoint) -> WatchVoIPCall {
        WatchVoIPCall(
            callID: callID, uuid: uuid, number: number, callerName: callerName,
            expiresAt: expiresAt, media: .local(endpoint), isOutgoing: isOutgoing
        )
    }

    private init(
        callID: String, uuid: UUID, number: String?, callerName: String?,
        expiresAt: Date?, media: WatchCallMedia, isOutgoing: Bool
    ) {
        self.callID = callID
        self.uuid = uuid
        self.number = number
        self.callerName = callerName
        self.expiresAt = expiresAt
        self.media = media
        self.isOutgoing = isOutgoing
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func date(from value: Any?) -> Date? {
        if let value = value as? TimeInterval { return Date(timeIntervalSince1970: value) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum WatchDialNumber {
    static func validated(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        guard !value.isEmpty, value.count <= 82,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }
}

struct WatchIncomingNotificationPlan: Equatable, Sendable {
    static let maximumDeliveryAge: TimeInterval = 45

    let identifier: String
    let title: String
    let body: String

    init?(payload: WatchCallPayload, now: Date = Date()) {
        guard payload.phase == .incoming, !payload.callID.isEmpty else { return nil }
        let age = now.timeIntervalSince(payload.updatedAt)
        guard age >= -5, age <= Self.maximumDeliveryAge else { return nil }
        let name = payload.callerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = payload.number?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [name, number]
            .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        identifier = "djonehub.watch.incoming.\(payload.callID)"
        title = "AirSIM 来电"
        body = parts.isEmpty ? "模块收到来电" : parts.joined(separator: " · ")
    }
}
