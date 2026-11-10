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
    let aliases: [String]
    let phase: WatchCallPhase
    let number: String?
    let callerName: String?
    let transport: String?
    let updatedAt: Date

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "event": "watch_call_state",
            "call_id": callID,
            "call_uuid": callUUID?.uuidString ?? "",
            "phase": phase.rawValue,
            "updated_at": updatedAt.timeIntervalSince1970,
        ]
        if !aliases.isEmpty { value["call_aliases"] = aliases }
        if let number, !number.isEmpty { value["number"] = number }
        if let callerName, !callerName.isEmpty { value["caller_name"] = callerName }
        if let transport, !transport.isEmpty { value["transport"] = transport }
        return value
    }

    init(
        callID: String,
        callUUID: UUID?,
        aliases: [String] = [],
        phase: WatchCallPhase,
        number: String?,
        callerName: String?,
        transport: String? = nil,
        updatedAt: Date
    ) {
        self.callID = callID
        self.callUUID = callUUID
        self.aliases = aliases.filter { !$0.isEmpty && $0 != callID }
        self.phase = phase
        self.number = number
        self.callerName = callerName
        self.transport = transport
        self.updatedAt = updatedAt
    }

    /// Identity and presentation fields, excluding the timestamp used only for
    /// stale/ordering checks. Re-publishing the same state must not create a new
    /// WatchConnectivity transfer on every update.
    func isSamePresentation(as other: WatchCallPayload) -> Bool {
        callID == other.callID
            && callUUID == other.callUUID
            && aliases == other.aliases
            && phase == other.phase
            && number == other.number
            && callerName == other.callerName
            && transport == other.transport
    }

    func matches(callID: String?, callUUID: UUID?) -> Bool {
        let idMatches = callID.map { $0 == self.callID || aliases.contains($0) } ?? false
        if let expectedUUID = self.callUUID, let candidateUUID = callUUID {
            return expectedUUID == candidateUUID
        }
        return idMatches || callUUID != nil && callUUID == self.callUUID
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["event"] as? String == "watch_call_state",
              let phaseValue = dictionary["phase"] as? String,
              let phase = WatchCallPhase(rawValue: phaseValue),
              let updatedAt = dictionary["updated_at"] as? TimeInterval else { return nil }
        let callID = dictionary["call_id"] as? String ?? ""
        let aliases = dictionary["call_aliases"] as? [String] ?? []
        let uuidValue = dictionary["call_uuid"] as? String
        self.init(
            callID: callID,
            callUUID: uuidValue.flatMap(UUID.init(uuidString:)),
            aliases: aliases,
            phase: phase,
            number: dictionary["number"] as? String,
            callerName: dictionary["caller_name"] as? String,
            transport: dictionary["transport"] as? String,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
enum WatchCallMirrorPolicy {
    static func identityKeys(for payload: WatchCallPayload) -> Set<String> {
        var keys = Set(payload.aliases.filter { !$0.isEmpty })
        if !payload.callID.isEmpty { keys.insert(payload.callID) }
        if let callUUID = payload.callUUID {
            keys.insert("uuid:\(callUUID.uuidString.lowercased())")
        }
        return keys
    }

    static func isTombstoned(
        _ payload: WatchCallPayload, endedCallIDs: Set<String>, endedCallUUIDs: Set<UUID>
    ) -> Bool {
        !endedCallIDs.isDisjoint(with: Set([payload.callID] + payload.aliases))
            || payload.callUUID.map(endedCallUUIDs.contains) == true
    }

    static func isNewer(_ payload: WatchCallPayload, than timestamp: Date?) -> Bool {
        guard let timestamp else { return true }
        return payload.updatedAt >= timestamp
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

/// ASCII DNS names only; TLS always uses system certificate and hostname validation.
/// Literal IPs, URLs, paths and numeric host aliases are deliberately excluded.
enum RemoteDirectHost {
    static func isValid(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.count > 1,
              let first = labels.last?.first, first.isASCII && first.isLetter else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

struct WatchLocalPCMEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16
    let secret: Data
    let usesTLS: Bool

    init?(dictionary: [String: Any]) {
        guard let host = dictionary["pcm_host"] as? String,
              let rawPort = dictionary["pcm_port"] as? Int,
              (1...65535).contains(rawPort),
              let encoded = dictionary["pcm_secret"] as? String else { return nil }
        if let flag = dictionary["pcm_tls"], !(flag is Bool) { return nil }
        let usesTLS = dictionary["pcm_tls"] as? Bool ?? false
        if usesTLS {
            guard RemoteDirectHost.isValid(host) else { return nil }
        } else {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            let octets = parts.compactMap { UInt8($0) }
            guard rawPort >= 1024, octets.count == 4, parts.count == 4,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                  octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                    || (octets[0] == 192 && octets[1] == 168) else { return nil }
        }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let secret = Data(base64Encoded: padded), secret.count >= 32 else { return nil }
        self.host = host
        port = UInt16(rawPort)
        self.secret = secret
        self.usesTLS = usesTLS
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
    let agentID: String?
    let generation: UInt64
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

    func controlMessage(action: String) -> [String: Any] {
        var value: [String: Any] = ["action": action, "call_id": callID,
            "call_uuid": uuid.uuidString.lowercased(), "generation": generation]
        if let agentID { value["agent_id"] = agentID }
        return value
    }

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
        agentID = userInfo["agent_id"] as? String
        generation = max(1, (userInfo["generation"] as? NSNumber)?.uint64Value
            ?? (userInfo["generation"] as? String).flatMap(UInt64.init) ?? 1)
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
            isOutgoing: true, agentID: parsed.agentID, generation: parsed.generation
        )
    }

    func usingLocalMedia(_ endpoint: WatchLocalPCMEndpoint) -> WatchVoIPCall {
        WatchVoIPCall(
            callID: callID, uuid: uuid, number: number, callerName: callerName,
            expiresAt: expiresAt, media: .local(endpoint), isOutgoing: isOutgoing,
            agentID: agentID, generation: generation
        )
    }

    private init(
        callID: String, uuid: UUID, number: String?, callerName: String?,
        expiresAt: Date?, media: WatchCallMedia, isOutgoing: Bool, agentID: String?, generation: UInt64
    ) {
        self.callID = callID
        self.uuid = uuid
        self.number = number
        self.callerName = callerName
        self.expiresAt = expiresAt
        self.media = media
        self.isOutgoing = isOutgoing
        self.agentID = agentID
        self.generation = generation
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
        identifier = "airsim.watch.incoming.\(payload.callID)"
        title = "AirSIM 来电"
        body = parts.isEmpty ? "模块收到来电" : parts.joined(separator: " · ")
    }
}

// Watch SMS uses the paired companion channel, never forwards SMS encryption keys.
struct WatchSMSDevice: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}
struct WatchSMSRow: Codable, Equatable, Identifiable {
    let id: String
    let agentID: String
    let sender: String
    let preview: String
    let timestamp: Date
    let sim: String?
    let outgoing: Bool
    let unread: Bool
}
struct WatchSMSPage: Codable, Equatable {
    let devices: [WatchSMSDevice]
    let selectedAgentID: String?
    var rows: [WatchSMSRow]
    let total: Int
    let generatedAt: Date
}
struct WatchSMSDetail: Codable, Equatable {
    let row: WatchSMSRow
    let body: String
    let truncated: Bool
}
enum WatchSMSPolicy {
    static let payloadBudget = 28_000
    static func selected(requested: String?, current: String?, paired: [String]) -> String? {
        if let requested { return paired.contains(requested) ? requested : nil }
        if let current, paired.contains(current) { return current }
        return paired.count == 1 ? paired.first : nil
    }
    static func permits(sourceAgentID: String?, selectedAgentID: String?, pairedIDs: [String]) -> Bool {
        guard let sourceAgentID, let selectedAgentID else { return false }
        return sourceAgentID == selectedAgentID && pairedIDs.contains(sourceAgentID)
    }
    static func prefix(_ text: String, utf8Limit: Int) -> String {
        guard utf8Limit > 0 else { return "" }
        var count = 0
        return String(text.prefix { character in
            let bytes = String(character).utf8.count
            guard count + bytes <= utf8Limit else { return false }
            count += bytes
            return true
        })
    }
    static func boundedDetail(row: WatchSMSRow, body: String) throws -> WatchSMSDetail {
        var limit = 20_000
        while true {
            let text = prefix(body, utf8Limit: limit)
            let detail = WatchSMSDetail(row: row, body: text, truncated: text != body)
            if try JSONEncoder().encode(detail).count <= payloadBudget { return detail }
            guard limit > 0 else { throw NSError(domain: "WatchSMSPayload", code: 1) }
            limit /= 2
        }
    }
    static func matches(_ row: WatchSMSRow, agentID: String, id: String) -> Bool {
        row.agentID == agentID && row.id == id
    }
}

/// DTMF is a scoped command to the connected Android call, never microphone audio.
enum WatchDTMFPolicy {
    static func validDigit(_ digit: String) -> Bool {
        digit.utf8.count == 1 && "0123456789*#".contains(digit)
    }
    static func canSend(phase: String?, backendID: String?, expectedID: String) -> Bool {
        phase == "active" && backendID == expectedID && !expectedID.isEmpty
    }
}

extension WatchCallMirrorPolicy {
    /// An active iPhone-owned call may already be tombstoned against late
    /// incoming pushes; its matching terminal mirror must still clear display.
    static func acceptsTerminalForDisplay(_ incoming: WatchCallPayload, current: WatchCallPayload) -> Bool {
        incoming.phase == .ended && incoming.matches(callID: current.callID, callUUID: current.callUUID)
    }
}

struct WatchSMSConversation: Identifiable, Equatable {
    let id: String
    let agentID: String
    let peer: String
    let rows: [WatchSMSRow]
    var latest: WatchSMSRow { rows[rows.count - 1] }
    var unreadCount: Int { rows.filter { !$0.outgoing && $0.unread }.count }
}

enum WatchSMSConversationPolicy {
    static func peer(_ sender: String) -> String {
        let raw = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.\t")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "text:" + raw }
        var digits = raw.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return "text:" + raw }
        let international = raw.hasPrefix("+") || digits.hasPrefix("00")
        if digits.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
        if international {
            if digits.hasPrefix("86"), digits.count > 2 { return "number:" + digits.dropFirst(2) }
            return "international:" + digits
        }
        if digits.count == 13, digits.hasPrefix("861") { digits = String(digits.dropFirst(2)) }
        return "number:" + digits
    }
    static func groups(_ rows: [WatchSMSRow]) -> [WatchSMSConversation] {
        let grouped = Dictionary(grouping: rows) { row in
            let value = peer(row.sender)
            return Data(row.agentID.utf8).base64EncodedString() + "." + Data((value.isEmpty ? "unknown:" + row.id : value).utf8).base64EncodedString()
        }
        return grouped.map { id, values in
            let sorted = values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
            return WatchSMSConversation(id: id, agentID: sorted[0].agentID, peer: peer(sorted[0].sender), rows: sorted)
        }.sorted { $0.latest.timestamp == $1.latest.timestamp ? $0.id < $1.id : $0.latest.timestamp > $1.latest.timestamp }
    }
}


struct WatchSMSReplyOptions: Codable {
    struct Slot: Codable, Identifiable {
        let id: String
        let label: String
        let carrier: String?
    }
    let recipient: String
    let slots: [Slot]
    let selectedID: String?
}

enum WatchSMSReplyOutcome {
    case sent
    case failed(String)
    case uncertain
}

extension WatchSMSConversationPolicy {
    static func replyNumber(_ sender: String) -> String? {
        let raw = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.\t")
        guard raw.unicodeScalars.allSatisfy(allowed.contains),
              !raw.dropFirst().contains("+") else { return nil }
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard (1...30).contains(digits.count) else { return nil }
        return raw.hasPrefix("+") ? "+" + digits : digits
    }
}
