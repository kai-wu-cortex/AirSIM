import Foundation

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
    let missed: Bool

    enum CodingKeys: String, CodingKey {
        case id, index, direction, state, number, missed
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
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

/// Agent 的统一事件快照；通话和短信共用一个长轮询，避免后台保持两套 USB 请求。
struct AgentEventStatus: Codable, Sendable {
    let revision: UInt64
    let smsRevision: UInt64
    let smsPending: Int
    let call: CallStatus

    enum CodingKeys: String, CodingKey {
        case revision, call
        case smsRevision = "sms_revision"
        case smsPending = "sms_pending"
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
struct CloudAgentStatus: Codable, Equatable, Sendable {
    let cloudOnline: Bool
    let agentVersion: String?
    let atOK: Bool?
    let cellularState: String?
    let cellularRegistration: String?
    let cellularRecovery: String?
    let ecmCarrier: String?
    let signalDBM: Int?

    enum CodingKeys: String, CodingKey {
        case cloudOnline = "cloud_online"
        case agentVersion = "agent_version"
        case atOK = "at_ok"
        case cellularState = "cellular_state"
        case cellularRegistration = "cellular_registration"
        case cellularRecovery = "cellular_recovery"
        case ecmCarrier = "ecm_carrier"
        case signalDBM = "signal_dbm"
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

    var isOutgoing: Bool { direction == .outgoing }

    /// 新版 Agent 用 delivery_id 对齐 APNs 与本地同步；旧版仍回退到内容指纹。
    var id: String {
        if let deliveryID, !deliveryID.isEmpty { return "delivery:\(deliveryID)" }
        return "\(sender)\u{0}\(timestamp.timeIntervalSince1970)\u{0}\(content)\u{0}\(direction?.rawValue ?? SMSDirection.incoming.rawValue)"
    }

    enum CodingKeys: String, CodingKey {
        case sender, content, code, timestamp, direction
        case deliveryID = "delivery_id"
    }
}

enum SMSHistoryPolicy {
    static func appendingSentMessage(
        recipient: String,
        content: String,
        at timestamp: Date,
        to messages: [SMSMessage],
        limit: Int
    ) -> [SMSMessage] {
        let sentMessage = SMSMessage(
            sender: recipient,
            content: content,
            code: nil,
            timestamp: timestamp,
            deliveryID: nil,
            direction: .outgoing
        )
        return Array((messages + [sentMessage])
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(max(0, limit)))
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

struct USBProfileStatus: Codable, Sendable {
    let mode: String
    let uacEnabled: Bool
    let configuration: String
    let needsReconnect: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case mode, configuration, message
        case uacEnabled = "uac_enabled"
        case needsReconnect = "needs_reconnect"
    }
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

struct ModuleDebugSnapshot: Codable, Sendable {
    let debug: ModuleDebugBufferStatus
    let agent: ModuleDebugAgentStatus
    let at: ModuleDebugATStatus
    let usb: [String: String]
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

struct NetworkDiagnostic: Codable, Sendable {
    let usbnetMode: String?
    let usbcfg: String?
    let pdpContexts: [PDPContext]?
    let activeContexts: [Int]?
    let pdpAddresses: [String]?
    let interfaces: [NetworkInterface]?
    let defaultRoute: NetworkDefaultRoute?
    let usbNetworkPresent: Bool
    let usbDevice: USBDeviceStatus?
    let errors: [String: String]?

    enum CodingKeys: String, CodingKey {
        case usbcfg, errors
        case usbnetMode = "usbnet_mode"
        case pdpContexts = "pdp_contexts"
        case activeContexts = "active_contexts"
        case pdpAddresses = "pdp_addresses"
        // 后端为兼容 Mac 版保留了旧字段名。
        case interfaces = "mac_interfaces"
        case defaultRoute = "default_route"
        case usbNetworkPresent = "usb_network_present"
        case usbDevice = "usb_device"
    }
}

struct PDPContext: Codable, Sendable { let id: Int?; let pdn: String?; let apn: String? }
struct NetworkInterface: Codable, Sendable {
    let name: String?; let status: String?; let ipv4: String?; let mac: String?; let kind: String?
}
struct NetworkDefaultRoute: Codable, Sendable { let interface: String?; let gateway: String? }
struct USBDeviceStatus: Codable, Sendable {
    let vendor: String?; let product: String?; let vendorID: String?; let productID: String?; let mode: String?
    enum CodingKeys: String, CodingKey {
        case vendor, product, mode
        case vendorID = "vendor_id"
        case productID = "product_id"
    }
}

struct ModuleSetupStatus: Codable, Sendable {
    let state: String
    let summary: String
    let detail: String?
    let canInitialize: Bool
    let requiresConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case state, summary, detail
        case canInitialize = "can_initialize"
        case requiresConfirmation = "requires_confirmation"
    }
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
