// Executed against the actual WatchLocalPCMTransport extracted by the test script.
import Foundation
import Network
import CryptoKit
import Darwin

setbuf(stdout, nil)
let fixtureSecret = Data(repeating: 0x42, count: 32)
let fixtureFrame = Data(repeating: 0x25, count: 320)
// Loopback-only adapter: production endpoint validation is tested separately.
struct WatchLocalPCMEndpoint {
    let host = "127.0.0.1"
    let port: UInt16
    let secret = fixtureSecret
    let usesTLS = false
}
var checks = 0
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
final class Probe {
    let ready = DispatchSemaphore(value: 0)
    let pcm = DispatchSemaphore(value: 0)
    let failure = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var readyValue = 0
    private var frameValue = 0
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (readyValue, frameValue) }
    func noteReady() { lock.lock(); readyValue += 1; lock.unlock(); ready.signal() }
    func notePCM(_ data: Data) { precondition(data == fixtureFrame); lock.lock(); frameValue += 1; lock.unlock(); pcm.signal() }
}
final class Gateway {
    enum Mode { case normal, rejectFirst, delayed, fragmented, timeoutFirst, hold }
    private let queue = DispatchQueue(label: "airsim.watch.mock-gateway")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var count = 0
    let preface = DispatchSemaphore(value: 0)
    let uplink = DispatchSemaphore(value: 0)
    let mode: Mode
    var port: UInt16 { listener.port!.rawValue }
    var handshakes: Int { queue.sync { count } }
    init(_ mode: Mode) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let bound = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { bound.signal() }
            if case let .failed(error) = state { fatalError("Mock gateway: \(error)") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receivePreface(connection, buffer: Data())
        }
        listener.start(queue: queue)
        precondition(bound.wait(timeout: .now() + 3) == .success)
    }
    private func receivePreface(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self, error == nil, !complete, let data else { return }
            let bytes = buffer + data
            guard bytes.contains(10) else { self.receivePreface(connection, buffer: bytes); return }
            let fields = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines).split(separator: " ").map(String.init)
            precondition(fields.count == 4 && fields[0] == "AIRSIMVWL1")
            let digest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
            let canonical = "PCM\n/v1/pcm\n\(digest)\n\(fields[1])\n\(fields[2])"
            let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: fixtureSecret)))
                .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            precondition(signature == fields[3], "Real transport must sign the fixture handshake")
            self.count += 1
            self.preface.signal()
            if self.mode == .hold || (self.mode == .timeoutFirst && self.count == 1) { return }
            if self.mode == .rejectFirst && self.count == 1 {
                connection.send(content: Data("INVALID_ACK".utf8), completion: .contentProcessed { _ in }); return
            }
            let send = {
                if self.mode == .fragmented {
                    connection.send(content: Data("AIRSI".utf8), completion: .contentProcessed { _ in })
                    self.queue.asyncAfter(deadline: .now() + 0.03) {
                        connection.send(content: Data("MREADY".utf8) + fixtureFrame.prefix(100), completion: .contentProcessed { _ in })
                    }
                    self.queue.asyncAfter(deadline: .now() + 0.15) {
                        connection.send(content: Data(fixtureFrame.dropFirst(100)), completion: .contentProcessed { _ in })
                    }
                } else {
                    connection.send(content: Data("AIRSIMREADY".utf8) + fixtureFrame, completion: .contentProcessed { _ in })
                }
                connection.receive(minimumIncompleteLength: 320, maximumLength: 320) { data, _, _, _ in
                    if let data, data == fixtureFrame { self.uplink.signal() }
                }
            }
            if self.mode == .delayed { self.queue.asyncAfter(deadline: .now() + 0.35, execute: send) }
            else { send() }
        }
    }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() } }
}
private func client(_ gateway: Gateway, _ probe: Probe) -> WatchLocalPCMTransport {
    WatchLocalPCMTransport(endpoint: WatchLocalPCMEndpoint(port: gateway.port),
        onPCM: { probe.notePCM($0) }, onReady: { probe.noteReady() }, onFailure: { _ in probe.failure.signal() })
}
func verifyCall(_ mode: Gateway.Mode) throws -> Double {
    let gateway = try Gateway(mode), probe = Probe(), transport = client(gateway, probe)
    let started = DispatchTime.now().uptimeNanoseconds
    transport.start()
    if mode == .delayed {
        require(gateway.preface.wait(timeout: .now() + 2) == .success, "Expected signed preface")
        require(probe.ready.wait(timeout: .now() + 0.1) == .timedOut, "TCP connection is not authenticated readiness")
    }
    require(probe.ready.wait(timeout: .now() + 10) == .success, "Expected authenticated connection")
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    if mode == .fragmented {
        require(probe.pcm.wait(timeout: .now() + 0.03) == .timedOut, "Partial PCM cannot be played as a whole frame")
    }
    require(probe.pcm.wait(timeout: .now() + 2) == .success, "Expected whole downlink PCM frame")
    transport.send(fixtureFrame)
    require(gateway.uplink.wait(timeout: .now() + 2) == .success, "Expected uplink PCM")
    require(probe.counts.0 == 1, "Readiness fires once per successful attempt")
    require(gateway.handshakes == (mode == .rejectFirst || mode == .timeoutFirst ? 2 : 1), "Unexpected handshake attempts")
    transport.stop()
    gateway.stop()
    return elapsed
}
var elapsed: [Double] = []
for _ in 0..<25 { elapsed.append(try verifyCall(.normal)) }
_ = try verifyCall(.delayed)
_ = try verifyCall(.rejectFirst)
_ = try verifyCall(.fragmented)
print("Loopback gateway: 25 normal calls, delayed ACK and rejected ACK passed")
_ = try verifyCall(.timeoutFirst)
print("Loopback gateway: silent handshake timeout and retry passed")
// Stop while the gateway is preparing its ACK: no old ready/frame is delivered.
do {
    let gateway = try Gateway(.delayed), probe = Probe(), transport = client(gateway, probe)
    transport.start()
    require(gateway.preface.wait(timeout: .now() + 2) == .success, "Expected pending handshake")
    transport.stop()
    require(probe.ready.wait(timeout: .now() + 0.7) == .timedOut, "Cancelled handshake cannot become ready")
    require(probe.counts.1 == 0, "Cancelled handshake cannot deliver old audio")
    gateway.stop()
}
// Exhaust the actual production retry budget; no shortened test-only deadlines.
do {
    let gateway = try Gateway(.hold), probe = Probe(), transport = client(gateway, probe)
    transport.start()
    print("Loopback gateway: checking production retry budget (about 45–50 seconds)")
    require(probe.failure.wait(timeout: .now() + 55) == .success, "A silent gateway must eventually fail")
    require(probe.counts.0 == 0 && probe.counts.1 == 0, "A failed gateway must never claim readiness or deliver audio")
    transport.stop(); gateway.stop()
}
let sorted = elapsed.sorted()
print("Loopback gateway checks passed: \(checks) assertions; mock-only median \(Int(sorted[sorted.count / 2])) ms, p95 \(Int(sorted[Int(Double(sorted.count - 1) * 0.95)])) ms. These are not Watch/Wi-Fi latency results.")
