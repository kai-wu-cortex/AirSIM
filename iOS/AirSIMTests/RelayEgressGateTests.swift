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

    func testParentCancellationStopsInFlightRequest() async throws {
        let transport = CountingRelayTransport(suspended: true)
        let gate = RelayEgressGate(blocked: false, transport: transport.send)
        let task = Task { try await gate.send(URLRequest(url: URL(string: "https://relay.invalid/test")!)) }
        await transport.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled probe returned a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let drained = await gate.disableAndDrain(timeoutNanoseconds: 100_000_000)
        XCTAssertTrue(drained)
    }

    func testDiagnosticsRetryTransientFailureButNotAuthenticationOrQuota() async throws {
        let request = URLRequest(url: URL(string: "https://relay.invalid/healthz")!)
        let retry = DiagnosticTransportProbe(status: 200, failFirst: true)
        let response = try await VoIPPushController.sendDiagnosticRequest(request, send: retry.send)
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(retry.count, 2)
        for status in [401, 403, 429] {
            let final = DiagnosticTransportProbe(status: status)
            _ = try await VoIPPushController.sendDiagnosticRequest(request, send: final.send)
            XCTAssertEqual(final.count, 1)
        }
        let busy = DiagnosticTransportProbe(status: 503)
        _ = try await VoIPPushController.sendDiagnosticRequest(request, send: busy.send)
        XCTAssertEqual(busy.count, 3)
    }

    func testEachDiagnosticFetchesFreshResponse() async throws {
        let probe = DiagnosticTransportProbe(status: 200)
        let request = URLRequest(url: URL(string: "https://relay.invalid/healthz")!)
        _ = try await VoIPPushController.sendDiagnosticRequest(request, send: probe.send)
        _ = try await VoIPPushController.sendDiagnosticRequest(request, send: probe.send)
        XCTAssertEqual(probe.count, 2, "Connection reuse must never reuse a previous result")
    }

    func testTransportCancellationIsNotRetried() async throws {
        do {
            _ = try await VoIPPushController.sendDiagnosticRequest(
                URLRequest(url: URL(string: "https://relay.invalid/healthz")!)) { _ in
                    throw URLError(.cancelled)
                }
            XCTFail("Cancelled request returned a response")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
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

private final class DiagnosticTransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private let status: Int
    private let failFirst: Bool
    var count: Int { lock.withLock { attempts } }
    init(status: Int, failFirst: Bool = false) { self.status = status; self.failFirst = failFirst }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let attempt = lock.withLock { attempts += 1; return attempts }
        if failFirst && attempt == 1 { throw URLError(.networkConnectionLost) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
