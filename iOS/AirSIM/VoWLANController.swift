import Foundation
import Network

struct VoWLANEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let controlPort: UInt16
    let pcmPort: UInt16
    let usesTLS: Bool

    init(host: String, controlPort: UInt16, pcmPort: UInt16, usesTLS: Bool = false) throws {
        let validHost = usesTLS ? RemoteDirectHost.isValid(host) : Self.permitsDirectIPv4(host)
        let minimumPort: UInt16 = usesTLS ? 1 : 1024
        guard validHost, controlPort >= minimumPort, pcmPort >= minimumPort else {
            throw VoWLANControllerError.invalidAdvertisement
        }
        self.host = host
        self.controlPort = controlPort
        self.pcmPort = pcmPort
        self.usesTLS = usesTLS
    }

    var controlBaseURL: URL { URL(string: "\(usesTLS ? "https" : "http")://\(host):\(controlPort)/")! }

    static func permitsDirectIPv4(_ host: String) -> Bool {
        VoWLANNetworkRoutePolicy.permitsDirectIPv4(host)
    }
}

struct VoWLANManualRoute: Codable, Equatable, Sendable {
    let agentID: String
    let host: String
    let controlPort: UInt16
    let pcmPort: UInt16
    // Optional for compatibility with routes saved by older releases.
    var tls: Bool? = nil
    var isRemote: Bool { tls == true }
    var endpoint: VoWLANEndpoint? {
        try? .init(host: host, controlPort: controlPort, pcmPort: pcmPort, usesTLS: isRemote)
    }
}

enum RemoteDirectConfiguration {
    static func route(agentID: String, host: String, controlPort: String, pcmPort: String) throws -> VoWLANManualRoute {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func port(_ text: String) -> UInt16? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let result = UInt16(value), result > 0 else { return nil }
            return result
        }
        guard !agentID.isEmpty, RemoteDirectHost.isValid(host),
              let control = port(controlPort), let pcm = port(pcmPort) else {
            throw RemoteDirectError.invalidAddress
        }
        return VoWLANManualRoute(agentID: agentID, host: host, controlPort: control, pcmPort: pcm, tls: true)
    }
}

enum RemoteDirectError: LocalizedError {
    case invalidAddress, callInProgress
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请填写有效域名（不含 https:// 或路径）及 1–65535 的控制、音频端口"
        case .callInProgress: return "请先结束当前通话，再更改自建域名直连"
        }
    }
}

enum VoWLANManualRouteStore {
    private static let key = "AirSIM.manualDirectRoutes.v1"
    static func routes(defaults: UserDefaults = .standard) -> [VoWLANManualRoute] {
        guard let data = defaults.data(forKey: key),
              let routes = try? JSONDecoder().decode([VoWLANManualRoute].self, from: data) else { return [] }
        return routes.filter { !$0.agentID.isEmpty && $0.endpoint != nil }
    }
    static func save(_ route: VoWLANManualRoute, defaults: UserDefaults = .standard) throws {
        guard !route.agentID.isEmpty, route.endpoint != nil else { throw VoWLANControllerError.invalidAdvertisement }
        var values = routes(defaults: defaults).filter { $0.agentID != route.agentID || $0.isRemote != route.isRemote }
        values.append(route)
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }
    static func remove(agentID: String, defaults: UserDefaults = .standard) {
        let values = routes(defaults: defaults).filter { $0.agentID != agentID }
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }
    static func removeRemote(agentID: String, defaults: UserDefaults = .standard) {
        let values = routes(defaults: defaults).filter { $0.agentID != agentID || !$0.isRemote }
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }
    static func selected(defaults: UserDefaults = .standard) -> VoWLANManualRoute? {
        let bound = AndroidAgentBindingPreference.selected(defaults: defaults)
        let candidates = routes(defaults: defaults).filter {
            PairedAndroidDeviceStore.permits($0.agentID, defaults: defaults) && (bound == nil || $0.agentID == bound)
        }
        return candidates.last(where: { !$0.isRemote }) ?? candidates.last
    }
}

struct VoWLANDiscoveredAgent: Equatable, Identifiable, Sendable {
    let id: String
    let endpoint: VoWLANEndpoint
    let deviceName: String
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?
    let agentKind: String?
    /// Android advertises an additional Tailscale/overlay listener in the same Bonjour
    /// record. It is used only after the LAN endpoint fails a signed health probe.
    let alternateEndpoint: VoWLANEndpoint?

    init(id: String, endpoint: VoWLANEndpoint, deviceName: String,
         manufacturer: String?, model: String?, phoneNumber: String?, agentKind: String?,
         alternateEndpoint: VoWLANEndpoint? = nil) {
        self.id = id
        self.endpoint = endpoint
        self.deviceName = deviceName
        self.manufacturer = manufacturer
        self.model = model
        self.phoneNumber = phoneNumber
        self.agentKind = agentKind
        self.alternateEndpoint = alternateEndpoint
    }

    func refreshed(with identity: VoWLANHealthIdentity) -> Self {
        Self(id: identity.agentID?.isEmpty == false ? identity.agentID! : id,
             endpoint: endpoint,
             deviceName: identity.deviceName?.isEmpty == false ? identity.deviceName! : deviceName,
             manufacturer: identity.manufacturer ?? manufacturer, model: identity.model ?? model,
             phoneNumber: identity.phoneNumber?.isEmpty == false ? identity.phoneNumber : nil,
             agentKind: identity.agentKind ?? agentKind,
             alternateEndpoint: alternateEndpoint)
    }
}

struct VoWLANHealthIdentity: Decodable {
    let ok: Bool
    let agentID: String?
    let agentKind: String?
    let deviceName: String?
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?
    var identityProof: String? = nil
    var canonicalCallIDs: Bool? = nil
    var simSlots: [AndroidSIMSlot]? = nil

    enum CodingKeys: String, CodingKey {
        case ok
        case agentID = "agent_id"
        case agentKind = "agent_kind"
        case deviceName = "device_name"
        case manufacturer, model
        case phoneNumber = "phone_number"
        case identityProof = "identity_proof"
        case canonicalCallIDs = "canonical_call_ids"
        case simSlots = "sim_slots"
    }
}

enum VoWLANRouteCandidates {
    /// A saved route for the same phone at a different address (typically Tailscale)
    /// is the fallback when the current LAN route stops responding.
    static func alternateManualRoute(
        _ routes: [VoWLANManualRoute], agentID: String?, failed: VoWLANEndpoint,
        attempted: Set<VoWLANEndpoint> = []
    ) -> VoWLANManualRoute? {
        guard let agentID else { return nil }
        return routes.first {
            $0.agentID == agentID && $0.endpoint != nil && $0.endpoint != failed
                && $0.endpoint.map { !attempted.contains($0) } == true
        }
    }

    static func merge(discovered: [VoWLANDiscoveredAgent], manual: [VoWLANManualRoute],
                      live: [VoWLANDiscoveredAgent], preferred: VoWLANEndpoint?) -> [VoWLANDiscoveredAgent] {
        var agents = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for route in manual.sorted(by: { !$0.isRemote && $1.isRemote }) {
            guard let endpoint = route.endpoint else { continue }
            // Keep a healthy active endpoint stable; once unavailable, a fresh
            // advertisement for this identity takes precedence over a saved address.
            if agents[route.agentID] != nil && preferred != endpoint { continue }
            agents[route.agentID] = live.first { $0.id == route.agentID && $0.endpoint == endpoint }
                ?? VoWLANDiscoveredAgent(id: route.agentID, endpoint: endpoint, deviceName: "Android 手动直连",
                    manufacturer: nil, model: nil, phoneNumber: nil, agentKind: nil)
        }
        return agents.values.sorted { $0.id < $1.id }
    }
}

struct VoWLANProbeGeneration {
    private var value: UInt64 = 0
    mutating func begin() -> UInt64 { value &+= 1; return value }
    func accepts(_ generation: UInt64) -> Bool { generation == value }
}

enum VoWLANAvailability: Equatable, Sendable {
    case unpaired
    case discovering
    case discovered(VoWLANEndpoint, at: Date)
    case verified(VoWLANEndpoint, at: Date)
    case unavailable(String)

    var endpoint: VoWLANEndpoint? {
        switch self {
        case let .discovered(value, _), let .verified(value, _): return value
        default: return nil
        }
    }

    func isReady(at now: Date = Date()) -> Bool {
        guard case let .verified(_, verifiedAt) = self else { return false }
        return now.timeIntervalSince(verifiedAt) >= 0 && now.timeIntervalSince(verifiedAt) <= 10
    }

    var isOnlineForDisplay: Bool {
        if case .verified = self { return true }
        return false
    }

    /// 拨号动作会在真正发起前重新执行签名健康检查，因此 UI 只需确认该端点
    /// 曾验证成功；不能用 10 秒的严格建链时效永久禁用拨号按钮。
    var allowsCallAttempt: Bool { isOnlineForDisplay }
}

enum ConnectionStatusHeadline {
    static func title(summary: ModuleConnectionSummary, vowlanOnline: Bool) -> String {
        if vowlanOnline { return "VoWLAN 在线" }
        switch summary {
        case .localOnline: return L10n.t("在线")
        case .localOnlineNoService: return "在线 · 蜂窝无服务"
        case .cloudOnly: return "云端在线 · 网络重连中"
        case .offline: return L10n.t("离线")
        }
    }
}

enum ModuleConnectionPresentationLevel: Equatable {
    case online
    case warning
    case cloud
    case offline
}

struct ModuleConnectionPresentation: Equatable {
    let title: String
    let routeTitle: String
    let description: String
    let level: ModuleConnectionPresentationLevel
    let systemImage: String

    static func make(
        summary: ModuleConnectionSummary,
        vowlanOnline: Bool,
        reconnecting: Bool,
        message: String?
    ) -> Self {
        if vowlanOnline {
            return Self(
                title: "VoWLAN 在线",
                routeTitle: "同一 Wi-Fi / 三星热点",
                description: "VoWLAN 已连接，状态会自动刷新",
                level: .online,
                systemImage: "wifi"
            )
        }
        switch summary {
        case .localOnline:
            return Self(
                title: "模块在线", routeTitle: "局域网直连",
                description: message ?? "本地网络已连接，状态会自动刷新",
                level: .online, systemImage: "checkmark.circle.fill"
            )
        case .localOnlineNoService:
            return Self(
                title: "模块在线 · 无服务", routeTitle: "本地网络已连接",
                description: message ?? "本地网络已连接，蜂窝网络正在自动恢复",
                level: .warning, systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .cloudOnly:
            return Self(
                title: "云端在线", routeTitle: "公网 Relay",
                description: message ?? "本地网络中断，模块仍可通过公网接收来电和短信",
                level: .cloud, systemImage: "icloud.fill"
            )
        case .offline:
            return Self(
                title: reconnecting ? "正在重新连接" : "模块离线",
                routeTitle: reconnecting ? "正在恢复连接" : "连接不可用",
                description: message ?? "请检查 Android 供电、蜂窝网络与局域网连接",
                level: reconnecting ? .warning : .offline,
                systemImage: reconnecting ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill"
            )
        }
    }
}

enum PushRegistrationRouteSelector {
    static func select<Route>(primary: Route, verifiedVoWLAN: Route?) -> Route {
        verifiedVoWLAN ?? primary
    }
}

enum VoWLANStatusCopy {
    static func text(for availability: VoWLANAvailability, activeCall: Bool = false) -> String {
        if activeCall { return "通话中（VoWLAN）" }
        switch availability {
        case .unpaired: return "未配对"
        case .discovering: return "正在发现"
        case .discovered: return "已发现，正在验证"
        case .verified: return "VoWLAN 就绪"
        case let .unavailable(reason):
            return reason.contains("局域网已断开") ? "局域网已断开 · 已回退云端（下一通）" : reason
        }
    }
}

enum VoWLANControllerError: LocalizedError {
    case invalidAdvertisement
    case notDiscovered
    case notPaired
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidAdvertisement: return "VoWLAN 广播内容无效"
        case .notDiscovered: return "尚未发现三星 VoWLAN"
        case .notPaired: return "VoWLAN 尚未配对"
        case .authenticationFailed: return "VoWLAN 鉴权失败"
        }
    }
}

@MainActor
enum VoWLANProbeRecovery {
    static func run<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch {
            guard isDefunctConnection(error) else { throw error }
            try? await Task.sleep(for: .milliseconds(200))
            return try await operation()
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if isDefunctConnection(error) {
            return "VoWLAN 连接已失效，请保持 iPhone 与三星处于同一局域网"
        }
        return error.localizedDescription
    }

    private static func isDefunctConnection(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("defunctconnection")
            || message.contains("defunct connection")
            || message.contains("65569")
    }
}

struct VoWLANBrowserLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isRunning = false

    mutating func startIfNeeded() -> UInt64? {
        guard !isRunning else { return nil }
        return begin()
    }

    mutating func restart() -> UInt64 { begin() }

    mutating func stop() {
        generation &+= 1
        isRunning = false
    }

    mutating func markFailed(_ candidate: UInt64) -> Bool {
        guard accepts(candidate) else { return false }
        isRunning = false
        return true
    }

    func accepts(_ candidate: UInt64) -> Bool {
        isRunning && generation == candidate
    }

    private mutating func begin() -> UInt64 {
        generation &+= 1
        isRunning = true
        return generation
    }
}

/// A transient VPN route change can invalidate a successful probe without changing
/// Bonjour's result set. Keep retrying the saved endpoint, but bound retries when
/// the phone is genuinely offline.
struct VoWLANRecoveryGate {
    private var nextAttemptAt = Date.distantPast

    mutating func shouldAttempt(for availability: VoWLANAvailability, at now: Date) -> Bool {
        guard availability != .unpaired, !availability.isOnlineForDisplay,
              now >= nextAttemptAt else { return false }
        nextAttemptAt = now.addingTimeInterval(10)
        return true
    }

    mutating func reset() { nextAttemptAt = .distantPast }
}

/// Route observations are process-local, never stored as pairing identity.
struct VoWLANNetworkPathGate {
    private var observed = false
    private var previousAvailable = false
    private var previousRoute = ""
    mutating func observe(available: Bool, route: String) -> Bool {
        let changed = observed && (previousAvailable != available
            || (available && previousRoute != route))
        observed = true
        previousAvailable = available
        previousRoute = route
        return changed
    }
}

struct VoWLANNetworkRecoveryPlan {
    private var generation: UInt64 = 0
    private var wifiAvailable = false
    mutating func changed(wifiAvailable: Bool) -> UInt64 {
        generation &+= 1
        self.wifiAvailable = wifiAvailable
        return generation
    }
    mutating func invalidate() { generation &+= 1; wifiAvailable = false }
    func isCurrent(_ token: UInt64) -> Bool { token == generation }
    func permits(_ token: UInt64, mode: AirSIMConnectionMode, paired: Bool, callInProgress: Bool) -> Bool {
        token == generation && wifiAvailable && paired && !callInProgress
            && ConnectionModeRuntimePolicy(mode: mode).startsVoWLAN
    }
}

@MainActor
final class VoWLANController: ObservableObject {
    @Published private(set) var availability: VoWLANAvailability =
        !VoWLANCredentialStore.hasAny() ? .unpaired : .discovering {
        didSet { onAvailabilityChange?(availability) }
    }

    var onAvailabilityChange: ((VoWLANAvailability) -> Void)?
    var callInProgress: () -> Bool = { false }
    var onNetworkRecoveryVerified: (() -> Void)?

    @Published private(set) var discoveredAgents: [VoWLANDiscoveredAgent] = [] {
        didSet { onDiscoveredAgentsChange?() }
    }
    var onDiscoveredAgentsChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.example.airsim.vowlan.discovery")
    private var browser: NWBrowser?
    private var browserLifecycle = VoWLANBrowserLifecycle()
    private var recoveryGate = VoWLANRecoveryGate()
    private var discoveredEndpoint: VoWLANEndpoint?
    private var latestBonjourAgents: [VoWLANDiscoveredAgent] = []
    private var disappearanceTask: Task<Void, Never>?
    private var identityEpoch: UInt64 = 0
    private var probeGeneration = VoWLANProbeGeneration()
    private var networkMonitor: NWPathMonitor?
    private var networkRecoveryTask: Task<Void, Never>?
    private var networkRecoveryPlan = VoWLANNetworkRecoveryPlan()
    private var networkPathGate = VoWLANNetworkPathGate()
    private var samePathProbeTask: Task<Void, Never>?
    private var remoteConfigurationGeneration: UInt64 = 0

    /// Validate without changing the active peer. Persist only after TLS and the
    /// existing nonce-bound Android identity proof both succeed.
    func configureRemoteRoute(agentID: String, route: VoWLANManualRoute?,
                              credentials: any LocalDeviceCredentialStoring = KeychainLocalDeviceCredentials(),
                              transport: LocalDeviceDirectory.HealthTransport? = nil) async throws {
        remoteConfigurationGeneration &+= 1
        let generation = remoteConfigurationGeneration
        guard !callInProgress() else { throw RemoteDirectError.callInProgress }
        if let route {
            guard route.agentID == agentID, route.isRemote, let endpoint = route.endpoint else {
                throw RemoteDirectError.invalidAddress
            }
            let credential = await Task.detached { credentials.load(agentID: agentID) }.value
            guard let credential, PairedAndroidDeviceStore.permits(agentID) else {
                throw VoWLANControllerError.notPaired
            }
            _ = try await VoWLANAuthenticatedHealth.fetch(agentID: agentID, endpoint: endpoint,
                credential: credential, transport: transport ?? { try await WiredHTTPTransport().send($0) })
            try Task.checkCancellation()
            guard generation == remoteConfigurationGeneration,
                  PairedAndroidDeviceStore.permits(agentID),
                  credentials.load(agentID: agentID) == credential else { throw CancellationError() }
            guard !callInProgress() else { throw RemoteDirectError.callInProgress }
            // Automatic Bonjour pairing has no manual LAN entry. Preserve its
            // last authenticated local address before adding the remote fallback.
            if !VoWLANManualRouteStore.routes().contains(where: { $0.agentID == agentID && !$0.isRemote }),
               let local = VoWLANPairingRecordStore.records().first(where: { $0.agentID == agentID })?
                .endpoints.compactMap({ $0.endpoint }).last(where: { !$0.usesTLS }) {
                try VoWLANManualRouteStore.save(.init(agentID: agentID, host: local.host,
                    controlPort: local.controlPort, pcmPort: local.pcmPort))
            }
            try VoWLANManualRouteStore.save(route)
        } else {
            VoWLANManualRouteStore.removeRemote(agentID: agentID)
        }
        // Configuring a secondary phone must not change the user's binding or
        // start local networking in explicit Cloud/Bluetooth modes.
        if ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN {
            restartBrowsing()
        }
    }

    func forget(_ agentID: String) {
        identityEpoch &+= 1
        remoteConfigurationGeneration &+= 1
        VoWLANManualRouteStore.remove(agentID: agentID)
        let removingActive = discoveredAgents.contains { $0.id == agentID && $0.endpoint == discoveredEndpoint }
        discoveredAgents.removeAll { $0.id == agentID }
        if removingActive {
            discoveredEndpoint = nil
            availability = .discovering
        }
        restartBrowsing()
    }

    func bind(to agentID: String?) {
        AndroidAgentBindingPreference.set(agentID)
        let selected = agentID.flatMap { id in discoveredAgents.first(where: { $0.id == id }) }
        if let selected {
            disappearanceTask?.cancel()
            discoveredEndpoint = selected.endpoint
            availability = .discovered(selected.endpoint, at: Date())
            Task { await probeNow() }
        } else if agentID != nil {
            discoveredEndpoint = nil
            availability = .discovering
        }
    }

    func startBrowsing() {
        startNetworkMonitorIfNeeded()
        guard let generation = browserLifecycle.startIfNeeded() else { return }
        restoreManualRoutes()
        beginBrowsing(generation: generation)
        if discoveredEndpoint != nil { Task { await probeNow() } }
    }

    /// Foreground recovery should not tear down a working Bonjour browser just
    /// because CallKit/ActivityKit briefly backgrounded the app. Probe the known
    /// endpoint first; only start a new browser when the old one is gone.
    func refreshAfterForeground() async {
        startNetworkMonitorIfNeeded()
        if browserLifecycle.isRunning {
            if discoveredEndpoint != nil {
                await probeNow()
            }
            return
        }
        startBrowsing()
        await probeNow()
    }

    func restartBrowsing() {
        samePathProbeTask?.cancel()
        samePathProbeTask = nil
        identityEpoch &+= 1
        startNetworkMonitorIfNeeded()
        let generation = browserLifecycle.restart()
        stopCurrentBrowser()
        discoveredEndpoint = nil
        discoveredAgents = []
        latestBonjourAgents = []
        restoreManualRoutes()
        beginBrowsing(generation: generation)
        if discoveredEndpoint != nil { Task { await probeNow() } }
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "browser_restarted",
                title: "VoWLAN 浏览器已重建",
                fields: ["generation": String(generation)]
            )
        }
    }

    private func beginBrowsing(generation: UInt64) {
        availability = discoveredEndpoint.map { .discovered($0, at: Date()) } ?? .discovering
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let active = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_airsim-vowlan._tcp", domain: nil),
            using: parameters
        )
        active.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = results.compactMap(Self.parseAgent)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.browserLifecycle.accepts(generation) else { return }
                self.latestBonjourAgents = parsed.filter { PairedAndroidDeviceStore.permits($0.id) }
                let agents = self.mergingManualRoutes(with: self.latestBonjourAgents)
                let endpoints = Set(agents.map(\.endpoint))
                self.discoveredAgents = agents.sorted {
                    if $0.deviceName == $1.deviceName { return $0.id < $1.id }
                    return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
                }
                let bound = AndroidAgentBindingPreference.selected()
                let endpoint = agents.first(where: { $0.id == bound })?.endpoint
                    ?? (bound == nil ? self.discoveredEndpoint.flatMap { endpoints.contains($0) ? $0 : nil } : nil)
                    ?? (bound == nil ? agents.first?.endpoint : nil)
                if let endpoint {
                    self.disappearanceTask?.cancel()
                    self.discoveredEndpoint = endpoint
                    if self.availability.endpoint == endpoint, self.availability.isReady() { return }
                    self.availability = .discovered(endpoint, at: Date())
                    await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: "ios", category: "vowlan", phase: "discovered",
                        title: "VoWLAN 已发现",
                        fields: ["host": endpoint.host, "control_port": String(endpoint.controlPort), "pcm_port": String(endpoint.pcmPort)]
                    )
                    await self.probeNow()
                } else if self.discoveredEndpoint != nil {
                    // Bonjour frequently publishes an empty intermediate result while VPN,
                    // hotspot, or Wi-Fi routes settle. Preserve the verified endpoint and
                    // verify it after a grace period instead of tearing down an active route.
                    self.scheduleDisappearanceCheck(generation: generation)
                } else if !self.availability.isReady() {
                    self.availability = .discovering
                }
            }
        }
        active.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { @MainActor [weak self] in
                    guard let self, self.browserLifecycle.markFailed(generation) else { return }
                    self.stopCurrentBrowser()
                    if let endpoint = self.discoveredEndpoint, self.manualRoute(for: endpoint) != nil {
                        // Manual routes do not depend on mDNS or its permission/state.
                        await self.probeNow()
                        return
                    }
                    self.discoveredEndpoint = nil
                    self.availability = .unavailable(
                        VoWLANProbeRecovery.userFacingMessage(for: error)
                    )
                    await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: "ios", category: "vowlan", phase: "browser_failed",
                        title: "VoWLAN 浏览器失效", detail: error.localizedDescription,
                        fields: ["generation": String(generation)], isFailure: true
                    )
                }
            }
        }
        browser = active
        active.start(queue: queue)
    }

    func stopBrowsing() {
        stopBrowserSession()
        if VoWLANCredentialStore.hasAny() { availability = .discovering }
    }

    private func stopBrowserSession() {
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil
        samePathProbeTask?.cancel()
        samePathProbeTask = nil
        networkPathGate = VoWLANNetworkPathGate()
        networkRecoveryPlan.invalidate()
        networkMonitor?.pathUpdateHandler = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        identityEpoch &+= 1
        disappearanceTask?.cancel()
        disappearanceTask = nil
        browserLifecycle.stop()
        stopCurrentBrowser()
        discoveredEndpoint = nil
        discoveredAgents = []
    }

    private func scheduleDisappearanceCheck(generation: UInt64) {
        guard disappearanceTask == nil else { return }
        disappearanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled,
                  self.browserLifecycle.accepts(generation) else { return }
            self.disappearanceTask = nil
            if let endpoint = self.discoveredEndpoint {
                self.availability = .discovered(endpoint, at: Date())
                await self.probeNow()
            }
        }
    }

    private func stopCurrentBrowser() {
        let active = browser
        browser = nil
        active?.browseResultsChangedHandler = nil
        active?.stateUpdateHandler = nil
        active?.cancel()
    }

    func refreshAfterPairing() async {
        restartBrowsing()
        await probeNow()
    }

    func installManualRoute(_ route: VoWLANManualRoute) async throws {
        try VoWLANManualRouteStore.save(route)
        // An explicit pairing is an explicit target selection. Without this,
        // a previous binding makes selected() keep probing the old address and
        // the freshly paired Tailscale gateway looks unreachable.
        AndroidAgentBindingPreference.set(route.agentID)
        restartBrowsing()
        await probeNow()
        if !availability.isOnlineForDisplay {
            // Tailscale/userspace proxies can need a moment after the pairing
            // socket closes before the control/PCM listeners accept again.
            try? await Task.sleep(for: .milliseconds(600))
            await probeNow()
        }
    }

    private func manualRoute(for endpoint: VoWLANEndpoint) -> VoWLANManualRoute? {
        VoWLANManualRouteStore.routes().first { $0.endpoint == endpoint && PairedAndroidDeviceStore.permits($0.agentID) }
    }

    private func mergingManualRoutes(with discovered: [VoWLANDiscoveredAgent]) -> [VoWLANDiscoveredAgent] {
        VoWLANRouteCandidates.merge(discovered: discovered,
            manual: VoWLANManualRouteStore.routes().filter { PairedAndroidDeviceStore.permits($0.agentID) },
            live: discoveredAgents,
            // A cached pairing-time IP is not a healthy route. Let fresh Bonjour
            // for the same paired agent replace it until it actually verifies.
            // Keep an established call's route stable; never mid-call hand over.
            preferred: (availability.isOnlineForDisplay || callInProgress()) ? discoveredEndpoint : nil)
    }

    private func restoreManualRoutes() {
        discoveredAgents = mergingManualRoutes(with: discoveredAgents)
        let route = VoWLANManualRouteStore.selected()
        if let endpoint = route?.endpoint { discoveredEndpoint = endpoint }
    }

    /// Called by the existing local status loop when no verified route remains.
    /// A VPN disconnect doesn't necessarily emit a new Bonjour result, so a
    /// failed health probe must not wait for Android to advertise again.
    func recoverIfNeeded() async {
        guard ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN,
              !callInProgress(), VoWLANCredentialStore.hasAny(),
              recoveryGate.shouldAttempt(for: availability, at: Date()) else { return }
        let browserWasRunning = browserLifecycle.isRunning
        startBrowsing()
        await probeNow()
        if availability.isOnlineForDisplay {
            recoveryGate.reset()
        } else if browserWasRunning {
            restartBrowsing()
        }
    }

    private func startNetworkMonitorIfNeeded() {
        guard networkMonitor == nil,
              ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        networkPathGate = VoWLANNetworkPathGate()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let available = path.status == .satisfied
            // No SSID/location permission or persistent address/identity cache.
            // Equal status can still describe a different local gateway/interface.
            let route = path.availableInterfaces.map { "\($0.index):\($0.name)" }.sorted().joined(separator: ",")
                + "|" + path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor, self.networkMonitor === monitor else { return }
                self.networkChanged(wifiAvailable: available, route: route)
            }
        }
        monitor.start(queue: queue)
    }

    private func networkChanged(wifiAvailable: Bool, route: String) {
        // A duplicate snapshot must not advance recovery's generation: otherwise
        // it invalidates the one-second delayed task for the actual Wi-Fi change.
        guard networkPathGate.observe(available: wifiAvailable, route: route) else {
            if wifiAvailable { verifyUnchangedPathIfNeeded() }
            return
        }
        let token = networkRecoveryPlan.changed(wifiAvailable: wifiAvailable)
        networkRecoveryTask?.cancel()
        samePathProbeTask?.cancel()
        samePathProbeTask = nil
        // Reject probes begun on the previous network, including an old successful response.
        identityEpoch &+= 1
        if !callInProgress(), let endpoint = discoveredEndpoint,
           !VoWLANNetworkRoutePolicy.usesSystemRouting(host: endpoint.host) {
            availability = .discovered(endpoint, at: Date())
        }
        networkRecoveryTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.networkRecoveryPlan.isCurrent(token) { self.networkRecoveryTask = nil }
            }
            await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "vowlan",
                phase: "network_changed", title: "VoWLAN 网络变化",
                fields: ["wifi_available": String(wifiAvailable), "revision": String(token)])
            guard wifiAvailable else { return }
            do {
                try await Task.sleep(for: .seconds(1))
                // A cloud call remains cloud. Recovery can proceed after it ends, not through handover.
                while let self, self.callInProgress() {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(2))
                }
                guard let self, self.mayRecoverNetwork(token) else { return }
                self.recoveryGate.reset()
                self.restartBrowsing()
                for delay in [0, 2, 5] {
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    guard self.mayRecoverNetwork(token) else { return }
                    await self.probeNow()
                    guard self.mayRecoverNetwork(token) else { return }
                    if self.availability.isOnlineForDisplay {
                        self.onNetworkRecoveryVerified?()
                        await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "vowlan",
                            phase: "network_recovered", title: "VoWLAN 已通过认证恢复",
                            fields: ["revision": String(token)])
                        return
                    }
                }
                await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "vowlan",
                    phase: "network_recovery_pending", title: "VoWLAN 尚未恢复，保留其他可用链路",
                    fields: ["revision": String(token)])
            } catch { /* Cancellation is normal on another network/mode transition. */ }
        }
    }

    /// Same gateway/interface can occur on different Wi-Fi networks. Use the
    /// existing signed health request, never SSID or IP alone, to decide liveness.
    /// Event-bound single task; no polling loop or new periodic timer.
    private func verifyUnchangedPathIfNeeded() {
        guard networkRecoveryTask == nil, samePathProbeTask == nil,
              !callInProgress(), VoWLANCredentialStore.hasAny(),
              ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN else { return }
        let epoch = identityEpoch
        samePathProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if epoch == self.identityEpoch { self.samePathProbeTask = nil } }
            await self.probeNow()
            guard !Task.isCancelled, epoch == self.identityEpoch,
                  self.networkMonitor != nil, !self.callInProgress(),
                  ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN,
                  !self.availability.isOnlineForDisplay else { return }
            self.samePathProbeTask = nil
            self.recoveryGate.reset()
            self.restartBrowsing()
        }
    }

    private func mayRecoverNetwork(_ token: UInt64) -> Bool {
        networkRecoveryPlan.permits(token, mode: ConnectionModePreference.selected(),
            paired: VoWLANCredentialStore.hasAny(), callInProgress: callInProgress())
    }

    func probeNow() async { await probeNow(attempted: []) }

    private func probeNow(attempted: Set<VoWLANEndpoint>) async {
        guard !Task.isCancelled else { return }
        guard let endpoint = availability.endpoint ?? discoveredEndpoint else { return }
        guard !attempted.contains(endpoint) else { return }
        let attempted = attempted.union([endpoint])
        let epoch = identityEpoch
        let expectedID = manualRoute(for: endpoint)?.agentID
            ?? discoveredAgents.first { $0.endpoint == endpoint }?.id
        let credential = await Task.detached {
            let scoped = expectedID.flatMap { VoWLANCredentialStore.load(agentID: $0) }
            // A remote gateway must never fall back to another device's legacy key.
            return scoped ?? (endpoint.usesTLS ? nil : VoWLANCredentialStore.load())
        }.value
        guard epoch == identityEpoch, discoveredEndpoint == endpoint else { return }
        guard let credential else {
            availability = .unpaired
            return
        }
        let probe = probeGeneration.begin()
        do {
            let (data, status, nonce) = try await VoWLANProbeRecovery.run {
                let signed = try VoWLANRequestSigner(credential: credential).sign(
                    method: "GET", path: "/v1/health", body: Data()
                )
                var request = URLRequest(url: endpoint.controlBaseURL.appendingPathComponent("v1/health"))
                // Tailscale/VPN health probes can exceed the old 3s budget even
                // when the authenticated control APIs are healthy. Keep the probe
                // bounded, but do not turn normal VPN latency into a failure storm.
                request.timeoutInterval = 6
                request.cachePolicy = .reloadIgnoringLocalCacheData
                Self.apply(signed, to: &request)
                // NWConnection-based transport: ATS does not apply to the
                // 100.64/10 tailnet address, and the system route is used.
                let response = try await WiredHTTPTransport().send(request)
                return (response.body, response.statusCode, signed.nonce)
            }
            guard status == 200,
                  let identity = try? JSONDecoder().decode(VoWLANHealthIdentity.self, from: data),
                  identity.ok else {
                throw VoWLANControllerError.authenticationFailed
            }
            guard epoch == identityEpoch, discoveredEndpoint == endpoint, probeGeneration.accepts(probe) else { return }
            if let expectedID, endpoint.usesTLS || VoWLANCredentialStore.load(agentID: expectedID) != nil {
                guard identity.agentID == expectedID,
                      VoWLANHealthProof.verify(identity.identityProof, nonce: nonce,
                        agentID: expectedID, credential: credential) else { throw VoWLANControllerError.authenticationFailed }
            }
            if let route = manualRoute(for: endpoint), identity.agentID != route.agentID {
                throw VoWLANControllerError.authenticationFailed
            }
            if let id = identity.agentID, !PairedAndroidDeviceStore.permits(id) {
                discoveredAgents.removeAll { $0.endpoint == endpoint }
                discoveredEndpoint = nil
                availability = .discovering
                return
            }
            if endpoint.usesTLS && expectedID == nil { throw VoWLANControllerError.authenticationFailed }
            if let index = discoveredAgents.firstIndex(where: { $0.endpoint == endpoint }) {
                let previous = discoveredAgents[index]
                discoveredAgents[index] = previous.refreshed(with: identity)
            }
            availability = .verified(endpoint, at: Date())
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "verified",
                title: "VoWLAN 签名健康检查通过",
                fields: ["host": endpoint.host, "control_port": String(endpoint.controlPort)]
            )
        } catch {
            guard epoch == identityEpoch, discoveredEndpoint == endpoint, probeGeneration.accepts(probe) else { return }
            availability = .unavailable(VoWLANProbeRecovery.userFacingMessage(for: error))
            guard !callInProgress(), !Task.isCancelled else { return }
            // LAN Bonjour discovery does not cross networks; when it stops responding,
            // use another saved direct address for the SAME phone (Tailscale/VPN).
            let failedAgent = discoveredAgents.first(where: { $0.endpoint == endpoint })
            let agentID = failedAgent?.id ?? AndroidAgentBindingPreference.selected()
            if let advertised = failedAgent?.alternateEndpoint, !attempted.contains(advertised) {
                // Persist the advertised Tailscale listener so the choice survives the
                // next Bonjour result and a cold start without the LAN advertisement.
                if let agentID, PairedAndroidDeviceStore.permits(agentID) {
                    try? VoWLANManualRouteStore.save(VoWLANManualRoute(
                        agentID: agentID, host: advertised.host,
                        controlPort: advertised.controlPort, pcmPort: advertised.pcmPort))
                }
                selectFallback(advertised)
                availability = .discovered(advertised, at: Date())
                await AgentVerboseTraceRecorder.shared.recordEvent(
                    source: "ios", category: "vowlan", phase: "fallback",
                    title: "VoWLAN 切换到 Android 通告的 Tailscale 地址",
                    fields: ["host": advertised.host, "control_port": String(advertised.controlPort)]
                )
                await probeNow(attempted: attempted)
                return
            }
            if let alternate = VoWLANRouteCandidates.alternateManualRoute(
                VoWLANManualRouteStore.routes().filter { PairedAndroidDeviceStore.permits($0.agentID) },
                agentID: agentID, failed: endpoint, attempted: attempted
            )?.endpoint {
                selectFallback(alternate)
                availability = .discovered(alternate, at: Date())
                await AgentVerboseTraceRecorder.shared.recordEvent(
                    source: "ios", category: "vowlan", phase: "fallback",
                    title: "VoWLAN 切换到已保存直连地址",
                    fields: ["host": alternate.host, "control_port": String(alternate.controlPort)]
                )
                await probeNow(attempted: attempted)
                return
            }
            if let saved = manualRoute(for: endpoint),
               let alternate = latestBonjourAgents.first(where: { $0.id == saved.agentID && !attempted.contains($0.endpoint) }) {
                // Change preferred route before merging, so the saved old-IP
                // manual route cannot hide this agent's newly discovered endpoint.
                selectFallback(alternate.endpoint)
                availability = .discovered(alternate.endpoint, at: Date())
                await probeNow(attempted: attempted)
                return
            }
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "failed",
                title: "VoWLAN 健康检查失败", detail: error.localizedDescription,
                isFailure: true
            )
        }
    }

    private func selectFallback(_ endpoint: VoWLANEndpoint) {
        discoveredEndpoint = endpoint
        // Keep the candidate's device/key and LocalDeviceDirectory in sync with the
        // selected route, even before its asynchronous health probe completes.
        discoveredAgents = VoWLANRouteCandidates.merge(discovered: latestBonjourAgents,
            manual: VoWLANManualRouteStore.routes().filter { PairedAndroidDeviceStore.permits($0.agentID) },
            live: discoveredAgents, preferred: endpoint)
    }

    nonisolated static func apply(_ signed: VoWLANSignedRequest, to request: inout URLRequest) {
        request.setValue("1", forHTTPHeaderField: "X-AirSIM-VoWLAN-Version")
        request.setValue(String(signed.timestamp), forHTTPHeaderField: "X-AirSIM-VoWLAN-Timestamp")
        request.setValue(signed.nonce, forHTTPHeaderField: "X-AirSIM-VoWLAN-Nonce")
        request.setValue(signed.signature, forHTTPHeaderField: "X-AirSIM-VoWLAN-Signature")
    }

    private nonisolated static func parseAgent(_ result: NWBrowser.Result) -> VoWLANDiscoveredAgent? {
        guard case let .bonjour(record) = result.metadata,
              record["v"] == "1", let host = record["host"],
              let controlText = record["control_port"], let control = UInt16(controlText),
              let pcmText = record["pcm_port"], let pcm = UInt16(pcmText) else { return nil }
        guard let endpoint = try? VoWLANEndpoint(host: host, controlPort: control, pcmPort: pcm) else {
            return nil
        }
        let fallbackID = "vowlan-\(host)-\(control)"
        let deviceName = record["device_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var alternate: VoWLANEndpoint?
        if let altHost = record["alt_host"], altHost != host,
           let altControl = record["alt_control_port"].flatMap(UInt16.init),
           let altPCM = record["alt_pcm_port"].flatMap(UInt16.init) {
            alternate = try? VoWLANEndpoint(host: altHost, controlPort: altControl, pcmPort: altPCM)
        }
        return VoWLANDiscoveredAgent(
            id: record["agent_id"]?.isEmpty == false ? record["agent_id"]! : fallbackID,
            endpoint: endpoint,
            deviceName: deviceName?.isEmpty == false ? deviceName! : "Android 手机",
            manufacturer: record["manufacturer"],
            model: record["model"],
            phoneNumber: nil,
            agentKind: record["agent_kind"],
            alternateEndpoint: alternate
        )
    }
}
