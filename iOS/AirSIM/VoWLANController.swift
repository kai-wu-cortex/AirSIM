import Foundation
import Network

struct VoWLANEndpoint: Equatable, Sendable {
    let host: String
    let controlPort: UInt16
    let pcmPort: UInt16

    init(host: String, controlPort: UInt16, pcmPort: UInt16) throws {
        guard Self.isPrivateIPv4(host), controlPort >= 1024, pcmPort >= 1024 else {
            throw VoWLANControllerError.invalidAdvertisement
        }
        self.host = host
        self.controlPort = controlPort
        self.pcmPort = pcmPort
    }

    var controlBaseURL: URL { URL(string: "http://\(host):\(controlPort)/")! }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let fields = host.split(separator: ".").compactMap { UInt8($0) }
        guard fields.count == 4 else { return false }
        return fields[0] == 10 || (fields[0] == 172 && (16...31).contains(fields[1]))
            || (fields[0] == 192 && fields[1] == 168)
    }
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
        case .cloudOnly: return "云端在线 · USB 重连中"
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
                title: "模块在线", routeTitle: "USB ECM 直连",
                description: message ?? "USB ECM 已连接，状态会自动刷新",
                level: .online, systemImage: "checkmark.circle.fill"
            )
        case .localOnlineNoService:
            return Self(
                title: "模块在线 · 无服务", routeTitle: "USB ECM 已连接",
                description: message ?? "USB ECM 已连接，蜂窝网络正在自动恢复",
                level: .warning, systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .cloudOnly:
            return Self(
                title: "云端在线", routeTitle: "公网 Relay",
                description: message ?? "USB ECM 本地连接中断，模块仍可通过公网接收来电和短信",
                level: .cloud, systemImage: "icloud.fill"
            )
        case .offline:
            return Self(
                title: reconnecting ? "正在重新连接" : "模块离线",
                routeTitle: reconnecting ? "正在恢复连接" : "连接不可用",
                description: message ?? "请检查模块供电、蜂窝网络与 USB ECM 连接",
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

@MainActor
final class VoWLANController: ObservableObject {
    @Published private(set) var availability: VoWLANAvailability =
        VoWLANCredentialStore.load() == nil ? .unpaired : .discovering {
        didSet { onAvailabilityChange?(availability) }
    }

    var onAvailabilityChange: ((VoWLANAvailability) -> Void)?

    private let queue = DispatchQueue(label: "com.example.airsim.vowlan.discovery")
    private var browser: NWBrowser?
    private var browserLifecycle = VoWLANBrowserLifecycle()
    private var discoveredEndpoint: VoWLANEndpoint?

    func startBrowsing() {
        guard VoWLANCredentialStore.load() != nil else {
            stopBrowserSession()
            availability = .unpaired
            return
        }
        guard let generation = browserLifecycle.startIfNeeded() else { return }
        beginBrowsing(generation: generation)
    }

    func restartBrowsing() {
        guard VoWLANCredentialStore.load() != nil else {
            stopBrowserSession()
            availability = .unpaired
            return
        }
        let generation = browserLifecycle.restart()
        stopCurrentBrowser()
        discoveredEndpoint = nil
        beginBrowsing(generation: generation)
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "browser_restarted",
                title: "VoWLAN 浏览器已重建",
                fields: ["generation": String(generation)]
            )
        }
    }

    private func beginBrowsing(generation: UInt64) {
        availability = .discovering
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let active = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_airsim-vowlan._tcp", domain: nil),
            using: parameters
        )
        active.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoint = results.lazy.compactMap(Self.parse).first
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.browserLifecycle.accepts(generation) else { return }
                if let endpoint {
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
                    self.discoveredEndpoint = nil
                    self.availability = .unavailable("局域网已断开")
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
        if VoWLANCredentialStore.load() != nil { availability = .discovering }
    }

    private func stopBrowserSession() {
        browserLifecycle.stop()
        stopCurrentBrowser()
        discoveredEndpoint = nil
    }

    private func stopCurrentBrowser() {
        let active = browser
        browser = nil
        active?.browseResultsChangedHandler = nil
        active?.stateUpdateHandler = nil
        active?.cancel()
    }

    func refreshAfterPairing() async {
        startBrowsing()
        await probeNow()
    }

    func probeNow() async {
        guard let endpoint = availability.endpoint ?? discoveredEndpoint else { return }
        guard let credential = VoWLANCredentialStore.load() else {
            availability = .unpaired
            return
        }
        do {
            let (data, response) = try await VoWLANProbeRecovery.run {
                let signed = try VoWLANRequestSigner(secret: credential.secret).sign(
                    method: "GET", path: "/v1/health", body: Data()
                )
                var request = URLRequest(url: endpoint.controlBaseURL.appendingPathComponent("v1/health"))
                request.timeoutInterval = 3
                request.cachePolicy = .reloadIgnoringLocalCacheData
                Self.apply(signed, to: &request)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = false
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                return try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true else {
                throw VoWLANControllerError.authenticationFailed
            }
            availability = .verified(endpoint, at: Date())
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "verified",
                title: "VoWLAN 签名健康检查通过",
                fields: ["host": endpoint.host, "control_port": String(endpoint.controlPort)]
            )
        } catch {
            availability = .unavailable(VoWLANProbeRecovery.userFacingMessage(for: error))
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "failed",
                title: "VoWLAN 健康检查失败", detail: error.localizedDescription,
                isFailure: true
            )
        }
    }

    nonisolated static func apply(_ signed: VoWLANSignedRequest, to request: inout URLRequest) {
        request.setValue("1", forHTTPHeaderField: "X-AirSIM-VoWLAN-Version")
        request.setValue(String(signed.timestamp), forHTTPHeaderField: "X-AirSIM-VoWLAN-Timestamp")
        request.setValue(signed.nonce, forHTTPHeaderField: "X-AirSIM-VoWLAN-Nonce")
        request.setValue(signed.signature, forHTTPHeaderField: "X-AirSIM-VoWLAN-Signature")
    }

    private nonisolated static func parse(_ result: NWBrowser.Result) -> VoWLANEndpoint? {
        guard case let .bonjour(record) = result.metadata,
              record["v"] == "1", let host = record["host"],
              let controlText = record["control_port"], let control = UInt16(controlText),
              let pcmText = record["pcm_port"], let pcm = UInt16(pcmText) else { return nil }
        return try? VoWLANEndpoint(host: host, controlPort: control, pcmPort: pcm)
    }
}
