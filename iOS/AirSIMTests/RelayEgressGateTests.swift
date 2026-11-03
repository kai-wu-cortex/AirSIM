import XCTest
@testable import AirSIM

final class RelayEgressGateTests: XCTestCase {
    func testBlockedGateNeverStartsTransport() async throws {
        let transport = CountingRelayTransport()
        let gate = RelayEgressGate(blocked: true, transport: transport.send)
        do {
            _ = try await gate.send(URLRequest(url: URL(string: "https://relay.invalid/test")!))
            XCTFail("blocked request accepted")
        } catch RelayEgressError.disabled {}
        XCTAssertEqual(transport.count, 0)
    }

    func testDisableCancelsAndInvalidatesOldCompletion() async throws {
        let transport = CountingRelayTransport(suspended: true)
        let gate = RelayEgressGate(blocked: false, transport: transport.send)
        let request = URLRequest(url: URL(string: "https://relay.invalid/test")!)
        let task = Task { try await gate.send(request) }
        await transport.waitUntilStarted()
        let drained = await gate.disableAndDrain(timeoutNanoseconds: 1_000_000_000)
        XCTAssertTrue(drained)
        do { _ = try await task.value; XCTFail("old result accepted") }
        catch {}
        try gate.enableAfterRestore()
        XCTAssertFalse(gate.isBlocked)
    }

    func testLocalRequestDoesNotUseRelayGate() async throws {
        let transport = CountingRelayTransport()
        let gate = RelayEgressGate(blocked: true, transport: transport.send)
        let local = URLRequest(url: URL(string: "http://100.92.1.2:8576/api/local-mode")!)
        XCTAssertTrue(RelayEgressGate.isLocalRequest(local))
        XCTAssertEqual(transport.count, 0)
        _ = gate
    }
}

private final class CountingRelayTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private let suspended: Bool
    private(set) var count = 0
    init(suspended: Bool = false) { self.suspended = suspended }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let shouldSuspend = lock.withLock { count += 1; return suspended }
        if shouldSuspend { try await Task.sleep(nanoseconds: 10_000_000_000) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitUntilStarted() async {
        for _ in 0..<100 { let value = lock.withLock { count }; if value > 0 { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}
