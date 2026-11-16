import Foundation
import CryptoKit

// MARK: - 通话与短信

/// 模块侧返回的单次通话记录。
struct CallRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let index: Int
    let direction: String
    let state: String
    let number: String?
    let startedAt: Date
    let updatedAt: Date
    let endedAt: Date?
    var missed: Bool
    var connectedAt: Date? = nil
    var androidID: String? = nil
    var sourceAgentID: String? = nil
    var sourceCallID: String? = nil
    var historyEstimated: Bool? = nil
    var slotIndex: Int? = nil
    var slotID: Int? = nil
    var connectedDuration: TimeInterval? {
        guard !missed, let connectedAt, let endedAt, endedAt.timeIntervalSinceReferenceDate >= connectedAt.timeIntervalSinceReferenceDate else { return nil }
        return endedAt.timeIntervalSince(connectedAt)
    }
    var isTerminal: Bool { endedAt != nil || state == "ended" || state == "failed" }

    enum CodingKeys: String, CodingKey {
        case id, index, direction, state, number, missed
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
        case connectedAt = "connected_at"
        case androidID = "android_id"
        case sourceAgentID = "source_agent_id", sourceCallID = "source_call_id"
        case historyEstimated = "history_estimated"
        case slotIndex = "slot_index", slotID = "slot_id"
    }
    // Merge history facts only. Missing legacy connected_at is not evidence
    // that every incoming call was missed; retain an already observed outcome.
    func preservingHistoryEvidence(from previous: CallRecord) -> CallRecord {
        guard id == previous.id, sourceAgentID == previous.sourceAgentID else { return self }
        var result = self
        if result.connectedAt == nil { result.connectedAt = previous.connectedAt }
        if result.slotIndex == nil { result.slotIndex = previous.slotIndex }
        if result.slotID == nil { result.slotID = previous.slotID }
        if result.direction == "incoming", result.isTerminal {
            if result.connectedAt != nil { result.missed = false }
            else if previous.missed { result.missed = true }
        }
        return result
    }
    func scopedHistory(to agentID: String) -> CallRecord {
        var copy = CallRecord(id: "agent-call:\(Data(agentID.utf8).base64EncodedString()):\(Data((androidID ?? id).utf8).base64EncodedString())",
            index: index, direction: direction, state: state, number: number, startedAt: startedAt,
            updatedAt: updatedAt, endedAt: endedAt, missed: missed, androidID: androidID)
        copy.connectedAt = connectedAt
        copy.slotIndex = slotIndex; copy.slotID = slotID
        copy.sourceAgentID = agentID; copy.sourceCallID = id; copy.historyEstimated = historyEstimated
        return copy
    }
}

/// 通话轮询结果；额外音频诊断字段由专门接口读取。
struct CallStatus: Codable, Sendable {
    let active: CallRecord?
    let history: [CallRecord]?
    let polling: Bool
    let eventDriven: Bool?
    let pollIntervalSeconds: Int
    let lastPollError: String
    let revision: UInt64?

    enum CodingKeys: String, CodingKey {
        case active, history, polling
        case eventDriven = "event_driven"
        case pollIntervalSeconds = "poll_interval_s"
        case lastPollError = "last_poll_error"
        case revision
    }
}

/// Agent 的统一事件快照；通话和短信共用一个长轮询，避免后台保持两套本地请求。
struct AgentEventStatus: Codable, Sendable {
    let revision: UInt64
    let smsRevision: UInt64
    let smsPending: Int
    let call: CallStatus
    let simRevision: UInt64?
    let simSlots: [AndroidSIMSlot]?

    enum CodingKeys: String, CodingKey {
        case revision, call
        case smsRevision = "sms_revision"
        case smsPending = "sms_pending"
        case simRevision = "sim_revision"
        case simSlots = "sim_slots"
    }
}

struct AgentHealth: Codable, Sendable {
    let ok: Bool
    let version: String
    let controlPlane: String?
    let cellularState: String?
    let cellularRegistration: String?
    let cellularRecovery: String?

    enum CodingKeys: String, CodingKey {
        case ok, version
        case controlPlane = "control_plane"
        case cellularState = "cellular_state"
        case cellularRegistration = "cellular_registration"
        case cellularRecovery = "cellular_recovery"
    }
}

/// Relay 最近一次收到的 Agent 心跳。该对象只包含可展示状态，不包含设备密钥。
struct CloudAndroidAgent: Codable, Equatable, Sendable, Identifiable {
    var simSlots: [AndroidSIMSlot]? = nil
    var battery: AndroidBatteryReading? = nil
    var commandRoutingVersion: Int? = nil
    let agentID: String
    let agentKind: String?
    let deviceName: String?
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?
    let agentVersion: String?
    let cloudOnline: Bool

    var id: String { agentID }

    enum CodingKeys: String, CodingKey {
        case battery
        case simSlots = "sim_slots"
        case agentID = "agent_id"
        case agentKind = "agent_kind"
        case deviceName = "device_name"
        case manufacturer, model
        case phoneNumber = "phone_number"
        case agentVersion = "agent_version"
        case cloudOnline = "cloud_online"
        case commandRoutingVersion = "command_routing_version"
    }
}

struct CloudAgentStatus: Decodable, Equatable, Sendable {
    let commandRoutingVersion: Int?
    let cloudOnline: Bool
    let agentVersion: String?
    let atOK: Bool?
    let cellularState: String?
    let cellularRegistration: String?
    let cellularRecovery: String?
    let signalDBM: Int?
    let activeAgentID: String?
    let agents: [CloudAndroidAgent]

    enum CodingKeys: String, CodingKey {
        case cloudOnline = "cloud_online"
        case agentVersion = "agent_version"
        case atOK = "at_ok"
        case cellularState = "cellular_state"
        case cellularRegistration = "cellular_registration"
        case cellularRecovery = "cellular_recovery"
        case signalDBM = "signal_dbm"
        case activeAgentID = "active_agent_id"
        case agents
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commandRoutingVersion = try values.decodeIfPresent([String: Int].self, forKey: .capabilities)?["agent_command_routing"]
        cloudOnline = try values.decode(Bool.self, forKey: .cloudOnline)
        agentVersion = try values.decodeIfPresent(String.self, forKey: .agentVersion)
        atOK = try values.decodeIfPresent(Bool.self, forKey: .atOK)
        cellularState = try values.decodeIfPresent(String.self, forKey: .cellularState)
        cellularRegistration = try values.decodeIfPresent(String.self, forKey: .cellularRegistration)
        cellularRecovery = try values.decodeIfPresent(String.self, forKey: .cellularRecovery)
        signalDBM = try values.decodeIfPresent(Int.self, forKey: .signalDBM)
        activeAgentID = try values.decodeIfPresent(String.self, forKey: .activeAgentID)
        agents = try values.decodeIfPresent([CloudAndroidAgent].self, forKey: .agents) ?? []
    }
}

/// One call-capable SIM/PhoneAccount reported by the paired Android.
/// The identifier is an opaque Telecom handle; the number is display-only.
struct AndroidSIMSlot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let number: String?
    let isDefault: Bool?
    let slotIndex: Int?
    let subID: Int?
    let carrierName: String?
    let isEmbedded: Bool?
    let isDefaultVoice: Bool?
    let isDefaultSMS: Bool?
    enum CodingKeys: String, CodingKey {
        case id, label, number
        case isDefault = "default"
        case slotIndex = "slot_index"
        case subID = "sub_id"
        case carrierName = "carrier_name"
        case isEmbedded = "is_embedded"
        case isDefaultVoice = "is_default_voice"
        case isDefaultSMS = "is_default_sms"
    }
    var displayNumber: String? {
        let value = number?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
    var displayName: String {
        guard let value = displayNumber else { return label }
        return "\(label) · \(value)"
    }
    var detail: String? {
        var values: [String] = []
        if isEmbedded == true, !label.localizedCaseInsensitiveContains("eSIM") {
            values.append("eSIM")
        }
        if let carrierName = carrierName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !carrierName.isEmpty, !label.localizedCaseInsensitiveContains(carrierName) {
            values.append(carrierName)
        }
        if isDefaultVoice == true { values.append("默认语音") }
        if isDefaultSMS == true { values.append("默认短信") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}

struct AndroidAgentMetadata: Decodable, Equatable, Sendable {
    var battery: AndroidBatteryReading? = nil
    let agentID: String
    let deviceName: String
    let phoneNumber: String?
    let agentKind: String?
    let callGeneration: UInt64?
    let simSlots: [AndroidSIMSlot]?
    init(agentID: String, deviceName: String, phoneNumber: String?, agentKind: String?,
         callGeneration: UInt64? = nil, simSlots: [AndroidSIMSlot]? = nil, battery: AndroidBatteryReading? = nil) {
        self.agentID = agentID; self.deviceName = deviceName; self.phoneNumber = phoneNumber
        self.agentKind = agentKind; self.callGeneration = callGeneration; self.simSlots = simSlots
        self.battery = battery
    }
    enum CodingKeys: String, CodingKey {
        case battery
        case agentID = "agent_id", deviceName = "device_name"
        case phoneNumber = "phone_number", agentKind = "agent_kind"
        case callGeneration = "call_generation"
        case simSlots = "sim_slots"
    }
    static func decode(_ data: Data, expectedID: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.agentID == expectedID else { throw VoBLECentralError.invalidResponse }
        let number = value.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(agentID: value.agentID, deviceName: value.deviceName,
                    phoneNumber: number?.isEmpty == false ? number : nil, agentKind: value.agentKind,
                    callGeneration: value.callGeneration, simSlots: value.simSlots ?? [], battery: value.battery)
    }
}

struct AndroidAgentPresentation: Equatable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let phoneNumber: String?
    let agentKind: String?
    let cloudOnline: Bool
    let vowlanOnline: Bool
    let bluetoothOnline: Bool
    let isCurrent: Bool

    init(
        id: String,
        deviceName: String,
        phoneNumber: String?,
        agentKind: String?,
        cloudOnline: Bool,
        vowlanOnline: Bool,
        bluetoothOnline: Bool = false,
        isCurrent: Bool
    ) {
        self.id = id
        self.deviceName = deviceName
        self.phoneNumber = phoneNumber
        self.agentKind = agentKind
        self.cloudOnline = cloudOnline
        self.vowlanOnline = vowlanOnline
        self.bluetoothOnline = bluetoothOnline
        self.isCurrent = isCurrent
    }

    var agentKindTitle: String {
        switch agentKind {
        case "standalone": return "Standalone"
        case "avf": return "AVF Agent"
        default: return "Android Agent"
        }
    }
}

enum AndroidAgentCycle {
    /// Stable round-robin over every paired Agent, independent of the
    /// current-first presentation order. Returns nil when there is nothing to
    /// switch to.
    static func nextID(
        in agents: [AndroidAgentPresentation],
        currentID: String?
    ) -> String? {
        guard agents.count > 1 else { return nil }
        let ordered = agents.sorted { $0.id < $1.id }
        let currentIndex = ordered.firstIndex { $0.id == currentID }
        let nextIndex = currentIndex.map { ($0 + 1) % ordered.count } ?? 0
        return ordered[nextIndex].id
    }
}

enum ModuleConnectionSummary: Equatable, Sendable {
    case localOnline
    case localOnlineNoService
    case cloudOnly
    case offline
}

enum ModuleConnectionPolicy {
    static func summary(
        localControlReachable: Bool,
        cloudHeartbeatFresh: Bool,
        cellularState: String?
    ) -> ModuleConnectionSummary {
        if localControlReachable {
            return ["searching", "denied", "unregistered"].contains(cellularState ?? "")
                ? .localOnlineNoService : .localOnline
        }
        return cloudHeartbeatFresh ? .cloudOnly : .offline
    }
}

enum SMSDirection: String, Codable, Equatable, Sendable {
    case incoming
    case outgoing
}

struct SMSMessage: Codable, Equatable, Sendable, Identifiable {
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date
    /// 模块交付队列的稳定标识；也用于推送与本地同步之间的去重。
    var deliveryID: String?
    /// 旧模块没有方向字段，缺省按收到的短信展示；发送成功后由 App 标记为 outgoing。
    var direction: SMSDirection? = nil
    /// Known authenticated producer. Legacy records remain explicitly unscoped.
    var sourceAgentID: String? = nil
    /// Android subscription slot label ("SIM 1"/"SIM 2"); absent on legacy records.
    var simSlot: String? = nil

    var isOutgoing: Bool { direction == .outgoing }

    var simDeliveryLabel: String {
        let line = simSlot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(isOutgoing ? "通过" : "接收于") \(line.isEmpty ? "SIM 未知" : line)"
    }

    /// 新版 Agent 用 delivery_id 对齐 APNs 与本地同步；旧版仍回退到内容指纹。
    var id: String {
        if let deliveryID, !deliveryID.isEmpty { return scopedIdentity("delivery:\(deliveryID)") }
        return scopedIdentity("\(sender)\u{0}\(timestamp.timeIntervalSince1970)\u{0}\(content)\u{0}\(direction?.rawValue ?? SMSDirection.incoming.rawValue)")
    }

    func scopedIdentity(_ value: String) -> String {
        guard let sourceAgentID, !sourceAgentID.isEmpty else { return value }
        return "source:\(sourceAgentID.utf8.count):\(sourceAgentID)\u{0}\(value)"
    }

    enum CodingKeys: String, CodingKey {
        case sender, content, code, timestamp, direction
        case deliveryID = "delivery_id"
        case sourceAgentID = "source_agent_id"
        case simSlot = "sim_slot"
    }
}

enum SMSHistoryPolicy {
    /// Legacy IDs contain subsecond Date values, while old ISO8601 files persist whole seconds.
    /// Prefer authoritative delivery IDs without multiplying the same legacy record on each save.
    static func deduplicated(_ records: [SMSMessage]) -> [SMSMessage] {
        func legacyKey(_ message: SMSMessage) -> String {
            message.scopedIdentity("\(message.sender)\u{0}\(Int64(message.timestamp.timeIntervalSince1970.rounded(.down)))\u{0}\(message.content)\u{0}\(message.direction?.rawValue ?? "incoming")")
        }
        func preservingSIMLine(_ incoming: SMSMessage, _ existing: SMSMessage?) -> SMSMessage {
            var merged = incoming
            let incomingLine = incoming.simSlot?.trimmingCharacters(in: .whitespacesAndNewlines)
            if incomingLine?.isEmpty != false,
               let existingLine = existing?.simSlot?.trimmingCharacters(in: .whitespacesAndNewlines),
               !existingLine.isEmpty {
                // APNs may omit a unique line label; do not erase the Agent copy's label.
                merged.simSlot = existingLine
            }
            return merged
        }
        let authoritativeLegacyKeys = Set(records.filter { $0.deliveryID?.isEmpty == false }.map(legacyKey))
        var byID: [String: SMSMessage] = [:]
        for message in records {
            let legacy = legacyKey(message)
            if message.deliveryID?.isEmpty != false {
                if authoritativeLegacyKeys.contains(legacy) { continue }
                byID["legacy:" + legacy] = message
            } else {
                byID[message.id] = preservingSIMLine(message, byID[message.id])
            }
        }
        return Array(byID.values)
    }

    static func appendingSentMessage(
        recipient: String,
        content: String,
        at timestamp: Date,
        to messages: [SMSMessage],
        limit: Int,
        sourceAgentID: String? = nil,
        simSlot: String? = nil
    ) -> [SMSMessage] {
        let sentMessage = SMSMessage(
            sender: recipient,
            content: content,
            code: nil,
            timestamp: timestamp,
            deliveryID: nil,
            direction: .outgoing,
            sourceAgentID: sourceAgentID,
            simSlot: simSlot
        )
        return Array((messages + [sentMessage])
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(max(0, limit)))
    }
}

/// A stable directory observation, independent of the selected device.
struct SMSIdentitySnapshot: Equatable {
    let knownAgentIDs: Set<String>
    let hasForgottenDevices: Bool
    let revision: String
    let valid: Bool
    var uniqueAgentID: String? {
        guard valid, !hasForgottenDevices, knownAgentIDs.count == 1 else { return nil }
        return knownAgentIDs.first
    }
    func legacySource(comparedTo current: Self) -> String? {
        self == current ? current.uniqueAgentID : nil
    }
}

struct SMSStatus: Codable, Sendable {
    let autoCleanupME: Bool
    let count: Int?
    let lastPollError: String?

    enum CodingKeys: String, CodingKey {
        case count
        case autoCleanupME = "auto_cleanup_me"
        case lastPollError = "last_poll_error"
    }
}

struct RejectResponse: Codable, Sendable { let rejected: Bool }
struct SMSSendResult: Codable, Sendable {
    let sent: Bool
    let segments: Int?

    init(sent: Bool, segments: Int?) {
        self.sent = sent
        self.segments = segments
    }
}

struct RelayErrorResponse: Decodable, Sendable { let error: String }
struct CallRecordingResponse: Codable, Sendable { let recording: Bool; let path: String? }
struct SIMIdentity: Codable, Sendable {
    let phoneNumber: String
    enum CodingKeys: String, CodingKey { case phoneNumber = "phone_number" }
}

// MARK: - 模块、网络与定位

struct ModemStatus: Codable, Equatable, Sendable {
    let imei: String?
    let firmware: String?
    let iccid: String?
    let imsi: String?
    let operatorName: String?
    let simInserted: Bool?
    let signalDBM: Int?
    let networkMode: String?
    let radioBand: String?
    let registrationText: String?
    let cellularState: String?
    let cellularRecovery: String?
    let lastRegisteredAt: Date?

    enum CodingKeys: String, CodingKey {
        case imei, firmware, iccid, imsi
        case operatorName = "operator"
        case simInserted = "sim_inserted"
        case signalDBM = "signal_dbm"
        case networkMode = "network_mode"
        case radioBand = "radio_band"
        case registrationText = "reg_status_text"
        case cellularState = "cellular_state"
        case cellularRecovery = "cellular_recovery"
        case lastRegisteredAt = "last_registered_at"
    }
}

struct NetworkTrafficSnapshot: Codable, Sendable {
    let available: Bool
    let interface: String?
    let rxBytes: UInt64
    let txBytes: UInt64
    let sessionRX: UInt64
    let sessionTX: UInt64
    let sessionTotal: UInt64
    let sampledAtMS: Int64
    let error: String?

    enum CodingKeys: String, CodingKey {
        case available, interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case sessionRX = "session_rx_bytes"
        case sessionTX = "session_tx_bytes"
        case sessionTotal = "session_total_bytes"
        case sampledAtMS = "sampled_at_ms"
    }
}

/// Agent 从模块只读 sysfs 接口采样的电源与温度数据。
struct SystemPowerStatus: Codable, Sendable {
    let supported: Bool
    let readings: [SystemPowerReading]
    let sampledAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case supported, readings
        case sampledAtMS = "sampled_at_ms"
    }
}

struct SystemPowerReading: Codable, Sendable, Identifiable {
    let kind: String
    let name: String
    let path: String
    let voltageV: Double?
    let currentA: Double?
    let powerW: Double?
    let temperatureC: Double?
    let capacityPercent: Int?
    let online: Bool?
    let status: String?

    var id: String { "\(kind):\(path)" }

    enum CodingKeys: String, CodingKey {
        case kind, name, path, online, status
        case voltageV = "voltage_v"
        case currentA = "current_a"
        case powerW = "power_w"
        case temperatureC = "temperature_c"
        case capacityPercent = "capacity_percent"
    }
}

struct CellularPolicyStatus: Codable, Sendable {
    let forceOff: Bool
    let services: [String]?
    enum CodingKeys: String, CodingKey { case forceOff = "force_off"; case services }
}

// MARK: - WRT Lite 路由与流量控制

struct RouterConfig: Codable, Equatable, Sendable {
    var internetAccess: Bool
    var natEnabled: Bool
    var monthlyQuotaBytes: UInt64
    var blockWhenQuotaExceeded: Bool
    var quotaResetDay: Int
    var downloadLimitKbps: Int
    var uploadLimitKbps: Int
    var schedules: [RouterSchedule]?
    var portForwards: [RouterPortForward]?
    var dnsOverrides: [RouterDNSOverride]?

    enum CodingKeys: String, CodingKey {
        case internetAccess = "internet_access"
        case natEnabled = "nat_enabled"
        case monthlyQuotaBytes = "monthly_quota_bytes"
        case blockWhenQuotaExceeded = "block_when_quota_exceeded"
        case quotaResetDay = "quota_reset_day"
        case downloadLimitKbps = "download_limit_kbps"
        case uploadLimitKbps = "upload_limit_kbps"
        case schedules
        case portForwards = "port_forwards"
        case dnsOverrides = "dns_overrides"
    }
}

struct RouterSchedule: Codable, Equatable, Sendable {
    var name: String
    var enabled: Bool
    var weekdays: [Int]
    var start: String
    var end: String
}

struct RouterPortForward: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var enabled: Bool
    var `protocol`: String
    var externalPort: Int
    var internalIP: String
    var internalPort: Int
    var id: String { "\(`protocol`)-\(externalPort)-\(internalIP)-\(internalPort)" }

    enum CodingKeys: String, CodingKey {
        case name, enabled, `protocol`
        case externalPort = "external_port"
        case internalIP = "internal_ip"
        case internalPort = "internal_port"
    }
}

struct RouterDNSOverride: Codable, Equatable, Sendable, Identifiable {
    var hostname: String
    var address: String
    var id: String { hostname }
}

struct RouterUsage: Codable, Equatable, Sendable {
    let period: String
    let usedBytes: UInt64
    let lastRXBytes: UInt64
    let lastTXBytes: UInt64
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case period
        case usedBytes = "used_bytes"
        case lastRXBytes = "last_rx_bytes"
        case lastTXBytes = "last_tx_bytes"
        case updatedAt = "updated_at"
    }
}

struct RouterCapabilities: Codable, Equatable, Sendable {
    let nat: Bool
    let dhcp: Bool
    let dns: Bool
    let trafficAccounting: Bool
    let quotaEnforcement: Bool
    let rateShaping: Bool
    let portForwarding: Bool?
    let dnsOverrides: Bool?
    let schedules: Bool?
    let trafficHistory: Bool?
    let staticDHCP: Bool?
    let vpn: Bool?
    let perClientFirewall: Bool?

    enum CodingKeys: String, CodingKey {
        case nat, dhcp, dns
        case trafficAccounting = "traffic_accounting"
        case quotaEnforcement = "quota_enforcement"
        case rateShaping = "rate_shaping"
        case portForwarding = "port_forwarding"
        case dnsOverrides = "dns_overrides"
        case schedules
        case trafficHistory = "traffic_history"
        case staticDHCP = "static_dhcp"
        case vpn
        case perClientFirewall = "per_client_firewall"
    }
}

struct RouterTrafficDay: Codable, Equatable, Sendable, Identifiable {
    let date: String
    let rxBytes: UInt64
    let txBytes: UInt64
    var id: String { date }
    enum CodingKeys: String, CodingKey {
        case date
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
    }
}

struct RouterTrafficHistory: Codable, Equatable, Sendable {
    let days: [RouterTrafficDay]
}

struct RouterForwardingStatus: Codable, Equatable, Sendable {
    let enabled: Bool
    let reason: String
    let blockLocalAgent: Bool

    enum CodingKeys: String, CodingKey {
        case enabled, reason
        case blockLocalAgent = "block_local_agent"
    }
}

struct RouterSystemStatus: Codable, Equatable, Sendable {
    let ipForward: Bool
    let wanInterface: String
    let lanInterface: String

    enum CodingKeys: String, CodingKey {
        case ipForward = "ip_forward"
        case wanInterface = "wan_interface"
        case lanInterface = "lan_interface"
    }
}

struct RouterStatus: Codable, Equatable, Sendable {
    let mode: String
    let config: RouterConfig
    let usage: RouterUsage
    let capabilities: RouterCapabilities
    let forwarding: RouterForwardingStatus
    let system: RouterSystemStatus?
    let lastError: String?
    let lastAppliedAt: String?
    let trafficHistory: RouterTrafficHistory?

    enum CodingKeys: String, CodingKey {
        case mode, config, usage, capabilities, forwarding, system
        case lastError = "last_error"
        case lastAppliedAt = "last_applied_at"
        case trafficHistory = "traffic_history"
    }
}

struct RouterConfigApplyResponse: Codable, Sendable {
    let config: RouterConfig
    let applied: Bool
    let warning: String?
}

struct RouterInternetResponse: Codable, Sendable {
    let internetAccess: Bool
    enum CodingKeys: String, CodingKey { case internetAccess = "internet_access" }
}

struct RouterRepairResponse: Codable, Sendable {
    let repaired: Bool
}

struct RouterClient: Codable, Identifiable, Sendable {
    let ip: String
    let mac: String?
    let hostname: String?
    let online: Bool
    let leaseRemainingSeconds: Int64?

    var id: String { mac?.isEmpty == false ? mac! : ip }

    enum CodingKeys: String, CodingKey {
        case ip, mac, hostname, online
        case leaseRemainingSeconds = "lease_remaining_seconds"
    }
}

struct RouterClientsResponse: Codable, Sendable {
    let clients: [RouterClient]
}

struct NetworkCheckResult: Codable, Sendable {
    let ok: Bool
    let summary: String?
    let detail: String?
}

struct GPSStatus: Codable, Sendable {
    let enabled: Bool
    let lastFix: GPSFixSummary?
    let lastError: String?
    enum CodingKeys: String, CodingKey {
        case enabled
        case lastFix = "last_fix"
        case lastError = "last_error"
    }
}

struct GPSFixSummary: Codable, Sendable {
    let latitude: String?
    let longitude: String?
    let hdop: String
    let satellites: String
}

struct GPSControlResponse: Codable, Sendable {
    let enabled: Bool
    let lastFix: GPSFixSummary?
    enum CodingKeys: String, CodingKey { case enabled; case lastFix = "last_fix" }
}

struct ATResult: Codable, Sendable { let response: String }

// MARK: - eSIM

struct ESIMOverview: Codable, Sendable {
    let cardType: String?
    let message: String?
    let chipInfo: ESIMChipInfo?
    let profiles: [ESIMProfileGroup]?

    enum CodingKeys: String, CodingKey {
        case message, profiles
        case cardType = "card_type"
        case chipInfo = "chip_info"
    }
}

struct ESIMChipInfo: Codable, Sendable {
    let skuName: String?
    let serialNumber: String?
    let firmware: String?
    let eids: [ESIMEID]?

    enum CodingKeys: String, CodingKey {
        case firmware, eids
        case skuName = "sku_name"
        case serialNumber = "serial_number"
    }
}

struct ESIMEID: Codable, Sendable, Identifiable {
    let eid: String?
    let aid: String?
    let freeNvram: String?
    let firmware: String?
    let specGuess: String?

    var id: String { eid ?? aid ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case eid, aid, firmware
        case freeNvram = "free_nvram"
        case specGuess = "spec_guess"
    }
}

struct ESIMProfileGroup: Codable, Sendable {
    let eid: String?
    let aidHex: String?
    let profiles: [ESIMProfile]?
    enum CodingKeys: String, CodingKey { case eid, profiles; case aidHex = "aid_hex" }
}

struct ESIMProfile: Codable, Sendable, Identifiable {
    let iccid: String?
    let name: String?
    let serviceProviderName: String?
    let state: Int?
    let stateText: String?

    var id: String { iccid ?? name ?? UUID().uuidString }
    var enabled: Bool { state == 1 }
    var displayName: String { name ?? serviceProviderName ?? iccid ?? "未命名 Profile" }

    enum CodingKeys: String, CodingKey {
        case iccid, name, state
        case serviceProviderName = "service_provider_name"
        case stateText = "state_text"
    }
}

struct ESIMHealth: Codable, Sendable {
    let ok: Bool?
    let message: String?
    let activeProfile: ESIMProfile?
    let moduleICCID: String?
    let registration: String?
    let registered: Bool?
    let signalDBM: Int?
    let networkMode: String?

    enum CodingKeys: String, CodingKey {
        case ok, message, registration, registered
        case activeProfile = "active_profile"
        case moduleICCID = "module_iccid"
        case signalDBM = "signal_dbm"
        case networkMode = "network_mode"
    }
}

struct ESIMSwitchResult: Codable, Sendable {
    let switchAccepted: Bool?
    let phase: String?
    let targetICCID: String?
    let recoveryPending: Bool?
    let moduleRebootRequested: Bool?
    let reconnectWaitSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case phase
        case switchAccepted = "switch_accepted"
        case targetICCID = "target_iccid"
        case recoveryPending = "recovery_pending"
        case moduleRebootRequested = "module_reboot_requested"
        case reconnectWaitSeconds = "reconnect_wait_seconds"
    }
}

struct ESIMNote: Codable, Sendable { let label: String?; let phone: String?; let tags: String? }
struct ESIMNotesResponse: Codable, Sendable { let notes: [String: ESIMNote] }
struct ESIMDownloadResult: Codable, Sendable { let message: String? }

struct ESIMPhonebookProbe: Codable, Sendable {
    let storageSupported: Bool?
    let storageSelected: Bool?
    let readSupported: Bool?
    let writeSupported: Bool?
    let storageStatus: String?

    enum CodingKeys: String, CodingKey {
        case storageSupported = "storage_supported"
        case storageSelected = "storage_selected"
        case readSupported = "read_supported"
        case writeSupported = "write_supported"
        case storageStatus = "storage_status"
    }
}

// MARK: - 诊断与语音运行时

struct AgentFeedbackSnapshot: Codable, Sendable {
    let bridgeLog: String?
    let runtimeProfile: String?
    let manufacturer: String?
    let model: String?
    let sdk: Int?
    let appVersion: String?
    let audio: AgentFeedbackAudio?

    enum CodingKeys: String, CodingKey {
        case bridgeLog = "bridge_log"
        case runtimeProfile = "runtime_profile"
        case manufacturer, model, sdk
        case appVersion = "app_version"
        case audio
    }
}

struct AgentFeedbackAudio: Codable, Sendable {
    let telecomState: String?
    let pcmClientClosed: Bool?
    let pcmHealth: String?

    enum CodingKeys: String, CodingKey {
        case telecomState = "telecom_state"
        case pcmClientClosed = "pcm_client_closed"
        case pcmHealth = "pcm_health"
    }
}

struct ModuleDebugSnapshot: Codable, Sendable {
    let debug: ModuleDebugBufferStatus
    let agent: ModuleDebugAgentStatus
    let at: ModuleDebugATStatus
    let traffic: ModuleDebugTrafficStatus
    let modem: ModemStatus
    let calls: ModuleDebugCallStatus
    let sms: ModuleDebugSMSStatus
    let voice: VoiceRuntimeStatus
    let events: [ModuleDebugEvent]
}

struct ModuleDebugBufferStatus: Codable, Sendable {
    let latestSequence: UInt64
    let returnedEvents: Int
    let storedBytes: Int
    let maxEvents: Int
    let maxStoredBytes: Int

    enum CodingKeys: String, CodingKey {
        case latestSequence = "latest_sequence"
        case returnedEvents = "returned_events"
        case storedBytes = "stored_bytes"
        case maxEvents = "max_events"
        case maxStoredBytes = "max_stored_bytes"
    }
}

struct ModuleDebugAgentStatus: Codable, Sendable {
    let version: String
    let uptimeSeconds: Int
    let goroutines: Int
    let heapBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case version, goroutines
        case uptimeSeconds = "uptime_seconds"
        case heapBytes = "heap_bytes"
    }
}

struct ModuleDebugATStatus: Codable, Sendable {
    let device: String
    let lastSuccessAt: String?
    let consecutiveFailures: Int
    let reopenCount: Int

    enum CodingKeys: String, CodingKey {
        case device
        case lastSuccessAt = "last_success_at"
        case consecutiveFailures = "consecutive_failures"
        case reopenCount = "reopen_count"
    }
}

struct ModuleDebugTrafficStatus: Codable, Sendable {
    let interface: String?
    let rxBytes: UInt64?
    let txBytes: UInt64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
    }
}

struct ModuleDebugCallStatus: Codable, Sendable {
    let active: CallRecord?
    let historyCount: Int
    let eventDriven: Bool
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case active
        case historyCount = "history_count"
        case eventDriven = "event_driven"
        case lastError = "last_error"
    }
}

struct ModuleDebugSMSStatus: Codable, Sendable {
    let count: Int
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case count
        case lastError = "last_error"
    }
}

struct ModuleDebugEvent: Codable, Sendable, Identifiable {
    let sequence: UInt64
    let timestamp: String
    let category: String
    let direction: String?
    let summary: String
    let payload: String?
    let fields: [String: String]?

    var id: UInt64 { sequence }
}

struct VoiceRuntimeStatus: Codable, Sendable {
    let ready: Bool
    let runtimeInstalled: Bool
    let runtimeSource: String?
    let runtimeDetail: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case ready
        case runtimeInstalled = "runtime_installed"
        case runtimeSource = "runtime_source"
        case runtimeDetail = "runtime_detail"
        case lastError = "last_error"
    }
}

struct ModuleUpdateStatus: Codable, Sendable {
    let supported: Bool
    let formatVersion: Int?
    let platform: String?
    let installedVersion: String?
    let publicKeyID: String?
    let dataFreeBytes: UInt64?
    let tempFreeBytes: UInt64?
    let callActive: Bool?
    let updatePending: Bool?
    let agentPID: Int?
    let factoryServicePID: Int?

    enum CodingKeys: String, CodingKey {
        case supported, platform
        case formatVersion = "format_version"
        case installedVersion = "installed_version"
        case publicKeyID = "public_key_id"
        case dataFreeBytes = "data_free_bytes"
        case tempFreeBytes = "temp_free_bytes"
        case callActive = "call_active"
        case updatePending = "update_pending"
        case agentPID = "agent_pid"
        case factoryServicePID = "factory_service_pid"
    }
}

enum ModuleUpdateInstallMode: String, Sendable {
    case normal
    case repair
}

struct ModuleUpdateInstallationState: Codable, Sendable, Equatable {
    let operationID: String?
    let mode: String?
    let phase: String
    let installedVersion: String?
    let targetVersion: String?
    let progress: Int
    let message: String
    let error: String?
    let rollbackConfirmed: Bool
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case mode, phase, progress, message, error
        case operationID = "operation_id"
        case installedVersion = "installed_version"
        case targetVersion = "target_version"
        case rollbackConfirmed = "rollback_confirmed"
        case updatedAt = "updated_at"
    }
}

struct ModuleUpdateLogChunk: Codable, Sendable {
    let text: String
    let nextOffset: Int64
    let complete: Bool

    enum CodingKeys: String, CodingKey {
        case text, complete
        case nextOffset = "next_offset"
    }
}

struct ModuleUpdateResult: Codable, Sendable {
    let updated: Bool
    let version: String?
    let restartRequired: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case updated, version, message
        case restartRequired = "restart_required"
    }
}

struct MaVoAudioHostConfig: Codable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
    let routeReady: Bool
    let routeSessionReady: Bool?
    let routeError: String?
    let routeRunning: Bool?
    let helperPID: Int?
    let sessionStartedAt: String?
    let statisticsAvailable: Bool?
    let statistics: VoicePCMStatistics?
    let diagnosticLog: String?
    let logTail: [String]?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case locationID = "location_id"
        case routeReady = "route_ready"
        case routeSessionReady = "route_session_ready"
        case routeError = "route_error"
        case routeRunning = "route_running"
        case helperPID = "helper_pid"
        case sessionStartedAt = "session_started_at"
        case statisticsAvailable = "statistics_available"
        case statistics
        case diagnosticLog = "diagnostic_log"
        case logTail = "log_tail"
    }
}

/// 模块语音桥的累计 PCM 统计；峰值为 PCM16 绝对幅度，0 代表纯静音。
struct VoicePCMStatistics: Codable, Sendable {
    let uplinkBytes: UInt64
    let uplinkFrames: UInt64
    let uplinkPeak: UInt64
    let downlinkBytes: UInt64
    let downlinkFrames: UInt64
    let downlinkPeak: UInt64
    let downlinkDroppedFrames: UInt64

    enum CodingKeys: String, CodingKey {
        case uplinkBytes = "uplink_bytes"
        case uplinkFrames = "uplink_frames"
        case uplinkPeak = "uplink_peak"
        case downlinkBytes = "downlink_bytes"
        case downlinkFrames = "downlink_frames"
        case downlinkPeak = "downlink_peak"
        case downlinkDroppedFrames = "downlink_dropped_frames"
    }
}

/// Explicit opt-in grant. Unknown/missing protocol or an unsigned grant is not media permission.
struct EarlyMediaGrant: Codable, Equatable, Sendable {
    let version: Int
    let agentID: String
    let callID: String
    let sessionID: String
    let expiresAt: Int64
    let state: String
    let direction: String
    let format: String
    let proof: String
    enum CodingKeys: String, CodingKey {
        case version, state, direction, format, proof
        case agentID = "agent_id", callID = "call_id", sessionID = "session_id", expiresAt = "expires_at"
    }
    func permits(agentID: String, callID: String, now: Int64) -> Bool {
        version == 1 && self.agentID == agentID && self.callID == callID
            && !sessionID.isEmpty && sessionID.utf8.count <= 128
            && [agentID, callID, sessionID].allSatisfy { !$0.contains("\n") && !$0.contains("\r") }
            && state == "early_media" && direction == "recvonly" && format == "s16le-8000-mono"
            && expiresAt > now && expiresAt <= now + 30
    }
    func proofMessage(nonce: String) -> Data {
        Data("AIRSIM-EARLY-MEDIA1\n\(nonce)\n\(agentID)\n\(callID)\n\(sessionID)\n\(expiresAt)\n\(state)\n\(direction)\n\(format)".utf8)
    }
}

enum EarlyMediaProbeResult: Equatable, Sendable {
    case ready(EarlyMediaGrant)
    case pending
    case unsupported
    case revoked
}

/// Audio callbacks reconnect off the main actor. Keep the newest verified
/// lease available to their handshake without sharing mutable call state.
final class EarlyMediaLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var grant: EarlyMediaGrant
    init(_ grant: EarlyMediaGrant) { self.grant = grant }
    func current() -> EarlyMediaGrant {
        lock.lock(); defer { lock.unlock() }
        return grant
    }
    func renew(_ next: EarlyMediaGrant, now: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard next.permits(agentID: grant.agentID, callID: grant.callID, now: now),
              next.sessionID == grant.sessionID, next.expiresAt >= grant.expiresAt else { return false }
        grant = next
        return true
    }
}

/// Bounded control negotiation only. It never dials, answers or changes call
/// state. Playback leases are independently enforced by the audio owner.
@MainActor
enum EarlyMediaNegotiator {
    enum Outcome: String { case cancelled, unsupported, revoked, unavailable, timedOut }

    static func run(
        clockOffset: TimeInterval,
        now: () -> TimeInterval = { Date().timeIntervalSince1970 },
        uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        isCurrent: () -> Bool,
        onPending: () -> Void = {},
        probe: () async throws -> EarlyMediaProbeResult,
        accept: (EarlyMediaGrant) async -> Bool
    ) async -> Outcome {
        let deadline = uptime() + 120
        var failures = 0
        while !Task.isCancelled, isCurrent(), uptime() < deadline {
            var delay: TimeInterval = 2
            do {
                let result = try await probe()
                guard !Task.isCancelled, isCurrent() else { return .cancelled }
                guard uptime() < deadline else { return .timedOut }
                switch result {
                case .ready(let grant):
                    guard grant.expiresAt > Int64(now() + clockOffset),
                          await accept(grant) else { return .unavailable }
                    failures = 0
                    // Renew before the independent playback deadline expires.
                    delay = min(15, max(0.5, Double(grant.expiresAt) - now() - clockOffset - 8))
                case .pending:
                    failures = 0
                    onPending()
                case .unsupported: return .unsupported
                case .revoked: return .revoked
                }
            } catch {
                if Task.isCancelled || !isCurrent() { return .cancelled }
                failures += 1
                if failures >= 3 { return .unavailable }
            }
            guard !Task.isCancelled, isCurrent() else { return .cancelled }
            do { try await sleep(max(0, min(delay, deadline - uptime()))) }
            catch { return .cancelled }
        }
        return Task.isCancelled || !isCurrent() ? .cancelled : .timedOut
    }
}

/// Read-only recovery receipt. Ownership and present state have separate proofs.
struct DialOperationStatus: Codable, Equatable, Sendable {
    let version: Int
    let agentID: String
    let operationID: String
    let status: String
    let androidID: String?
    let backendID: String?
    let callState: String
    let endedAt: String?
    let operationProof: String?
    let statusProof: String
    enum CodingKeys: String, CodingKey {
        case version, status
        case agentID = "agent_id", operationID = "operation_id", androidID = "android_id"
        case backendID = "backend_id", callState = "call_state", endedAt = "ended_at"
        case operationProof = "operation_proof", statusProof = "status_proof"
    }
    func matches(agentID: String, operationID: String) -> Bool {
        func token(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 128 && !value.contains(where: { "\r\n\0".contains($0) })
        }
        guard version == 1, self.agentID == agentID, self.operationID == operationID,
              token(agentID), token(operationID),
              ["confirmed", "unknown", "rejected"].contains(status),
              ["unknown", "dialing", "alerting", "active", "held", "ended"].contains(callState) else { return false }
        let ended = endedAt ?? ""
        guard ended.utf8.count <= 64, !ended.contains(where: { "\r\n\0".contains($0) }),
              (callState == "ended") == !ended.isEmpty else { return false }
        if callState == "ended" {
            let date = ISO8601DateFormatter()
            date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if date.date(from: ended) == nil {
                date.formatOptions = [.withInternetDateTime]
                guard date.date(from: ended) != nil else { return false }
            }
        }
        if status == "confirmed" { return token(androidID ?? "") && token(backendID ?? "") }
        return (androidID ?? "").isEmpty && (backendID ?? "").isEmpty
            && (operationProof ?? "").isEmpty && callState == "unknown" && ended.isEmpty
    }
    func proofMessage(nonce: String) -> Data {
        Data(["AIRSIM-OPERATION1", nonce, agentID, operationID, status,
              androidID ?? "", backendID ?? "", callState, endedAt ?? ""].joined(separator: "\n").utf8)
    }
    var lifecycleState: CallLifecycleState? {
        guard status == "confirmed" else { return nil }
        switch callState {
        case "dialing", "alerting": return .connecting
        case "active", "held": return .active
        case "ended": return .ended
        default: return nil
        }
    }
}

enum DialOperationRecoveryError: LocalizedError {
    case unknown, rejected, invalidProof
    var errorDescription: String? {
        switch self {
        case .unknown: return "拨号结果尚未确认。未自动重拨，请先检查设备通话状态。"
        case .rejected: return "设备确认未执行本次拨号。请检查设备提示后手动重试。"
        case .invalidProof: return "无法验证拨号状态回执，未恢复通话，也未自动重拨。"
        }
    }
}

enum SMSSIMPreference {
    static func key(_ agentID: String) -> String { "airsim.sms-sim-account.\(agentID)" }
    private static func conversationsKey(_ agentID: String) -> String { "airsim.sms-conversation-lines.\(agentID)" }
    private static func recipientKey(_ recipient: String) -> String {
        let normalized = recipient.filter { !$0.isWhitespace && !"()-".contains($0) }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func select(_ id: String, agentID: String, recipient: String?, defaults: UserDefaults = .standard) {
        guard let recipient, !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.set(id, forKey: key(agentID)); return
        }
        var lines = defaults.dictionary(forKey: conversationsKey(agentID)) as? [String: String] ?? [:]
        lines[recipientKey(recipient)] = id
        defaults.set(lines, forKey: conversationsKey(agentID))
    }
    static func remember(agentID: String, slots: [AndroidSIMSlot], defaults: UserDefaults = .standard) {
        // Cloud-only cold launches still need the previously authenticated
        // opaque handles. Do not persist SIM phone numbers. Android validates
        // the selected handle again and fails if that SIM has been removed.
        let sanitized = slots.prefix(8).map { slot in
            AndroidSIMSlot(id: slot.id, label: slot.label, number: nil, isDefault: slot.isDefault,
                slotIndex: slot.slotIndex, subID: slot.subID, carrierName: slot.carrierName,
                isEmbedded: slot.isEmbedded, isDefaultVoice: slot.isDefaultVoice, isDefaultSMS: slot.isDefaultSMS)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(sanitized), data != defaults.data(forKey: "airsim.sms-sim-slots.\(agentID)") {
            defaults.set(data, forKey: "airsim.sms-sim-slots.\(agentID)")
        }
    }
    static func rememberedSlots(agentID: String, defaults: UserDefaults = .standard) -> [AndroidSIMSlot] {
        guard let data = defaults.data(forKey: "airsim.sms-sim-slots.\(agentID)"),
              let slots = try? JSONDecoder().decode([AndroidSIMSlot].self, from: data) else { return [] }
        return slots
    }
    static func forget(agentID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(agentID))
        defaults.removeObject(forKey: "airsim.sms-sim-slots.\(agentID)")
        defaults.removeObject(forKey: conversationsKey(agentID))
    }
    static func selectedID(agentID: String, slots: [AndroidSIMSlot], recipient: String? = nil,
                           suggestedID: String? = nil,
                           defaults: UserDefaults = .standard) -> String? {
        let saved: String?
        if let recipient, !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saved = (defaults.dictionary(forKey: conversationsKey(agentID)) as? [String: String])?[recipientKey(recipient)]
        } else { saved = defaults.string(forKey: key(agentID)) }
        if let saved, slots.contains(where: { $0.id == saved }) { return saved }
        if let suggestedID, slots.contains(where: { $0.id == suggestedID }) { return suggestedID }
        return slots.first(where: { $0.isDefaultSMS == true })?.id
            ?? slots.first(where: { $0.isDefault == true })?.id ?? slots.first?.id
    }
}


/// Presentation grouping never drops or mutates the source history.
struct RecentCallGroup: Identifiable {
    let id: String
    let records: [CallRecord]
    var latest: CallRecord { records[0] }
    var recordIDs: Set<String> { Set(records.map(\.id)) }
    static func normalizedNumber(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "+0123456789")
        let separators = CharacterSet(charactersIn: " -().\u{00a0}")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) || separators.contains($0) }) else { return value }
        let number = value.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        let national = number.hasPrefix("+86") ? String(number.dropFirst(3)) : number
        if number.hasPrefix("+86"), (national.count == 11 && national.hasPrefix("1"))
            || (number.hasPrefix("+86") && national.hasPrefix("0") && (10...12).contains(national.count)) { return national }
        return number.isEmpty ? nil : number
    }
    static func grouped(_ calls: [CallRecord]) -> [Self] {
        Dictionary(grouping: calls, by: { normalizedNumber($0.number) ?? "unknown:" + $0.id })
            .map { key, calls in Self(id: key, records: calls.sorted {
                $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt
            }) }.sorted { $0.latest.startedAt == $1.latest.startedAt ? $0.id < $1.id : $0.latest.startedAt > $1.latest.startedAt }
    }
}

/// A command ACK or a different active call does not prove this call has ended.
enum CallEndEvidence {
    static func confirms(_ status: CallStatus, id: String) -> Bool {
        guard !id.isEmpty else { return false }
        func matches(_ call: CallRecord) -> Bool {
            [call.id, call.androidID, call.sourceCallID].compactMap { $0 }.contains(id)
        }
        if let active = status.active, matches(active) { return active.isTerminal }
        return (status.history ?? []).contains { matches($0) && $0.isTerminal }
    }
}
