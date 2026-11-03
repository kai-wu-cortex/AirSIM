import Foundation
import Network
import CryptoKit

struct SamsungManualPairingAddress: Equatable, Sendable {
    let host: String
    let port: UInt16
    init(host: String, port: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoWLANEndpoint.permitsDirectIPv4(host), !portText.isEmpty,
              portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(portText), port > 0 else { throw SamsungPairingClientError.invalidAddress }
        self.host = host
        self.port = port
    }
    var endpoint: NWEndpoint { .hostPort(host: .init(host), port: .init(rawValue: port)!) }
}

enum SamsungDirectRouteProof {
    static func verify(_ proof: String, secret: Data, sessionID: String, clientKey: String,
                       agentID: String, controlPort: UInt16, pcmPort: UInt16) -> Bool {
        guard secret.count >= 32, let mac = Data(base64URL: proof) else { return false }
        let canonical = "AIRSIM-DIRECT1\n\(sessionID)\n\(clientKey)\n\(agentID)\n\(controlPort)\n\(pcmPort)"
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(canonical.utf8),
                                                     using: SymmetricKey(data: secret))
    }
}

struct SamsungPairingService: Identifiable {
    let endpoint: NWEndpoint
    let sessionID: String
    let serverPublicKey: Data
    let expiresAt: Date
    /// Standalone accepts an end-to-end encrypted SMS key (TXT `e2e=1`, issue #24).
    var supportsE2ESMS = false

    var id: String { sessionID }
    var displayName: String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return "Android Phone Bridge"
    }
}

protocol SamsungPairingBrowsing: AnyObject {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)? { get set }
    var browseResultsChangedHandler: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

extension NWBrowser: SamsungPairingBrowsing {}

@MainActor
final class SamsungPairingBrowser: ObservableObject {
    @Published private(set) var services: [SamsungPairingService] = []
    @Published private(set) var stateText = "正在扫描 VoWLAN 局域网…"

    private let queue = DispatchQueue(label: "com.airsim.samsung-pair.browser")
    private var browser: SamsungPairingBrowsing?
    private let makeBrowser: (NWParameters) -> SamsungPairingBrowsing
    private var scanID: UUID?

    init(makeBrowser: @escaping (NWParameters) -> SamsungPairingBrowsing = {
        NWBrowser(for: .bonjourWithTXTRecord(type: "_airsim-pair._tcp", domain: nil), using: $0)
    }) {
        self.makeBrowser = makeBrowser
    }

    func start() {
        guard browser == nil else { return }
        let scanID = UUID()
        self.scanID = scanID
        services = []
        stateText = "正在扫描 VoWLAN 局域网…"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let active = makeBrowser(parameters)
        active.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.scanID == scanID else { return }
                switch state {
                case .ready: self.stateText = "正在等待安卓配对广播…"
                case .waiting: self.stateText = "请确认 iPhone 与安卓处于同一 Wi-Fi 或安卓热点"
                case .failed(let error):
                    self.stop()
                    self.stateText = "局域网扫描失败：\(error.localizedDescription)。请检查本地网络权限后重新扫描。"
                case .cancelled: self.stop()
                default: break
                }
            }
        }
        active.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = results.compactMap(Self.parse)
                .filter { $0.expiresAt > Date() }
                .sorted { $0.expiresAt < $1.expiresAt }
            Task { @MainActor in
                guard let self, self.scanID == scanID else { return }
                self.services = parsed
                self.stateText = parsed.isEmpty
                    ? "正在等待安卓配对广播…"
                    : "已发现 \(parsed.count) 台待配对设备"
            }
        }
        browser = active
        active.start(queue: queue)
    }

    func stop() {
        // Invalidate before cancel: Network.framework can deliver callbacks after cancellation.
        scanID = nil
        browser?.cancel()
        browser = nil
        services = []
        stateText = "扫描已停止"
    }

    func restart() {
        stop()
        start()
    }

    private nonisolated static func parse(_ result: NWBrowser.Result) -> SamsungPairingService? {
        guard case let .bonjour(record) = result.metadata else { return nil }
        return service(endpoint: result.endpoint, record: record)
    }

    nonisolated static func service(endpoint: NWEndpoint, record: NWTXTRecord) -> SamsungPairingService? {
        guard record["v"] == "1",
              let sessionID = record["session"],
              let keyText = record["key"],
              let serverPublicKey = Data(base64URL: keyText),
              serverPublicKey.count == 32,
              let expiresText = record["expires"],
              let expiresMillis = Double(expiresText) else { return nil }
        return SamsungPairingService(
            endpoint: endpoint,
            sessionID: sessionID,
            serverPublicKey: serverPublicKey,
            expiresAt: Date(timeIntervalSince1970: expiresMillis / 1_000),
            supportsE2ESMS: record["e2e"] == "1"
        )
    }
}

@MainActor
final class SamsungPairingRegistrationGate {
    private var activeAgentWrites = 0
    private var pairing = false

    func beginAgentWrite() -> Bool {
        guard !pairing else { return false }
        activeAgentWrites += 1
        return true
    }

    func endAgentWrite() { activeAgentWrites -= 1 }

    func withPairing<T>(_ operation: () async throws -> T) async throws -> T {
        guard !pairing else { throw SamsungPairingClientError.pairingBusy }
        pairing = true
        defer { pairing = false }
        // Wait only for local Agent writes, never for an unrelated Relay request.
        while activeAgentWrites > 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        return try await operation()
    }
}

enum SamsungPairingRegistrationPolicy {
    static func registration(
        localOnly: Bool,
        vowlanSecret: String,
        notificationForwarding: NotificationForwardingConfig? = nil,
        cloudRegistration: () -> AgentPushRegistration?
    ) throws -> AgentPushRegistration {
        if localOnly {
            return .local(
                vowlanSecret: vowlanSecret,
                notificationForwarding: notificationForwarding
            )
        }
        guard var registration = cloudRegistration(), !registration.localMode else {
            throw SamsungPairingClientError.registrationUnavailable
        }
        registration.vowlanSecret = vowlanSecret
        return registration
    }
}

enum SamsungPairingClient {
    typealias Transport = @Sendable (NWEndpoint, Data, String, String, TimeInterval) async throws -> Data
    static let networkTransport: Transport = { endpoint, body, method, path, timeout in
        try await exchange(endpoint: endpoint, body: body, method: method, path: path, timeout: timeout)
    }
    struct ManualResult {
        let message: String
        let route: VoWLANManualRoute
        /// Server clock minus local clock, captured while the pairing window is open.
        let clockOffset: TimeInterval
        /// The E2E SMS key sealed into the claim, if both sides negotiated one.
        let e2eKey: SymmetricKey?
    }

    private struct SessionInfo: Decodable {
        let product: String
        let version: Int
        let sessionID: String
        let serverPublicKey: String
        let expiresAt: Double
        let serverTime: Double?
        let capabilities: CapabilityFlags?
        enum CodingKeys: String, CodingKey {
            case product, version
            case sessionID = "session_id", serverPublicKey = "server_public_key", expiresAt = "expires_at"
            case serverTime = "server_time"
            case capabilities
        }
    }

    /// The claim's plaintext: the registration exactly as encoded elsewhere, plus `e2e_key`. The key
    /// never becomes part of the registration, which is also sent unsealed after pairing.
    private struct SealedRegistration: Encodable {
        let registration: AgentPushRegistration
        let e2eKey: SymmetricKey?
        enum CodingKeys: String, CodingKey { case e2eKey = "e2e_key" }

        func encode(to encoder: Encoder) throws {
            try registration.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(e2eKey.map { key in E2ESMS.base64URL(key.withUnsafeBytes { Data($0) }) },
                                       forKey: .e2eKey)
        }
    }
    private struct Claim: Encodable {
        let version = 1
        let sessionID: String
        let clientPublicKey: String
        let sealedRegistration: String
        let wantDirectRoute: Bool

        enum CodingKeys: String, CodingKey {
            case version
            case sessionID = "session_id"
            case clientPublicKey = "client_public_key"
            case sealedRegistration = "sealed_registration"
            case wantDirectRoute = "want_direct_route"
        }
    }

    private struct Response: Decodable {
        let configured: Bool
        let deviceIDHint: String?
        let agentID: String?
        let controlPort: UInt16?
        let pcmPort: UInt16?
        let routeProof: String?
        enum CodingKeys: String, CodingKey {
            case configured
            case deviceIDHint = "device_id_hint"
            case agentID = "agent_id"
            case controlPort = "control_port", pcmPort = "pcm_port", routeProof = "route_proof"
        }
    }

    struct PairedDeviceResult {
        let agentID: String
        let message: String
        /// The E2E SMS key sealed into the claim, if both sides negotiated one.
        let e2eKey: SymmetricKey?
    }
    static func pairDevice(service: SamsungPairingService, code: String,
                           registration: AgentPushRegistration, offerE2E: Bool = false) async throws -> PairedDeviceResult {
        let e2eKey = offerE2E && service.supportsE2ESMS ? E2ESMS.newKey() : nil
        let (response, _) = try await claim(service: service, code: code, registration: registration,
                                            e2eKey: e2eKey, direct: false)
        guard let agentID = response.agentID, !agentID.isEmpty else { throw SamsungPairingClientError.directGatewayUnavailable }
        PairedAndroidDeviceStore.allowPairing(agentID)
        return PairedDeviceResult(agentID: agentID,
            message: response.deviceIDHint.map { "配对成功（设备 …\($0)）" } ?? "配对成功", e2eKey: e2eKey)
    }
    static func pair(service: SamsungPairingService, code: String, registration: AgentPushRegistration) async throws -> String {
        try await pairDevice(service: service, code: code, registration: registration).message
    }

    static func pairManually(address: SamsungManualPairingAddress, code: String,
                             registration: AgentPushRegistration, offerE2E: Bool = false,
                             transport: Transport = networkTransport) async throws -> ManualResult {
        let data = try await transport(address.endpoint, Data(), "GET", "/pair/v1/info", 8)
        let info: SessionInfo
        do { info = try JSONDecoder().decode(SessionInfo.self, from: data) }
        catch { throw SamsungPairingClientError.manualUnsupported }
        guard info.product == "airsim-pair", info.version == 1, !info.sessionID.isEmpty,
              info.sessionID.count <= 128, let publicKey = Data(base64URL: info.serverPublicKey), publicKey.count == 32,
              info.expiresAt.isFinite else { throw SamsungPairingClientError.manualUnsupported }
        let service = SamsungPairingService(endpoint: address.endpoint, sessionID: info.sessionID,
            serverPublicKey: publicKey, expiresAt: Date(timeIntervalSince1970: info.expiresAt / 1_000),
            supportsE2ESMS: info.capabilities?.e2eSMS == true)
        let e2eKey = offerE2E && service.supportsE2ESMS ? E2ESMS.newKey() : nil
        let (response, clientKey) = try await claim(service: service, code: code, registration: registration,
                                                    e2eKey: e2eKey, direct: true, transport: transport)
        guard let agentID = response.agentID, !agentID.isEmpty,
              let controlPort = response.controlPort, let pcmPort = response.pcmPort,
              let proof = response.routeProof, let encodedSecret = registration.vowlanSecret,
              let secret = Data(base64URL: encodedSecret),
              SamsungDirectRouteProof.verify(proof, secret: secret, sessionID: service.sessionID,
                clientKey: clientKey, agentID: agentID, controlPort: controlPort, pcmPort: pcmPort) else {
            throw SamsungPairingClientError.directGatewayUnavailable
        }
        let route = VoWLANManualRoute(agentID: agentID, host: address.host, controlPort: controlPort, pcmPort: pcmPort)
        guard route.endpoint != nil else { throw SamsungPairingClientError.directGatewayUnavailable }
        // Server clock lets the signer avoid 401 when the phone and the paired
        // Android are not time-synchronised (common across Tailscale carriers).
        let clockOffset = info.serverTime.map { $0 / 1_000 - Date().timeIntervalSince1970 } ?? 0
        // Do not persist an unverified server response or silently trust an old port.
        PairedAndroidDeviceStore.allowPairing(agentID)
        return ManualResult(message: "加密配对成功，正在验证直连通话网关…", route: route,
                            clockOffset: clockOffset, e2eKey: e2eKey)
    }

    private static func claim(service: SamsungPairingService, code: String,
                              registration: AgentPushRegistration, e2eKey: SymmetricKey?, direct: Bool,
                              transport: Transport = networkTransport) async throws -> (Response, String) {
        guard code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else {
            throw SamsungPairingClientError.invalidCode
        }
        guard service.expiresAt > Date() else { throw SamsungPairingClientError.expired }
        let registrationData = try JSONEncoder().encode(SealedRegistration(registration: registration, e2eKey: e2eKey))
        let sealed = try SamsungPairingCrypto.seal(
            registration: registrationData,
            serverPublicKey: service.serverPublicKey,
            sessionID: service.sessionID,
            code: code
        )
        let body = try JSONEncoder().encode(Claim(
            sessionID: service.sessionID,
            clientPublicKey: sealed.clientPublicKey.base64URL,
            sealedRegistration: sealed.combined.base64URL,
            wantDirectRoute: direct
        ))
        let responseData = try await transport(service.endpoint, body, "POST", "/pair/v1/claim", 25)
        let response = try JSONDecoder().decode(Response.self, from: responseData)
        guard response.configured else { throw SamsungPairingClientError.rejected }
        return (response, sealed.clientPublicKey.base64URL)
    }

    private static func exchange(endpoint: NWEndpoint, body: Data, method: String = "POST",
                                  path: String = "/pair/v1/claim", timeout: TimeInterval = 25) async throws -> Data {
        let cancellation = PairingExchangeCancellation()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let state = PairingExchangeState(connection: connection, continuation: continuation)
            guard cancellation.install(state) else { return }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready: state.send(body: body, method: method, path: path)
                case .failed(let error): state.finish(.failure(error))
                case .cancelled: state.finish(.failure(SamsungPairingClientError.connectionClosed))
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.airsim.samsung-pair.claim"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak state] in
                state?.finish(.failure(SamsungPairingClientError.timedOut))
            }
          }
        } onCancel: { cancellation.cancel() }
    }
}

private final class PairingExchangeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var state: PairingExchangeState?
    private var cancelled = false
    func install(_ state: PairingExchangeState) -> Bool {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { self.state = state }
        lock.unlock()
        if wasCancelled { state.finish(.failure(CancellationError())) }
        return !wasCancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let active = state
        lock.unlock()
        active?.finish(.failure(CancellationError()))
    }
}

@MainActor
enum SamsungPairingCompletionCoordinator {
    static func complete(
        performPairing: () async throws -> String,
        refreshVoWLAN: () async -> Void
    ) async rethrows -> String {
        let message = try await performPairing()
        await refreshVoWLAN()
        return message
    }
}

private final class PairingExchangeState: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Data, Error>
    private var received = Data()
    private var finished = false
    private let lock = NSLock()
    private var metadata = false

    init(connection: NWConnection, continuation: CheckedContinuation<Data, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func send(body: Data, method: String, path: String) {
        metadata = method == "GET" && path == "/pair/v1/info"
        var request = Data("\(method) \(path) HTTP/1.1\r\nHost: airsim-pair.local\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failure(error)); return }
            self?.receive()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content { self.received.append(content) }
            if let error { self.finish(.failure(error)); return }
            if self.received.count > 65_536 { self.finish(.failure(SamsungPairingClientError.responseTooLarge)); return }
            if isComplete { self.finish(self.parseResponse()); return }
            self.receive()
        }
    }

    private func parseResponse() -> Result<Data, Error> {
        Result { try SamsungPairingHTTPResponse.decode(received, metadata: metadata) }
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

enum SamsungPairingHTTPResponse {
    static func decode(_ received: Data, metadata: Bool) throws -> Data {
        guard received.count <= 65_536,
              let range = received.range(of: Data("\r\n\r\n".utf8)), range.lowerBound <= 8_192,
              let header = String(data: received[..<range.lowerBound], encoding: .utf8) else {
            throw SamsungPairingClientError.rejected
        }
        let lines = header.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        guard status.count >= 2, status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0" else {
            throw SamsungPairingClientError.rejected
        }
        guard status[1] == "200" else {
            if status[1] == "403" { throw SamsungPairingClientError.networkNotAllowed }
            if status[1] == "410" { throw SamsungPairingClientError.expired }
            if status[1] == "404", metadata { throw SamsungPairingClientError.manualUnsupported }
            throw SamsungPairingClientError.rejected
        }
        let lengths = lines.dropFirst().filter { $0.lowercased().hasPrefix("content-length:") }
        let body = Data(received[range.upperBound...])
        guard lengths.count == 1,
              let length = Int(lengths[0].dropFirst(15).trimmingCharacters(in: .whitespaces)),
              length == body.count,
              !lines.dropFirst().contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else {
            throw SamsungPairingClientError.rejected
        }
        return body
    }
}

enum SamsungPairingClientError: LocalizedError, Equatable {
    case invalidCode, expired, rejected, responseTooLarge, connectionClosed, registrationUnavailable, pairingBusy, invalidAddress
    case manualUnsupported, directGatewayUnavailable, timedOut, networkNotAllowed
    var errorDescription: String? {
        switch self {
        case .invalidCode: return "请输入三星屏幕上的 6 位验证码"
        case .expired: return "三星配对窗口已过期，请重新开始"
        case .rejected: return "三星拒绝了配对，请核对验证码后重试"
        case .networkNotAllowed: return "安卓拒绝当前网络来源，尚未校验验证码。请更新安卓 App，并确认两端处于同一 Wi-Fi／热点或允许互访的 Tailscale 网络。"
        case .responseTooLarge: return "三星返回的数据异常"
        case .connectionClosed: return "与三星的局域网连接已断开"
        case .registrationUnavailable: return "Relay／推送配置未就绪。请先在设置完成云端配置；若只需本地连接，请打开‘本地模式配对’。"
        case .pairingBusy: return "另一个配对正在进行，请稍后重试"
        case .invalidAddress: return "请输入有效的局域网或 Tailscale IPv4 地址，以及 1–65535 的端口；不要填写 http:// 或路径。"
        case .manualUnsupported: return "该地址未返回 AirSIM 配对信息。请更新安卓 App，并填写当前一次性配对端口，而非 ADB、Relay 或通话端口。"
        case .directGatewayUnavailable: return "配对已写入，但直连通话网关未就绪或认证失败。请检查安卓默认电话角色及 PCM 桥，再开启新的配对窗口重试。"
        case .timedOut: return "连接超时。请检查 IP、当前配对端口、局域网隔离或 Tailscale 两端连接及访问规则。"
        }
    }
}

private extension Data {
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
