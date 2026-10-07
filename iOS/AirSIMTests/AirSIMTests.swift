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
    func testCloudUplinkNeverBurstsAfterBlockedSend() {
        var queue = CloudPCMUplinkSendQueue()
        for index in 0..<20 {
            queue.enqueue(Data(repeating: UInt8(index), count: 320), at: Double(index) * 0.02)
        }
        XCTAssertEqual(queue.next(at: 0.4)?.first, 0)
        XCTAssertNil(queue.next(at: 0.6))
        queue.complete()
        XCTAssertEqual(queue.next(at: 0.61)?.first, 1)
        queue.complete()
        XCTAssertNil(queue.next(at: 0.611))
        XCTAssertEqual(queue.next(at: 0.631)?.first, 2)
    }

    func testCloudUplinkDropsStaleBacklog() {
        var queue = CloudPCMUplinkSendQueue()
        for _ in 0..<200 { queue.enqueue(Data(repeating: 1, count: 320), at: 0) }
        XCTAssertEqual(queue.pendingPackets, 50)
        XCTAssertNil(queue.next(at: 2))
        XCTAssertEqual(queue.pendingPackets, 0)
        XCTAssertEqual(queue.droppedPackets, 200)
    }

    func testCloudDownlinkPrimesAndReordersBurst() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in [0, 2, 1, 3, 4, 5, 6, 7, 8, 9] {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: UInt8(sequence), count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.dequeue(maxFrames: 10).map(\.sequence), Array(0..<10).map(UInt32.init))
        buffer.notePlaybackUnderrun()
        XCTAssertFalse(buffer.isPrimed)
    }

    func testCloudDownlinkLimitsLateBurstLatency() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in 0..<75 {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.bufferedFrameCount, 50)
        XCTAssertEqual(buffer.droppedFrameCount, 25)
        XCTAssertEqual(buffer.dequeue(maxFrames: 50).map(\.sequence), Array(25..<75).map(UInt32.init))
    }

    func testCloudPlaybackReserveRefillsOnRenderedFrames() {
        var window = CloudPCMPlaybackWindow()
        for _ in 0..<12 { window.schedulePacket() }
        XCTAssertEqual(window.availablePackets, 0)
        window.didRenderPacket()
        XCTAssertEqual(window.availablePackets, 1)
        window.schedulePacket()
        XCTAssertEqual(window.scheduledPackets, 12)
    }

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

    func testMaintainerBundleUsesDedicatedRelayFallback() {
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            ""
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            "https://push.remotepilot.site/"
        )
    }

    func testRelayHealthRequiresAirSIMServiceIdentity() {
        let airSIM = Data(#"{"ok":true,"service":"airsim-push-relay","version":"0.2.0"}"#.utf8)
        let djonehub = Data(#"{"ok":true,"service":"djonehub-push-relay","version":"1.0.0"}"#.utf8)
        XCTAssertTrue(RelayHealthValidation.accepts(statusCode: 200, data: airSIM))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 200, data: djonehub))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 503, data: airSIM))
    }

    func testCurrentModePrefersVoWLANAndReportsCloudFailure() {
        XCTAssertEqual(
            ConnectionModePresentation.make(
                vowlanOnline: true,
                cloudModeEnabled: true,
                cloudOnline: true
            ).mode,
            .vowlan
        )
        let cloud = ConnectionModePresentation.make(
            vowlanOnline: false,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        XCTAssertEqual(cloud.mode, .cloud)
        XCTAssertEqual(cloud.status, "已连接")

        let unreachable = ConnectionModePresentation.make(
            vowlanOnline: false,
            cloudModeEnabled: true,
            cloudOnline: false
        )
        XCTAssertEqual(unreachable.mode, .cloud)
        XCTAssertEqual(unreachable.status, "不可达")
    }

    func testCloudSelfTestReportOnlyPassesWhenEveryStagePasses() {
        var report = CloudSelfTestReport.initial
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.steps.map(\.id), CloudSelfTestStepID.allCases)

        for id in CloudSelfTestStepID.allCases {
            report.update(id, state: .passed, detail: "通过")
        }
        report.completedAt = Date()
        XCTAssertTrue(report.allPassed)

        report.update(.agentHeartbeat, state: .failed, detail: "无心跳")
        XCTAssertFalse(report.allPassed)
    }
}
