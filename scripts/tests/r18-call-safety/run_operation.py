#!/usr/bin/env python3
"""Run the SAME HTTP fixture bodies and production recovery methods on macOS.
Assertions use fail-fast native equivalents, not the iOS XCTest runner.
The host adapter replaces only URL/transport/tracing wiring (not the recovery,
JSON validation or crypto code). It does not test Network.framework, CallKit,
UIKit audio or the device server. No real network requests are sent.
"""
from pathlib import Path
import tempfile, subprocess
import run as core
api = core.source('AirSIMAPI.swift'); router = core.source('DeviceCallActionRouter.swift')
tests = (core.root/'iOS/AirSIMTests/AirSIMTests.swift').read_text()
methods = core.between(api, '    func dialOwnedCall(', '    func answerCall(')
require = core.between(api, '    private static func requireSuccess', '\n}\n\nenum APIError')
adapter = r'''
struct VoWLANEndpoint: Sendable {
    let host: String; let controlPort: UInt16; let pcmPort: UInt16
    init(host: String, controlPort: UInt16, pcmPort: UInt16) throws {
        self.host = host; self.controlPort = controlPort; self.pcmPort = pcmPort
    }
}
enum LocalAgentRoute: Sendable {
    case vowlan(endpoint: VoWLANEndpoint, credential: VoWLANCredential)
    var credential: VoWLANCredential? { if case let .vowlan(_, credential) = self { return credential }; return nil }
}
enum WiredHTTPTransport {
    // These fixtures exercise URLError and HTTP responses, not private NW errors.
    static func permitsOperationStatusLookup(after error: Error) -> Bool { false }
}
struct AirSIMAPI: Sendable {
    static let voWLANDialTimeout: TimeInterval = 15
    static let decoder = JSONDecoder()
    let route: LocalAgentRoute
    let transport: any AirSIMHTTPTransport
    func endpoint(_ path: String) -> URL { URL(string: "http://fixture.invalid/")!.appendingPathComponent(path) }
    func tracedResponse(for original: URLRequest, recordVerboseTrace: Bool = true,
                        authenticationNonce: String? = nil) async throws -> WiredHTTPResponse {
        var request = original
        request.setValue(authenticationNonce, forHTTPHeaderField: "X-AirSIM-VoWLAN-Nonce")
        return try await transport.send(request, uploadFileURL: nil)
    }
'''
# Keep the host adapter scoped to recovery fixtures; audio tests require real XCTest.
fixture = core.between(tests, '@MainActor\nfinal class DialOperationRecoveryTests:',
                       '@MainActor\nfinal class EarlyMediaNegotiationTests:')
fixture += tests[tests.index('private actor OperationQueryTransport:'):]
names = ['testConfirmedLiveAndEndedAreRecoveredWithOriginalIdentity',
         'testUnknownRejectedAndNoCapabilityNeverReplayOrAdopt',
         'testStatusProofIsRequiredAndBindsEveryStateAndIdentityField',
         'testDefiniteRejectionAndUnboundLegacyPeerDoNotQuery']
main = '@main struct Runner { @MainActor static func main() async throws {\nlet tests = DialOperationRecoveryTests()\n' + '\n'.join(
    f'try await tests.{n}()' for n in names) + '\nprint("PASS: 4 operation-recovery fixture groups / 22 response scenarios (production methods; native host adapter)")\n} }\n'
assertions = r"""
// Fail-fast native equivalents; an assertion failure terminates with nonzero status.
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ message: String = "") {
    precondition(a() == b(), message)
}
func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "") { precondition(value(), message) }
func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "") { precondition(!value(), message) }
func XCTFail(_ message: String) { preconditionFailure(message) }
"""

parts = core.parts + [
    core.between(core.source('WiredHTTPTransport.swift'), 'struct WiredHTTPResponse:', '/// 使用 Network.framework'),
    core.between(api, 'protocol AirSIMHTTPTransport:', 'extension WiredHTTPTransport:'),
    core.between(router, 'struct DeviceBackendCall:', '@MainActor\nprotocol DeviceCallBackend'),
    core.between(router, 'enum DeviceCallRoutingError:', '@MainActor\nfinal class DeviceCallActionRouter'),
    api[api.index('enum APIError:'):], adapter + methods + require + '\n}\n',
    assertions + fixture]
with tempfile.TemporaryDirectory(prefix='airsim-operation-http-tests-') as tmp:
    production = Path(tmp)/'Production.swift'; production.write_text('\n'.join(parts))
    entry = Path(tmp)/'main.swift'; entry.write_text(main)
    binary = Path(tmp)/'tests'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(production),str(entry),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
