import Foundation

struct LocalCallControlBody: Encodable {
    let callID: String?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
    }
}

enum LocalAgentRoute: Equatable, Sendable {
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)

    var baseURL: URL {
        switch self {
        case let .vowlan(endpoint, _):
            return endpoint.controlBaseURL
        }
    }

    var traceDescription: String {
        switch self {
        case let .vowlan(endpoint, _): return endpoint.usesTLS ? "VoWLAN · 自建 TLS 直连" : VoWLANNetworkRoutePolicy.isOverlayHost(endpoint.host)
            ? "VoWLAN · VPN 直连" : "VoWLAN · 同一局域网"
        }
    }

    var credential: VoWLANCredential? {
        guard case let .vowlan(_, credential) = self else { return nil }
        return credential
    }
}

enum AirSIMRoutePolicy {
    static func permits(_ route: LocalAgentRoute) -> Bool {
        if case .vowlan = route { return true }
        return false
    }
}

/// 统一封装模块代理 HTTP API；接口路径与 AirSIM Mac 版保持一致。
protocol AirSIMHTTPTransport: Sendable {
    func send(_ request: URLRequest, uploadFileURL: URL?) async throws -> WiredHTTPResponse
}
extension WiredHTTPTransport: AirSIMHTTPTransport {}

struct AirSIMAPI: Sendable {
    /// Android Telecom 最长等待 12 秒确认；VoWLAN 必须晚于 Agent 的确认窗口超时，
    /// 否则 iPhone 会把仍在执行的非幂等拨号误判为失败并可能触发重复呼叫。
    static let voWLANDialTimeout: TimeInterval = 15

    let baseURL: URL
    let route: LocalAgentRoute
    private let transport: any AirSIMHTTPTransport

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

    init(route: LocalAgentRoute, transport: (any AirSIMHTTPTransport)? = nil) {
        self.route = route
        let baseURL = route.baseURL
        // TLS endpoints are explicitly constructed for a paired remote gateway;
        // keep the legacy local URL whitelist unchanged for other callers.
        precondition(Self.isAllowedLocalURL(baseURL) || {
            if case let .vowlan(endpoint, _) = route { return endpoint.usesTLS }
            return false
        }(), "Agent 地址必须是本地 HTTP 或已配对的 TLS 网关")
        self.baseURL = baseURL
        self.transport = transport ?? WiredHTTPTransport()
    }

    /// 限制高权限控制接口只能指向环回或私有网络，避免误发到公网主机。
    static func isAllowedLocalURL(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        return VoWLANEndpoint.permitsDirectIPv4(host)
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
            try await post(
                "api/calls/dial",
                ["number": number],
                timeout: Self.voWLANDialTimeout
            )
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
    func dialOwnedCall(number: String, operationID: String,
                       simAccount: String? = nil) async throws -> DeviceBackendCall {
        struct Receipt: Decodable {
            let operation_id: String?
            let android_id: String?
            let backend_id: String?
            let operation_proof: String?
        }
        guard let credential = route.credential else { throw DeviceCallRoutingError.unavailable }
        let nonce = VoWLANRequestSigner.makeNonce()
        var request = URLRequest(url: endpoint("api/calls/dial"))
        request.httpMethod = "POST"
        var payload: [String: Any] = ["number": number, "operation_id": operationID]
        if let simAccount, !simAccount.isEmpty { payload["sim_account"] = simAccount }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.voWLANDialTimeout
        let response = try await tracedResponse(for: request, authenticationNonce: nonce)
        try Self.requireSuccess(response)
        let receipt = try JSONDecoder().decode(Receipt.self, from: response.body)
        guard receipt.operation_id == operationID, let androidID = receipt.android_id,
              let backendID = receipt.backend_id,
              VoWLANHealthProof.verifyDial(receipt.operation_proof, nonce: nonce, operationID: operationID,
                androidID: androidID, backendID: backendID, credential: credential) else { throw DeviceCallRoutingError.unsupportedPeer }
        return DeviceBackendCall(callID: androidID, backendID: backendID, generation: nil)
    }
    func answerCall(callID: String? = nil) async throws {
        try await post("api/calls/answer", LocalCallControlBody(callID: callID))
    }
    func rejectCall(callID: String? = nil) async throws -> RejectResponse {
        try await postDecoded("api/calls/reject", LocalCallControlBody(callID: callID))
    }
    func hangupCall(callID: String? = nil) async throws {
        try await post("api/calls/hangup", LocalCallControlBody(callID: callID))
    }
    func sendDTMF(_ digit: String, callID: String? = nil) async throws {
        var body = ["digit": digit]
        if let callID { body["call_id"] = callID }
        try await post("api/calls/dtmf", body)
    }
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

    func sendSMS(to phone: String, message: String, simAccount: String? = nil) async throws -> SMSSendResult {
        var payload = ["phone": phone, "message": message]
        if let simAccount, !simAccount.isEmpty { payload["sim_account"] = simAccount }
        return try await postDecoded("api/sms/send", payload, timeout: 80)
    }
    func refreshSMS() async throws { try await post("api/sms/refresh", EmptyBody()) }
    func clearModuleSMS() async throws { try await post("api/sms/clear-module", EmptyBody()) }
    func setSMSAutoCleanup(_ enabled: Bool) async throws {
        try await send("PATCH", "api/sms/settings", ["auto_cleanup_me": enabled])
    }

    // MARK: 状态、网络、定位与调试

    func modemStatus() async throws -> ModemStatus { try await get("api/status") }
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
        recordVerboseTrace: Bool = true,
        authenticationNonce: String? = nil
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
                bodyBytes: uploadFileURL == nil ? (request.httpBody?.count ?? 0) : uploadBytes,
                category: route.credential == nil ? "http" : "vowlan"
            )
            : nil
        if let trace {
            request.setValue(trace.id, forHTTPHeaderField: "X-AirSIM-Trace-ID")
            await AgentVerboseTraceRecorder.shared.recordRoute(
                trace,
                route: route.traceDescription,
                attempt: 1
            )
        }
        if let credential = route.credential {
            let body = request.httpBody ?? Data()
            let signed = try VoWLANRequestSigner(credential: credential).sign(
                method: method,
                path: path,
                body: body,
                nonce: authenticationNonce ?? VoWLANRequestSigner.makeNonce()
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
                await AgentVerboseTraceRecorder.shared.recordFailure(category: route.credential == nil ? "http" : "vowlan",
                    phase: "http_request", error: error)
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
