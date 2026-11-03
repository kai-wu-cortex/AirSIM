import Foundation

enum RelayEgressError: Error, Equatable { case disabled, stale, draining }

final class RelayEgressGate: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let persistenceKey = "airsim.pure-local.relay-blocked.v1"
    static let shared = RelayEgressGate(blocked: UserDefaults.standard.bool(forKey: persistenceKey))

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private weak var gate: RelayEgressGate?
        fileprivate let id: UUID
        fileprivate let epoch: UInt64
        fileprivate init(gate: RelayEgressGate, id: UUID, epoch: UInt64) { self.gate = gate; self.id = id; self.epoch = epoch }
        var isCurrent: Bool { gate?.isCurrent(epoch) == true }
        func close() { lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; lock.unlock(); gate?.finish(id) }
        deinit { close() }
    }

    private let lock = NSLock()
    private var blocked: Bool
    private var epoch: UInt64 = 0
    private var operations: [UUID: @Sendable () -> Void] = [:]
    private let transport: Transport

    init(blocked: Bool, transport: Transport? = nil) {
        self.blocked = blocked
        self.transport = transport ?? Self.defaultTransport
    }

    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func setPersistentBlocked(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Self.persistenceKey)
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await send(request, transport: transport)
    }

    func send(_ request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        try await send(request, transport: { try await session.data(for: $0) })
    }

    private func send(_ request: URLRequest, transport: @escaping Transport) async throws -> (Data, URLResponse) {
        let id = UUID()
        lock.lock()
        guard !blocked else { lock.unlock(); throw RelayEgressError.disabled }
        let admittedEpoch = epoch
        lock.unlock()
        let operation = Task { try await transport(request) }
        lock.lock()
        guard !blocked, epoch == admittedEpoch else { lock.unlock(); operation.cancel(); throw RelayEgressError.stale }
        operations[id] = { operation.cancel() }
        lock.unlock()
        defer { finish(id) }
        let result = try await operation.value
        guard isCurrent(admittedEpoch) else { throw RelayEgressError.stale }
        return result
    }

    func admitSocket(cancel: @escaping @Sendable () -> Void) throws -> Lease {
        lock.lock(); defer { lock.unlock() }
        guard !blocked else { throw RelayEgressError.disabled }
        let id = UUID(); operations[id] = cancel
        return Lease(gate: self, id: id, epoch: epoch)
    }

    func disableAndDrain(timeoutNanoseconds: UInt64 = 5_000_000_000) async -> Bool {
        lock.lock(); if !blocked { blocked = true; epoch &+= 1 }; let cancellations = Array(operations.values); lock.unlock()
        cancellations.forEach { $0() }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            lock.lock(); let empty = operations.isEmpty; lock.unlock()
            if empty { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        lock.lock(); let empty = operations.isEmpty; lock.unlock(); return empty
    }

    func enableAfterRestore() throws {
        lock.lock(); defer { lock.unlock() }
        guard operations.isEmpty else { throw RelayEgressError.draining }
        if blocked { blocked = false; epoch &+= 1 }
    }

    fileprivate func finish(_ id: UUID) { lock.lock(); operations.removeValue(forKey: id); lock.unlock() }
    fileprivate func isCurrent(_ value: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return !blocked && epoch == value }

    static func isLocalRequest(_ request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        guard pieces.count == 4 else { return false }
        return pieces[0] == 10 || pieces[0] == 127 || (pieces[0] == 192 && pieces[1] == 168)
            || (pieces[0] == 172 && (16...31).contains(pieces[1]))
            || (pieces[0] == 100 && (64...127).contains(pieces[1]))
            || (pieces[0] == 169 && pieces[1] == 254)
    }

    private static func defaultTransport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
