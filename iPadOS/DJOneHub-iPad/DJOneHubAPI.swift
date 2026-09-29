import Foundation

enum LocalAgentRoute: Equatable, Sendable {
    case moduleLocal
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)

    var baseURL: URL {
        switch self {
        case .moduleLocal:
            return URL(string: "http://192.168.225.1:7575/")!
        case let .vowlan(endpoint, _):
            return endpoint.controlBaseURL
        }
    }

    var traceDescription: String {
        switch self {
        case .moduleLocal: return "USB ECM · 固定模块私网"
        case .vowlan: return "VoWLAN · 同一局域网"
        }
    }

    var credential: VoWLANCredential? {
        guard case let .vowlan(_, credential) = self else { return nil }
        return credential
    }
}

/// AirSIM 不允许把大疆 USB ECM 地址当作三星控制通道。
enum AirSIMRoutePolicy {
    static func permits(_ route: LocalAgentRoute) -> Bool {
        if case .vowlan = route { return true }
        return false
    }
}

/// 统一封装模块代理 HTTP API；接口路径与 DJOneHub Mac 版保持一致。
struct DJOneHubAPI: Sendable {
    let baseURL: URL
    let route: LocalAgentRoute
    private let transport: WiredHTTPTransport

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ISO 8601 date: \(value)"
            )
        }
        return decoder
    }

    private static let decoder = makeDecoder()

    init(route: LocalAgentRoute = .moduleLocal) {
        self.route = route
        let baseURL = route.baseURL
        precondition(Self.isAllowedLocalURL(baseURL), "模块代理地址必须是本地 HTTP 地址")
        self.baseURL = baseURL
        self.transport = WiredHTTPTransport(policy: route == .moduleLocal ? .moduleLocal : .vowlan)
    }

    init(baseURL: URL) {
        precondition(baseURL == LocalAgentRoute.moduleLocal.baseURL, "请通过 LocalAgentRoute 配置动态本地地址")
        self.init(route: .moduleLocal)
    }

    /// 限制高权限控制接口只能指向环回或私有网络，避免误发到公网主机。
    private static func isAllowedLocalURL(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        guard host.hasPrefix("172."), let second = Int(host.split(separator: ".").dropFirst().first ?? "") else {
            return false
        }
        return (16...31).contains(second)
    }

    // MARK: 通话与短信

    func health() async throws -> AgentHealth { try await get("api/health") }
    func callStatus() async throws -> CallStatus { try await get("api/calls/status") }
    func waitForAgentEvent(after revision: UInt64, timeout: TimeInterval = 15) async throws -> AgentEventStatus {
        let boundedTimeout = min(30, max(1, timeout))
        var components = URLComponents(
            url: endpoint("api/events"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "after", value: String(revision)),
            URLQueryItem(name: "timeout_ms", value: String(Int(boundedTimeout * 1_000)))
        ]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = boundedTimeout + 5
        return try await decoded(request)
    }
    func waitForCallEvent(after revision: UInt64, timeout: TimeInterval = 25) async throws -> CallStatus {
        let boundedTimeout = min(30, max(1, timeout))
        var components = URLComponents(
            url: endpoint("api/calls/events"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "after", value: String(revision)),
            URLQueryItem(name: "timeout_ms", value: String(Int(boundedTimeout * 1_000)))
        ]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = boundedTimeout + 5
        return try await decoded(request)
    }
    func messages() async throws -> [SMSMessage] { try await get("api/sms") }
    func acknowledgeCallHistory(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await post("api/calls/history/ack", ["ids": ids])
    }
    func acknowledgeMessages(ids: [String]) async throws {
        let validIDs = ids.filter { !$0.isEmpty }
        guard !validIDs.isEmpty else { return }
        try await post("api/sms/ack", ["ids": validIDs])
    }
    func smsStatus() async throws -> SMSStatus { try await get("api/sms/status") }
    func simIdentity() async throws -> SIMIdentity { try await get("api/sim/identity") }
    func registerVoIPPush(_ registration: AgentPushRegistration) async throws {
        try await post("api/push/register", registration)
    }
    func pushStatus() async throws -> AgentPushStatus { try await get("api/push/status") }
    func setPushCloudEnabled(_ enabled: Bool) async throws {
        try await post("api/push/mode", ["enabled": enabled])
    }

    func dial(number: String) async throws {
        do {
            try await post("api/calls/dial", ["number": number])
        } catch {
            let originalError = error
            // ATD 是非幂等操作：响应连接被模块重置后只能查询状态确认，绝对不能自动重发。
            for delay in [0.25, 0.5, 1.0, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard let status = try? await callStatus(), let call = status.active else { continue }
                let expectedState = ["dialing", "alerting", "active", "held"].contains(call.state)
                let expectedNumber = call.number?.isEmpty != false || call.number == number
                if call.direction == "outgoing", expectedState, expectedNumber { return }
            }
            throw originalError
        }
    }
    func answerCall() async throws { try await post("api/calls/answer", EmptyBody()) }
    func rejectCall() async throws -> RejectResponse { try await postDecoded("api/calls/reject", EmptyBody()) }
    func hangupCall() async throws { try await post("api/calls/hangup", EmptyBody()) }
    func sendDTMF(_ digit: String) async throws { try await post("api/calls/dtmf", ["digit": digit]) }
    func setAudioMuted(_ muted: Bool) async throws { try await post("api/calls/audio/mute", ["muted": muted]) }
    func setCallRecording(_ recording: Bool) async throws -> CallRecordingResponse {
        try await postDecoded("api/calls/audio/record", ["action": recording ? "start" : "stop"])
    }
    func setAudioHostEnabled(_ enabled: Bool) async throws {
        try await post("api/calls/audio/host/register", ["enabled": enabled])
    }
    func warmAudioHost() async throws {
        try await post("api/calls/audio/host/warmup", EmptyBody())
    }
    func audioHostConfig() async throws -> MaVoAudioHostConfig { try await get("api/calls/audio/host/config") }

    func sendSMS(to phone: String, message: String) async throws -> SMSSendResult {
        try await postDecoded("api/sms/send", ["phone": phone, "message": message], timeout: 12)
    }
    func refreshSMS() async throws { try await post("api/sms/refresh", EmptyBody()) }
    func clearModuleSMS() async throws { try await post("api/sms/clear-module", EmptyBody()) }
    func setSMSAutoCleanup(_ enabled: Bool) async throws {
        try await send("PATCH", "api/sms/settings", ["auto_cleanup_me": enabled])
    }

    // MARK: 状态、网络、定位与调试

    func modemStatus() async throws -> ModemStatus { try await get("api/status") }
    func networkTraffic() async throws -> NetworkTrafficSnapshot { try await get("api/network/traffic") }
    func systemPower() async throws -> SystemPowerStatus { try await get("api/system/power") }
    func cellularPolicy() async throws -> CellularPolicyStatus { try await get("api/network/cellular-policy") }
    func setCellularPolicy(forceOff: Bool) async throws -> CellularPolicyStatus {
        try await postDecoded("api/network/cellular-policy", ["force_off": forceOff])
    }
    func check4GRoute() async throws -> NetworkCheckResult { try await postDecoded("api/network/check-4g", EmptyBody()) }
    func checkProxyRoute() async throws -> NetworkCheckResult { try await postDecoded("api/network/check-proxy", EmptyBody()) }
    func rebootModule() async throws { try await post("api/network/reboot-module", EmptyBody()) }
    func networkDiagnostic() async throws -> NetworkDiagnostic { try await get("api/network") }
    func routerStatus() async throws -> RouterStatus { try await get("api/router/status") }
    func saveRouterConfig(_ config: RouterConfig) async throws -> RouterConfigApplyResponse {
        try await postDecoded("api/router/config", config)
    }
    func setRouterInternet(_ enabled: Bool) async throws -> RouterInternetResponse {
        try await postDecoded("api/router/internet", ["enabled": enabled])
    }
    func resetRouterQuota() async throws { try await post("api/router/quota/reset", EmptyBody()) }
    func repairRouter() async throws -> RouterRepairResponse {
        try await postDecoded("api/router/repair", EmptyBody())
    }
    func routerClients() async throws -> RouterClientsResponse { try await get("api/router/clients") }
    func usbProfile() async throws -> USBProfileStatus { try await get("api/usb/profile") }
    func setUSBProfile(_ mode: String) async throws -> USBProfileStatus {
        try await postDecoded("api/usb/profile", ["mode": mode])
    }
    func gpsStatus() async throws -> GPSStatus { try await get("api/gps") }
    func gpsStart() async throws -> GPSControlResponse { try await postDecoded("api/gps/start", EmptyBody()) }
    func gpsStop() async throws -> GPSControlResponse { try await postDecoded("api/gps/stop", EmptyBody()) }
    func gpsRefresh() async throws -> GPSFixSummary { try await postDecoded("api/gps/refresh", EmptyBody()) }
    func executeAT(_ command: String) async throws -> ATResult { try await postDecoded("api/at", ["command": command]) }
    func moduleDebug(after sequence: UInt64 = 0, limit: Int = 400) async throws -> ModuleDebugSnapshot {
        var components = URLComponents(url: endpoint("api/debug"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "after", value: String(sequence)),
            URLQueryItem(name: "limit", value: String(min(2_000, max(1, limit))))
        ]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        return try await decoded(request, recordVerboseTrace: false)
    }
    func clearModuleDebug() async throws { try await post("api/debug/clear", EmptyBody()) }

    // MARK: eSIM、模块初始化与语音运行时

    func esimOverview() async throws -> ESIMOverview { try await get("api/esim") }
    func esimHealth() async throws -> ESIMHealth { try await get("api/esim/health") }
    func esimNotes() async throws -> [String: ESIMNote] {
        let response: ESIMNotesResponse = try await get("api/esim/notes")
        return response.notes
    }
    func switchESIM(iccid: String, aid: String) async throws -> ESIMSwitchResult {
        try await postDecoded("api/esim/switch", ["iccid": iccid, "aid": aid])
    }
    func renameESIMProfile(iccid: String, aid: String, name: String) async throws {
        try await send("PATCH", "api/esim/profile", ["iccid": iccid, "aid": aid, "name": name])
    }
    func deleteESIMProfile(iccid: String, aid: String) async throws {
        try await send("DELETE", "api/esim/profile", ["iccid": iccid, "aid": aid])
    }
    func saveESIMNote(iccid: String, label: String, phone: String, tags: String) async throws {
        try await post("api/esim/notes", ["iccid": iccid, "label": label, "phone": phone, "tags": tags])
    }
    func probeESIMPhonebook() async throws -> ESIMPhonebookProbe {
        try await postDecoded("api/esim/phonebook/probe", EmptyBody())
    }
    func downloadESIMProfile(smdp: String, matchingID: String, confirmationCode: String, imei: String, aid: String) async throws -> ESIMDownloadResult {
        try await postDecoded(
            "api/esim/download",
            ["smdp": smdp, "matching_id": matchingID, "confirmation_code": confirmationCode, "imei": imei, "aid": aid],
            timeout: 180
        )
    }
    func moduleSetupStatus() async throws -> ModuleSetupStatus { try await get("api/module/setup") }
    func initializeModule() async throws -> ModuleSetupStatus {
        try await postDecoded("api/module/setup", ["confirm": true], timeout: 120)
    }
    func voiceRuntimeStatus() async throws -> VoiceRuntimeStatus { try await get("api/voice/status") }
    func provisionVoiceRuntime() async throws -> VoiceRuntimeStatus {
        try await postDecoded("api/voice/provision", ["confirm": true], timeout: 180)
    }
    func moduleUpdateStatus() async throws -> ModuleUpdateStatus {
        try await get("api/system/update")
    }

    func moduleUpdateInstallationState() async throws -> ModuleUpdateInstallationState {
        try await get("api/system/update/status")
    }

    func moduleUpdateLog(after offset: Int64) async throws -> ModuleUpdateLogChunk {
        var components = URLComponents(url: endpoint("api/system/update/log"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(max(0, offset)))]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        return try await decoded(request)
    }

    /// 上传 App 内置的已签名模块更新包；使用文件流避免把 6 MB 运行时一次性放入内存。
    func uploadModuleUpdate(
        from fileURL: URL,
        mode: ModuleUpdateInstallMode = .normal
    ) async throws -> ModuleUpdateResult {
        var request = URLRequest(url: endpoint("api/system/update"))
        request.httpMethod = "POST"
        request.setValue("application/vnd.djonehub.update+gzip", forHTTPHeaderField: "Content-Type")
        request.setValue(mode.rawValue, forHTTPHeaderField: "X-DJOneHub-Update-Mode")
        request.timeoutInterval = 180
        let response = try await tracedResponse(for: request, uploadFileURL: fileURL)
        try Self.requireSuccess(response)
        return try Self.decode(ModuleUpdateResult.self, from: response.body)
    }

    /// App 已在本地核对 SHA-256 与 Agent 公钥后，若模块仍报告签名无效，
    /// 视为一次 USB 传输损坏并仅重传一次；第二次失败原样返回，绝不循环安装。
    func uploadVerifiedModuleUpdate(
        from fileURL: URL,
        mode: ModuleUpdateInstallMode
    ) async throws -> ModuleUpdateResult {
        do {
            return try await uploadModuleUpdate(from: fileURL, mode: mode)
        } catch {
            guard ModuleUpdatePolicy.shouldRetryVerifiedPackage(message: error.localizedDescription) else {
                throw error
            }
            try await Task.sleep(for: .milliseconds(350))
            return try await uploadModuleUpdate(from: fileURL, mode: mode)
        }
    }

    /// iPad 直连模式下，“完全退出”等价为停止模块内代理；模块重启后由 init 自动恢复。
    func shutdownModuleAgent() async throws {
        try await post("api/service/shutdown", ["confirm": true])
    }

    // MARK: HTTP 公共实现

    private func endpoint(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        var request = URLRequest(url: endpoint(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        return try await decoded(request)
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body, timeout: TimeInterval = 8) async throws {
        _ = try await raw(method: "POST", path: path, body: body, timeout: timeout)
    }

    private func postDecoded<Response: Decodable, Body: Encodable>(
        _ path: String,
        _ body: Body,
        timeout: TimeInterval = 8
    ) async throws -> Response {
        let data = try await raw(method: "POST", path: path, body: body, timeout: timeout)
        return try Self.decode(Response.self, from: data)
    }

    private func send<Body: Encodable>(_ method: String, _ path: String, _ body: Body) async throws {
        _ = try await raw(method: method, path: path, body: body, timeout: 10)
    }

    private func raw<Body: Encodable>(method: String, path: String, body: Body, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeout
        let response = try await tracedResponse(for: request)
        try Self.requireSuccess(response)
        return response.body
    }

    private func decoded<Response: Decodable>(
        _ request: URLRequest,
        recordVerboseTrace: Bool = true
    ) async throws -> Response {
        let response = try await tracedResponse(for: request, recordVerboseTrace: recordVerboseTrace)
        try Self.requireSuccess(response)
        return try Self.decode(Response.self, from: response.body)
    }

    private func tracedResponse(
        for originalRequest: URLRequest,
        uploadFileURL: URL? = nil,
        recordVerboseTrace: Bool = true
    ) async throws -> WiredHTTPResponse {
        var request = originalRequest
        let method = request.httpMethod?.uppercased() ?? "GET"
        let path: String = {
            guard let url = request.url else { return "--" }
            return url.path + (url.query.map { "?\($0)" } ?? "")
        }()
        let uploadBytes: Int = {
            guard let uploadFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: uploadFileURL.path),
                  let size = attributes[.size] as? NSNumber else { return 0 }
            return size.intValue
        }()
        let trace = recordVerboseTrace
            ? await AgentVerboseTraceRecorder.shared.begin(
                method: method,
                path: path,
                bodyBytes: uploadFileURL == nil ? (request.httpBody?.count ?? 0) : uploadBytes
            )
            : nil
        if let trace {
            request.setValue(trace.id, forHTTPHeaderField: "X-DJOneHub-Trace-ID")
            await AgentVerboseTraceRecorder.shared.recordRoute(
                trace,
                route: route.traceDescription,
                attempt: 1
            )
        }
        if let credential = route.credential {
            let body = request.httpBody ?? Data()
            let signed = try VoWLANRequestSigner(secret: credential.secret).sign(
                method: method,
                path: path,
                body: body
            )
            VoWLANController.apply(signed, to: &request)
        }
        do {
            let response = try await transport.send(request, uploadFileURL: uploadFileURL)
            if let trace {
                await AgentVerboseTraceRecorder.shared.finish(
                    trace,
                    statusCode: response.statusCode,
                    responseBytes: response.body.count
                )
            }
            return response
        } catch {
            if let trace {
                await AgentVerboseTraceRecorder.shared.fail(trace, error: error.localizedDescription)
            }
            throw error
        }
    }

    private static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.unreadablePayload("模块代理返回的数据无法识别：\(error.localizedDescription)")
        }
    }

    private static func requireSuccess(_ response: WiredHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(APIErrorPayload.self, from: response.body))?.error
            throw APIError.http(response.statusCode, message)
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case http(Int, String?)
    case unreadablePayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "模块代理返回了无效响应"
        case let .http(status, message): return message?.isEmpty == false ? message : "请求失败（HTTP \(status)）"
        case let .unreadablePayload(message): return message
        }
    }
}

private struct APIErrorPayload: Decodable { let error: String? }
private struct EmptyBody: Encodable {}
