import XCTest
@testable import AirSIM

private actor OutgoingCallServiceProbe: OutgoingCallServicing {
    private let dialError: Error?
    private var actions: [String] = []

    init(dialError: Error? = nil) {
        self.dialError = dialError
    }

    func warmAudioHost() async throws { actions.append("warm") }
    func setAudioHostEnabled(_ enabled: Bool) async throws { actions.append("enable:\(enabled)") }
    func dial(number: String) async throws {
        actions.append("dial:\(number)")
        if let dialError { throw dialError }
    }

    func recordedActions() -> [String] { actions }
}

final class AirSIMTests: XCTestCase {
    func testOnlySamsungPrivateEndpointsAreAccepted() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.43.1", controlPort: 7575, pcmPort: 7576)
        XCTAssertEqual(endpoint.controlBaseURL.absoluteString, "http://192.168.43.1:7575/")
        XCTAssertThrowsError(try VoWLANEndpoint(host: "8.8.8.8", controlPort: 7575, pcmPort: 7576))
        XCTAssertFalse(AirSIMRoutePolicy.permits(.moduleLocal))
    }

    func testLegacyModuleRequestIsRejectedBeforeNetworkAccess() async {
        do {
            _ = try await AirSIMAPI().health()
            XCTFail("旧模块路线不应发出请求")
        } catch APIError.disabledLegacyRoute {
            // Expected: the old module route is blocked at the transport boundary.
        } catch {
            XCTFail("预期得到旧路线已停用错误，实际为 \(error)")
        }
    }

    func testLegacyModulePCMHandshakeIsRejected() {
        XCTAssertThrowsError(try PCMRoute.moduleLocal.handshake()) { error in
            guard case APIError.disabledLegacyRoute = error else {
                return XCTFail("预期旧模块 PCM 被拦截，实际为 \(error)")
            }
        }
    }

    func testDialTransportPrefersVoWLANOverCloud() {
        let route = DialPadTransportPresentation.make(
            vowlanOnline: true,
            moduleLocalReachable: false,
            cloudOnline: true
        )
        XCTAssertEqual(route?.transport, .vowlan)
    }

    func testCloudModeCanBeDisabledWithoutDisablingLocalCalls() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudModePreference.key)
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
        XCTAssertTrue(OutgoingCommandAvailability.isAvailable(
            localControlReachable: true,
            cloudModeEnabled: false,
            cloudHeartbeatFresh: false
        ))
    }

    @MainActor
    func testVoWLANTransportFailureFallsBackOnceToCloud() async throws {
        let local = OutgoingCallServiceProbe(dialError: URLError(.timedOut))
        var cloudAttempts = 0

        let result = try await OutgoingCallRouteCoordinator.start(
            number: "10086",
            vowlanService: local,
            cloudModeEnabled: true
        ) {
            cloudAttempts += 1
            return "cloud-call"
        }

        XCTAssertEqual(result, .cloud("cloud-call"))
        XCTAssertEqual(cloudAttempts, 1)
        let localActions = await local.recordedActions()
        XCTAssertEqual(localActions, ["warm", "dial:10086"])
    }

    @MainActor
    func testVoWLANAgentRejectionDoesNotReplayDialThroughCloud() async {
        let local = OutgoingCallServiceProbe(
            dialError: APIError.http(502, "Android Telecom 拒绝拨号")
        )
        var cloudAttempts = 0

        do {
            _ = try await OutgoingCallRouteCoordinator.start(
                number: "10086",
                vowlanService: local,
                cloudModeEnabled: true
            ) {
                cloudAttempts += 1
                return "cloud-call"
            }
            XCTFail("Agent 已明确拒绝时不得通过云端重放非幂等拨号")
        } catch APIError.http(let status, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("预期保留 Agent HTTP 错误，实际为 \(error)")
        }

        XCTAssertEqual(cloudAttempts, 0)
    }

    func testVoWLANDialWaitsPastSamsungTelecomAcknowledgementWindow() {
        XCTAssertGreaterThan(AirSIMAPI.voWLANDialTimeout, 12)
    }
}
