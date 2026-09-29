import Foundation
import Network
import Darwin

/// 模块 HTTP 响应；传输层只保留上层解码和错误处理真正需要的字段。
struct WiredHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

/// 使用 Network.framework 将模块控制请求固定到 USB ECM，避免 Wi-Fi 或 VPN 抢走私网路由。
final class WiredHTTPTransport: @unchecked Sendable {
    enum Policy: Sendable {
        case moduleLocal
        case vowlan
    }

    private let queue = DispatchQueue(label: "com.jieden.djonehub.wired-http", qos: .userInitiated)
    private let policy: Policy
    private let interfaceLock = NSLock()
    private var preferredInterfaceType: NWInterface.InterfaceType = .wiredEthernet

    init(policy: Policy = .moduleLocal) {
        self.policy = policy
    }

    static func allowsInterfaceFallback(httpMethod: String?) -> Bool {
        switch httpMethod?.uppercased() ?? "GET" {
        case "GET", "HEAD": return true
        default: return false
        }
    }

    func send(_ request: URLRequest, uploadFileURL: URL? = nil) async throws -> WiredHTTPResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw WiredHTTPError.invalidRequest
        }

        let body: WiredHTTPBody
        if let uploadFileURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: uploadFileURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw WiredHTTPError.unreadableUpload
            }
            body = .file(uploadFileURL, size.uint64Value)
        } else if let data = request.httpBody, !data.isEmpty {
            body = .data(data)
        } else {
            body = .none
        }

        if case .vowlan = policy {
            return try await sendOnce(
                request,
                host: NWEndpoint.Host(host),
                port: port,
                body: body,
                route: .type(.wifi)
            )
        }

        if let moduleInterface = ModuleUSBInterfaceResolver.resolve() {
            do {
                return try await sendOnce(
                    request,
                    host: NWEndpoint.Host(host),
                    port: port,
                    body: body,
                    route: .exact(moduleInterface)
                )
            } catch {
                guard Self.allowsInterfaceFallback(httpMethod: request.httpMethod),
                      (error as? WiredHTTPError)?.isInterfaceFailure == true else { throw error }
            }
        }

        let preferred = lockedPreferredInterface()
        do {
            return try await sendOnce(
                request,
                host: NWEndpoint.Host(host),
                port: port,
                body: body,
                route: .type(preferred)
            )
        } catch {
            guard Self.allowsInterfaceFallback(httpMethod: request.httpMethod),
                  (error as? WiredHTTPError)?.isInterfaceFailure == true else { throw error }
            let fallback: NWInterface.InterfaceType = preferred == .wiredEthernet ? .other : .wiredEthernet
            let response = try await sendOnce(
                request,
                host: NWEndpoint.Host(host),
                port: port,
                body: body,
                route: .type(fallback)
            )
            setPreferredInterface(fallback)
            return response
        }
    }

    private func sendOnce(
        _ request: URLRequest,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        body: WiredHTTPBody,
        route: WiredInterfaceRoute
    ) async throws -> WiredHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let operation = WiredHTTPRequestOperation(
                request: request,
                host: host,
                port: port,
                body: body,
                route: route,
                queue: queue,
                continuation: continuation
            )
            operation.start()
        }
    }

    private func lockedPreferredInterface() -> NWInterface.InterfaceType {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        return preferredInterfaceType
    }

    private func setPreferredInterface(_ interfaceType: NWInterface.InterfaceType) {
        interfaceLock.lock()
        preferredInterfaceType = interfaceType
        interfaceLock.unlock()
    }
}

struct NetworkInterfaceAddress: Equatable, Sendable {
    let name: String
    let address: String
}

/// 从本机 192.168.225.x 地址反查模块 USB ECM 接口。通过接口名精确绑定后，
/// 即使 VPN 改写默认路由，发往模块的请求也不会误入 utun 或 Wi-Fi。
enum ModuleUSBInterfaceResolver {
    private static let monitorQueue = DispatchQueue(label: "com.jieden.djonehub.usb-interface")

    static func moduleInterfaceNames(from addresses: [NetworkInterfaceAddress]) -> Set<String> {
        Set(addresses.compactMap { item in
            let octets = item.address.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  octets[0] == "192", octets[1] == "168", octets[2] == "225",
                  let host = Int(octets[3]), (2...254).contains(host),
                  String(host) == octets[3] else { return nil }
            return item.name
        })
    }

    static func resolve(timeout: TimeInterval = 0.35) -> NWInterface? {
        let names = moduleInterfaceNames(from: systemInterfaceAddresses())
        guard !names.isEmpty else { return nil }

        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var resolved: NWInterface?
        monitor.pathUpdateHandler = { path in
            lock.lock()
            resolved = path.availableInterfaces.first { names.contains($0.name) }
            lock.unlock()
            semaphore.signal()
        }
        monitor.start(queue: monitorQueue)
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    private static func systemInterfaceAddresses() -> [NetworkInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetworkInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
            var numericAddress = ipv4.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &numericAddress, &buffer, socklen_t(buffer.count)) != nil else { continue }
            result.append(
                NetworkInterfaceAddress(
                    name: String(cString: item.pointee.ifa_name),
                    address: String(cString: buffer)
                )
            )
        }
        return result
    }
}

private enum WiredInterfaceRoute {
    case exact(NWInterface)
    case type(NWInterface.InterfaceType)

    var description: String {
        switch self {
        case let .exact(interface): return "\(interface.name):\(interface.type)"
        case let .type(type): return String(describing: type)
        }
    }

    func matches(_ path: NWPath?) -> Bool {
        guard let path else { return false }
        switch self {
        case let .exact(interface):
            return path.availableInterfaces.contains { $0.name == interface.name }
        case let .type(type):
            return path.usesInterfaceType(type)
        }
    }
}

private enum WiredHTTPBody {
    case none
    case data(Data)
    case file(URL, UInt64)

    var length: UInt64 {
        switch self {
        case .none: return 0
        case let .data(data): return UInt64(data.count)
        case let .file(_, length): return length
        }
    }
}

/// 单次请求使用独立 TCP 连接和 `Connection: close`，避免熄屏恢复后复用已失效的 Wi-Fi 路径。
private final class WiredHTTPRequestOperation: @unchecked Sendable {
    private static let maximumResponseBytes = 32 * 1_024 * 1_024
    private static let uploadChunkBytes = 64 * 1_024

    private let request: URLRequest
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let body: WiredHTTPBody
    private let route: WiredInterfaceRoute
    private let queue: DispatchQueue
    private let continuation: CheckedContinuation<WiredHTTPResponse, Error>
    private let connection: NWConnection
    private var responseData = Data()
    private var uploadHandle: FileHandle?
    private var keepAlive: WiredHTTPRequestOperation?
    private var requestStarted = false
    private var finished = false

    init(
        request: URLRequest,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        body: WiredHTTPBody,
        route: WiredInterfaceRoute,
        queue: DispatchQueue,
        continuation: CheckedContinuation<WiredHTTPResponse, Error>
    ) {
        self.request = request
        self.host = host
        self.port = port
        self.body = body
        self.route = route
        self.queue = queue
        self.continuation = continuation

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // 优先绑定实际 USB ECM 接口；找不到接口名时才按接口类型约束。
        switch route {
        case let .exact(interface): parameters.requiredInterface = interface
        case let .type(type): parameters.requiredInterfaceType = type
        }
        connection = NWConnection(host: host, port: port, using: parameters)
    }

    func start() {
        // NWConnection 的回调使用弱引用；请求结束前由操作自持有，避免局部变量离开作用域后提前释放。
        keepAlive = self
#if DEBUG
        connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            print("[DJOneHub Network] route=\(self.route.description) status=\(path.status) reason=\(path.unsatisfiedReason) available=\(interfaces)")
        }
#endif
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.requestStarted else { return }
                guard self.route.matches(self.connection.currentPath) else {
                    self.finish(.failure(WiredHTTPError.wiredPathUnavailable))
                    return
                }
                self.requestStarted = true
                self.receiveNextChunk()
                self.sendRequest()
            case let .failed(error):
                self.finish(.failure(WiredHTTPError.connectionFailed(error.localizedDescription)))
#if DEBUG
            case let .waiting(error):
                print("[DJOneHub Network] route=\(self.route.description) waiting=\(error.localizedDescription)")
#endif
            case .cancelled:
                if !self.finished { self.finish(.failure(WiredHTTPError.connectionClosed)) }
            default:
                break
            }
        }
        connection.start(queue: queue)

        // 严格路径不匹配时连接可能一直 waiting；请求尚未发送，可安全交给上层决定是否回退。
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.finished, !self.requestStarted else { return }
            self.finish(.failure(WiredHTTPError.wiredPathUnavailable))
        }

        let timeout = max(1, request.timeoutInterval)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(.failure(WiredHTTPError.timedOut))
        }
    }

    private func sendRequest() {
        do {
            let header = try makeHeader()
            let hasBody = body.length > 0
            connection.send(
                content: header,
                contentContext: .defaultStream,
                // HTTP/1.1 已通过 Content-Length 声明请求体边界。这里不能把
                // NWConnection stream 标记完成，否则 GET 会提前半关闭 TCP，
                // Go 长轮询的 request.Context 会被取消并返回 200 空正文。
                isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.finish(.failure(WiredHTTPError.sendFailed(error.localizedDescription)))
                    } else if hasBody {
                        self.sendBody()
                    }
                }
            )
        } catch {
            finish(.failure(error))
        }
    }

    private func makeHeader() throws -> Data {
        guard let url = request.url else { throw WiredHTTPError.invalidRequest }
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            throw WiredHTTPError.invalidRequest
        }

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        guard !path.contains("\r"), !path.contains("\n") else {
            throw WiredHTTPError.invalidRequest
        }

        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = "\(host):\(port.rawValue)"
        headers["Connection"] = "close"
        headers["Accept"] = "application/json"
        headers["Content-Length"] = String(body.length)

        var lines = ["\(method) \(path) HTTP/1.1"]
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
                  !value.contains("\r"), !value.contains("\n") else {
                throw WiredHTTPError.invalidRequest
            }
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")
        guard let data = lines.joined(separator: "\r\n").data(using: .utf8) else {
            throw WiredHTTPError.invalidRequest
        }
        return data
    }

    private func sendBody() {
        switch body {
        case .none:
            break
        case let .data(data):
            send(data)
        case let .file(url, _):
            do {
                uploadHandle = try FileHandle(forReadingFrom: url)
                sendNextFileChunk()
            } catch {
                finish(.failure(WiredHTTPError.unreadableUpload))
            }
        }
    }

    private func sendNextFileChunk() {
        guard let uploadHandle else {
            finish(.failure(WiredHTTPError.unreadableUpload))
            return
        }
        do {
            let data = try uploadHandle.read(upToCount: Self.uploadChunkBytes) ?? Data()
            if data.isEmpty {
                // 文件长度已通过 Content-Length 声明，不发送 TCP FIN；服务端仍可
                // 在同一连接上返回更新结果。
                send(Data())
            } else {
                send(data) { [weak self] in self?.sendNextFileChunk() }
            }
        } catch {
            finish(.failure(WiredHTTPError.unreadableUpload))
        }
    }

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        connection.send(
            content: data,
            contentContext: .defaultStream,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(WiredHTTPError.sendFailed(error.localizedDescription)))
                } else {
                    completion?()
                }
            }
        )
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                guard self.responseData.count + data.count <= Self.maximumResponseBytes else {
                    self.finish(.failure(WiredHTTPError.responseTooLarge))
                    return
                }
                self.responseData.append(data)
            }
            if let error {
                // 模块执行 ATD 时偶尔用 RST 结束连接；若完整 HTTP 响应已经到达，应采用响应而非误报失败。
                if let response = try? WiredHTTPResponseParser.parse(self.responseData) {
                    self.finish(.success(response))
                } else {
                    self.finish(.failure(WiredHTTPError.receiveFailed(error.localizedDescription)))
                }
            } else if isComplete {
                do {
                    self.finish(.success(try WiredHTTPResponseParser.parse(self.responseData)))
                } catch {
                    self.finish(.failure(error))
                }
            } else {
                self.receiveNextChunk()
            }
        }
    }

    private func finish(_ result: Result<WiredHTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        try? uploadHandle?.close()
        uploadHandle = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
        keepAlive = nil
    }

}

/// 独立解析 HTTP/1.1 响应，便于对 Go Agent 的定长和分块响应做无网络测试。
enum WiredHTTPResponseParser {
    static func parse(_ data: Data) throws -> WiredHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let headerText = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else {
            throw WiredHTTPError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw WiredHTTPError.invalidResponse }
        let statusFields = statusLine.split(separator: " ", maxSplits: 2)
        guard statusFields.count >= 2,
              statusFields[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusFields[1]) else {
            throw WiredHTTPError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let encodedBody = Data(data[range.upperBound...])
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(encodedBody)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard length >= 0, encodedBody.count >= length else {
                throw WiredHTTPError.incompleteResponse
            }
            body = Data(encodedBody.prefix(length))
        } else {
            body = encodedBody
        }
        return WiredHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        let lineBreak = Data("\r\n".utf8)
        var cursor = data.startIndex
        var decoded = Data()

        while cursor < data.endIndex {
            guard let sizeRange = data[cursor...].range(of: lineBreak),
                  let sizeLine = String(data: data[cursor..<sizeRange.lowerBound], encoding: .ascii),
                  let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw WiredHTTPError.invalidResponse
            }
            cursor = sizeRange.upperBound
            if size == 0 { return decoded }
            guard size > 0,
                  let chunkEnd = data.index(cursor, offsetBy: size, limitedBy: data.endIndex),
                  data.distance(from: chunkEnd, to: data.endIndex) >= 2,
                  data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)] == lineBreak else {
                throw WiredHTTPError.incompleteResponse
            }
            decoded.append(data[cursor..<chunkEnd])
            cursor = data.index(chunkEnd, offsetBy: 2)
        }
        throw WiredHTTPError.incompleteResponse
    }
}

private enum WiredHTTPError: LocalizedError {
    case invalidRequest
    case wiredPathUnavailable
    case connectionFailed(String)
    case connectionClosed
    case sendFailed(String)
    case receiveFailed(String)
    case timedOut
    case responseTooLarge
    case invalidResponse
    case incompleteResponse
    case unreadableUpload

    var isInterfaceFailure: Bool {
        switch self {
        case .wiredPathUnavailable, .connectionFailed, .connectionClosed, .timedOut:
            return true
        case .invalidRequest, .sendFailed, .receiveFailed, .responseTooLarge,
             .invalidResponse, .incompleteResponse, .unreadableUpload:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "模块请求格式无效"
        case .wiredPathUnavailable: return "未找到模块 USB 以太网路径"
        case let .connectionFailed(message): return "模块有线连接失败：\(message)"
        case .connectionClosed: return "模块有线连接已关闭"
        case let .sendFailed(message): return "模块请求发送失败：\(message)"
        case let .receiveFailed(message): return "模块响应接收失败：\(message)"
        case .timedOut: return "模块有线请求超时"
        case .responseTooLarge: return "模块响应超过安全大小限制"
        case .invalidResponse: return "模块代理返回了无效 HTTP 响应"
        case .incompleteResponse: return "模块代理返回的 HTTP 响应不完整"
        case .unreadableUpload: return "无法读取模块更新包"
        }
    }
}
