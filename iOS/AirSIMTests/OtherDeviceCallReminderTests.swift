import XCTest
import CallKit
import SwiftUI
import UIKit
@testable import AirSIM

@MainActor
final class FixtureToneOutput: CallToneOutput {
    private(set) var isPlaying = false
    private(set) var sessionConfigurations: [Bool] = []
    func play(_ data: Data, looping: Bool, volume: Float, configureSession: Bool) throws {
        isPlaying = true; sessionConfigurations.append(configureSession)
    }
    func stop(deactivateSession: Bool) { isPlaying = false }
}

@MainActor
final class OtherDeviceCallReminderTests: XCTestCase {
    func testRealCloudPushCannotBecomePrimaryWhenOwnedWatchHasNoPhoneUUID() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.automatic)
        defer { ConnectionModePreference.set(old) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ReminderBackend() })
        let a = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        let controller = CallKitController(); controller.handler = model; controller.setEnabled(true)
        var reported = [UUID](), retired = [UUID]()
        let b = IncomingVoIPCall(bluetoothCallID: "cloud-B", uuid: UUID(), generation: 1, number: nil, agentID: "B")
        let completed = expectation(description: "genuine PushKit completion")
        controller.reportRequiredVoIPPush(b, systemReport: { uuid, _, done in reported.append(uuid); done(nil) },
            systemEnd: { retired.append($0) }) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(reported, [b.uuid]); XCTAssertEqual(retired, [b.uuid])
        XCTAssertNil(controller.currentSystemCallUUID)
        XCTAssertEqual(model.deviceCalls.active, a.key)
        await model.hangup()
    }
    func testWatchPendingAdmissionBlocksPhoneDialAndAnswerUntilReleased() async throws {
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ReminderBackend() })
        let request = UUID()
        XCTAssertTrue(model.deviceCallContext.reserveAdmission(request))
        do { _ = try await model.deviceCallRouter.dial(agentID: "B", number: "fixture", mode: .bluetooth); XCTFail("pending Watch must block dial") }
        catch { XCTAssertEqual(error as? DeviceCallRoutingError, .busy) }
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "b", state: .ringing, transport: .bluetooth, transportEpoch: 1))
        XCTAssertNil(model.remoteCall)
        let reminder = try XCTUnwrap(model.otherDeviceCallReminders.first)
        do { try await model.answerOtherDeviceCall(reminder.key); XCTFail("pending Watch must block answer") }
        catch { XCTAssertEqual(error as? DeviceCallRoutingError, .busy) }
        model.deviceCallContext.releaseAdmission(request)
        try await model.answerOtherDeviceCall(reminder.key)
        XCTAssertEqual(model.deviceCalls.active?.agentID, "B")
        await model.hangup()
    }
    func testOwnedOutgoingBindsScopedCallKitAndWatchActionIdentity() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.localDual)
        defer { ConnectionModePreference.set(old) }
        let controller = CallKitController(); controller.setEnabled(true)
        let backend = ReminderBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in backend }, callKitController: controller)
        try await controller.startOutgoingCall(number: "123", systemStart: { _ in })
        let uuid = try XCTUnwrap(controller.currentSystemCallUUID)
        model.deviceCallRouter.systemUUID = { uuid }
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        let id = try XCTUnwrap(model.remoteCall?.id)
        XCTAssertEqual(controller.watchCallUUID(for: id), uuid)
        XCTAssertTrue(controller.matchesCurrentCall(callID: id, uuid: uuid, agentID: "A"))
        XCTAssertFalse(controller.matchesCurrentCall(callID: id, uuid: uuid, agentID: "B"))
        await model.hangup()
    }
    func testEverySecondarySourceHasASelectableForegroundRow() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(old) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ReminderBackend() })
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        for id in ["B", "C"] {
            _ = model.receiveOwnedCallEvent(.init(agentID: id, callID: "same", state: .ringing,
                transport: .bluetooth, transportEpoch: 1))
        }
        let reminder = try XCTUnwrap(model.otherDeviceCallReminders.first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: OtherDeviceCallSheet(reminder: reminder).environmentObject(model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        // SwiftUI exposes identifiers on virtual accessibility elements, not
        // necessarily UIKit views. Assert the real rendered source section.
        let list = try XCTUnwrap(descendants(window).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 2)
        let c = try XCTUnwrap(model.otherDeviceCallReminders.first { $0.key.agentID == "C" })
        XCTAssertTrue(model.openOtherDeviceCallNotification(c.userInfo))
        XCTAssertEqual(model.focusedOtherDeviceCall?.key.agentID, "C")
        await model.hangup()
    }
    func testAndroidSideAnswerWithdrawsOnlyMatchingRingingPresentation() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(old) }
        let backend = ReminderBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in backend })
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same", state: .ringing,
            transport: .bluetooth, transportEpoch: 1))
        XCTAssertNotNil(model.remoteCall)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same", state: .active,
            transport: .bluetooth, transportEpoch: 1))
        XCTAssertNil(model.remoteCall)
        XCTAssertNil(model.deviceCallContext.media.owner)
        XCTAssertTrue(backend.answered.isEmpty); XCTAssertTrue(backend.ended.isEmpty)
    }
    func testPrimaryWLANFallbackAlertsStopAtAnswerAndNeverAlertForB() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.vowlan)
        defer { ConnectionModePreference.set(old) }
        let controller = CallKitController()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in ReminderBackend() }, callKitController: controller)
        defer { model.stop() }
        // Exercise the in-app fallback, not the asynchronous simulator CallKit service.
        // An accepted/pending system report correctly suppresses duplicate tones.
        controller.setEnabled(false)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "a", state: .ringing,
            transport: .vowlan, transportEpoch: 1))
        XCTAssertTrue(model.audio.hasCallTone)
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "b", state: .ringing,
            transport: .vowlan, transportEpoch: 1))
        XCTAssertEqual(model.incomingNotifier.currentCallID, model.remoteCall?.id)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "a", state: .active,
            transport: .vowlan, transportEpoch: 1))
        XCTAssertFalse(model.audio.hasCallTone)
        XCTAssertNil(model.incomingNotifier.currentCallID)
    }
    func testLocalDualPairingDefaultsToNoCloudConfiguration() {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.localDual)
        defer { ConnectionModePreference.set(old) }
        XCTAssertTrue(SamsungPairingView.defaultLocalPairingOnly)
    }
    func testLegacySelectedWLANLossCannotEndAnOwnedOtherDeviceCall() async throws {
        let backend = ReminderBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in backend })
        let route = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .vowlan)
        model.vowlan.onAvailabilityChange?(.unavailable("fixture B offline"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.deviceCalls.active, route.key)
        XCTAssertTrue(backend.ended.isEmpty)
        await model.hangup()
    }
    func testReminderPersistenceKeepsOnlyValidatedIdentityFields() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let reminder = OtherDeviceCallReminder(key: .init(agentID: "B", callID: "call", generation: 1),
            deviceName: "B", number: nil, stillRinging: true)
        var payload = reminder.userInfo
        payload["untrusted_extra"] = "must not persist"
        OtherAndroidCallPresentationRequest.mark(payload, defaults: defaults)
        let stored = try XCTUnwrap(OtherAndroidCallPresentationRequest.consume(defaults: defaults))
        XCTAssertNil(stored["untrusted_extra"])
        XCTAssertEqual(OtherDeviceCallReminder.key(from: stored), reminder.key)
    }
    func testIdleDeviceSelectionAnswersOnlySelectedCallAndRenewsSystemUUID() async throws {
        let oldMode = ConnectionModePreference.selected()
        ConnectionModePreference.set(.bluetooth)
        defer { ConnectionModePreference.set(oldMode) }
        let a = ReminderBackend(), b = ReminderBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { id, _ in id == "A" ? a : b })
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: "same", state: .ringing,
            transport: .bluetooth, transportEpoch: 1))
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "same", state: .ringing,
            transport: .bluetooth, transportEpoch: 1))
        let reminder = try XCTUnwrap(model.otherDeviceCallReminders.first)
        let oldUUID = try XCTUnwrap(model.deviceCallRouter.route(for: reminder.key)?.systemUUID)
        try await model.answerOtherDeviceCall(reminder.key)
        XCTAssertEqual(model.deviceCalls.active, reminder.key)
        XCTAssertEqual(model.deviceCallContext.media.owner, reminder.key)
        XCTAssertNotEqual(model.deviceCallRouter.route(for: reminder.key)?.systemUUID, oldUUID)
        XCTAssertEqual(b.answered, ["same"])
        XCTAssertTrue(a.answered.isEmpty); XCTAssertTrue(a.ended.isEmpty)
        await model.hangup()
        XCTAssertEqual(model.otherDeviceCallReminders.map(\.key.agentID), ["A"])
        let remaining = try XCTUnwrap(model.otherDeviceCallReminders.first)
        try await model.answerOtherDeviceCall(remaining.key)
        XCTAssertEqual(a.answered, ["same"])
        await model.hangup()
    }
    func testLateNativeIncomingReportFailureCannotResetReplacementUUID() async throws {
        let controller = CallKitController()
        controller.setEnabled(true)
        let a = IncomingVoIPCall(bluetoothCallID: "A", uuid: UUID(), generation: 1, number: nil)
        let b = IncomingVoIPCall(bluetoothCallID: "B", uuid: UUID(), generation: 1, number: nil)
        var oldReply: ((Error?) -> Void)?
        controller.reportIncomingPush(b, systemReport: { _, _, done in oldReply = done }) { _ in }
        controller.withdrawLocalPresentation(uuid: b.uuid)
        var replacementCompletions = 0
        controller.reportIncomingPush(a, systemReport: { _, _, _ in }) { _ in replacementCompletions += 1 }
        oldReply?(NSError(domain: CXErrorDomainRequestTransaction,
            code: CXErrorCodeRequestTransactionError.Code.unentitled.rawValue))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.currentSystemCallUUID, a.uuid)
        XCTAssertEqual(replacementCompletions, 0)
    }
    func testAppHangupCapturesBackendBeforeRetiringPresentation() async throws {
        let backend = ReminderBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in backend })
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        await model.hangup()
        XCTAssertEqual(backend.ended, ["fixture"])
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertNil(model.inAppPresentedCall)
    }
    func testIslandHangupResolvesScopedPresentationID() async throws {
        let backend = ReminderBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in backend })
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        let id = try XCTUnwrap(model.remoteCall?.id)
        await model.performVoBLELiveActivityAction(.hangup, callID: id)
        XCTAssertEqual(backend.ended, ["fixture"])
        XCTAssertNil(model.deviceCalls.active)
    }
    func testFailedOwnedDialRetiresConnectingPresentation() async {
        let backend = ReminderBackend(); backend.failDial = true
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in backend })
        do { _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth) }
        catch {}
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertNil(model.remoteCall)
    }
    func testGenuinePushWhileLocalCallActiveStillReportsWithoutEndingA() async throws {
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ReminderBackend() })
        let a = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        let controller = CallKitController()
        controller.handler = model
        controller.setEnabled(false)
        let call = IncomingVoIPCall(bluetoothCallID: "cloud-B", uuid: UUID(), generation: 1, number: nil, agentID: "B")
        var reports = [UUID](), retired = [UUID]()
        let completed = expectation(description: "PushKit completion")
        controller.reportRequiredVoIPPush(call, systemReport: { uuid, _, completion in
            reports.append(uuid); completion(nil)
        }, systemEnd: { retired.append($0) }) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(reports, [call.uuid]); XCTAssertEqual(retired, [call.uuid])
        XCTAssertEqual(model.deviceCalls.active, a.key)
        XCTAssertEqual(model.deviceCallContext.media.owner, a.key)
    }
    func testDuplicateRingingCreatesOneNotification() async {
        let key = DeviceCallKey(agentID: "B", callID: "shared", generation: 2)
        var posted = [String]()
        let controller = OtherDeviceCallReminderController(lookup: { candidate in
            candidate == key ? .init(key: key, deviceName: "B", number: nil, stillRinging: true) : nil
        }, notify: { reminder in posted.append(reminder.id) }, remove: { _ in })
        controller.consume([.remind(key), .remind(key)])
        await controller.waitForNotifications()
        controller.consume([.update(key)])
        await controller.waitForNotifications()
        XCTAssertEqual(controller.reminders.map(\.key), [key])
        XCTAssertEqual(posted.count, 1)
    }
    func testBEndedRemovesOnlyBReminder() async {
        let b = DeviceCallKey(agentID: "B", callID: "same", generation: 1)
        let c = DeviceCallKey(agentID: "C", callID: "same", generation: 2)
        var ringing: Set<DeviceCallKey> = [b, c]
        var removed = [String]()
        let controller = OtherDeviceCallReminderController(lookup: { key in
            ringing.contains(key) ? .init(key: key, deviceName: key.agentID, number: nil, stillRinging: true) : nil
        }, notify: { _ in }, remove: { removed.append($0) })
        controller.consume([.remind(b), .remind(c)])
        await controller.waitForNotifications()
        ringing.remove(b)
        controller.consume([.ended(b)])
        XCTAssertEqual(controller.reminders.map(\.key), [c])
        XCTAssertEqual(removed, [OtherDeviceCallReminder.notificationID(for: b)])
    }
    func testProductionNotificationTapRevalidatesSourceWithoutAutoAnswer() async throws {
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ReminderBackend() })
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "fixture", state: .ringing,
            transport: .bluetooth, transportEpoch: 1))
        let key = try XCTUnwrap(model.deviceCalls.key(agentID: "B", callID: "fixture"))
        let reminder = try XCTUnwrap(model.otherDeviceCallReminders.first)
        let active = model.deviceCalls.active
        XCTAssertTrue(model.openOtherDeviceCallNotification(reminder.userInfo))
        XCTAssertEqual(model.focusedOtherDeviceCall?.key, key)
        XCTAssertEqual(model.deviceCalls.active, active)
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "fixture", state: .ended,
            transport: .bluetooth, transportEpoch: 1))
        XCTAssertFalse(model.openOtherDeviceCallNotification(reminder.userInfo))
        XCTAssertTrue(model.otherDeviceCallReminders.isEmpty)
        XCTAssertEqual(model.deviceCalls.active, active)
    }
    func testBReminderNeverReplacesACallOrActivityTimer() async throws {
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ReminderBackend() })
        _ = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        let snapshot = model.callLifecycleSnapshot, started = model.remoteCall?.startedAt
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "fixture", state: .ringing,
            transport: .bluetooth, transportEpoch: 1))
        XCTAssertEqual(model.otherDeviceCallReminders.count, 1)
        XCTAssertEqual(model.callLifecycleSnapshot, snapshot)
        XCTAssertEqual(model.remoteCall?.startedAt, started)
    }
    func testAEndsRevalidatesBInsteadOfAutoAnswer() async throws {
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()), deviceBackend: { _, _ in ReminderBackend() })
        let a = try await model.deviceCallRouter.dial(agentID: "A", number: "fixture", mode: .bluetooth)
        _ = model.receiveOwnedCallEvent(.init(agentID: "B", callID: "fixture", state: .ringing,
            transport: .bluetooth, transportEpoch: 1))
        try await model.callKitEnd(uuid: a.systemUUID)
        XCTAssertNil(model.deviceCalls.active)
        XCTAssertEqual(model.otherDeviceCallReminders.count, 1)
        XCTAssertEqual(model.deviceCalls.ringing.map(\.agentID), ["B"])
    }
    func testLocalDualStartsBothLocalTransportsWithoutCloudOrPushKit() throws {
        let mode = try XCTUnwrap(AirSIMConnectionMode(rawValue: "localDual"))
        let policy = ConnectionModeRuntimePolicy(mode: mode)
        XCTAssertTrue(policy.startsVoWLAN); XCTAssertTrue(policy.startsBluetooth)
        XCTAssertFalse(policy.startsCloud); XCTAssertTrue(policy.usesCallKit)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        ConnectionModePreference.set(mode, defaults: defaults)
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
        XCTAssertEqual(ConnectionModePreference.selected(defaults: defaults), mode)
    }
    func testLocalDualRouteStaysInsideSelectedAgent() throws {
        let mode = try XCTUnwrap(AirSIMConnectionMode(rawValue: "localDual"))
        XCTAssertEqual(DialRouteSelector.preferred(mode: mode, vowlanReady: true, bluetoothReady: true, cloudReady: true), .vowlan)
        XCTAssertEqual(DialRouteSelector.preferred(mode: mode, vowlanReady: false, bluetoothReady: true, cloudReady: true), .bluetooth)
        XCTAssertNil(DialRouteSelector.preferred(mode: mode, vowlanReady: false, bluetoothReady: false, cloudReady: true))
    }
    func testLegacyFourModePreferencesKeepTheirMeaning() {
        for mode in [AirSIMConnectionMode.vowlan, .bluetooth, .cloud, .automatic] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            ConnectionModePreference.set(mode, defaults: defaults)
            XCTAssertEqual(ConnectionModePreference.selected(defaults: defaults), mode)
            XCTAssertEqual(ConnectionModeRuntimePolicy(mode: mode).startsCloud, mode == .cloud || mode == .automatic)
        }
    }
    func testPushedCallActiveEventOnlyWithdrawsUnansweredPresentation() {
        let call = IncomingVoIPCall(bluetoothCallID: "call-1", uuid: UUID(), generation: 2, number: nil, agentID: "A")
        let event = DeviceCallEvent(agentID: "A", callID: "call-1", state: .active,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 2)
        XCTAssertEqual(PushedCallTerminationPolicy.action(event: event, call: call, state: .ringing,
            answered: false, systemAnswered: false), .answeredElsewhere)
        XCTAssertNil(PushedCallTerminationPolicy.action(event: event, call: call, state: .ringing,
            answered: true, systemAnswered: false))
        XCTAssertNil(PushedCallTerminationPolicy.action(event: event, call: call, state: .ringing,
            answered: false, systemAnswered: true))
        XCTAssertNil(PushedCallTerminationPolicy.action(event: event, call: call, state: .active,
            answered: false, systemAnswered: false))
    }

    func testPushedCallTerminalRequiresDeviceAndBackendIdentity() {
        let call = IncomingVoIPCall(bluetoothCallID: "backend-1", uuid: UUID(), generation: 7, number: nil, agentID: "A")
        for state in [CallLifecycleState.ringing, .connecting, .active, .ending] {
            for terminal in [CallLifecycleState.ended, .failed] {
                let event = DeviceCallEvent(agentID: "A", callID: "canonical-1", state: terminal,
                    transport: .vowlan, transportEpoch: 3, backendCallID: "backend-1")
                XCTAssertEqual(PushedCallTerminationPolicy.action(event: event, call: call, state: state,
                    answered: true, systemAnswered: true), .ended)
            }
        }
        for event in [
            DeviceCallEvent(agentID: "B", callID: "backend-1", state: .ended, transport: .vowlan, transportEpoch: 1),
            DeviceCallEvent(agentID: "A", callID: "other", state: .ended, transport: .vowlan, transportEpoch: 1),
        ] {
            XCTAssertNil(PushedCallTerminationPolicy.action(event: event, call: call, state: .active,
                answered: true, systemAnswered: true))
        }
        let independentlyCountedBLE = DeviceCallEvent(agentID: "A", callID: "backend-1", state: .ended,
            transport: .bluetooth, transportEpoch: 3, backendGeneration: 11)
        XCTAssertEqual(PushedCallTerminationPolicy.action(event: independentlyCountedBLE, call: call,
            state: .active, answered: true, systemAnswered: true), .ended)
        let unscoped = IncomingVoIPCall(bluetoothCallID: "backend-1", uuid: UUID(), generation: 7, number: nil)
        XCTAssertNil(PushedCallTerminationPolicy.action(event: .init(agentID: "A", callID: "backend-1",
            state: .ended, transport: .vowlan, transportEpoch: 1), call: unscoped, state: .active,
            answered: true, systemAnswered: true))
    }

    func testColdCloudHandoffAdoptsOnlyTheSurvivingSystemUUID() async throws {
        let old = ConnectionModePreference.selected(); ConnectionModePreference.set(.cloud)
        defer { ConnectionModePreference.set(old); IPhoneCloudCallSession.shared.stop() }
        let controller = CallKitController(); controller.setEnabled(true)
        let retired = IncomingVoIPCall(bluetoothCallID: "cold-A", uuid: UUID(), generation: 7, number: nil, agentID: "A")
        let surviving = IncomingVoIPCall(bluetoothCallID: "cold-B", uuid: UUID(), generation: 8, number: nil, agentID: "A")
        for incoming in [retired, surviving] {
            let reported = expectation(description: "cold push reported before model")
            controller.reportIncomingPush(incoming, systemReport: { _, _, done in done(nil) }) { error in
                XCTAssertNil(error); reported.fulfill()
            }
            await fulfillment(of: [reported], timeout: 2)
            if incoming.uuid == retired.uuid { controller.reportCurrentCallEnded(reason: .remoteEnded) }
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            callKitController: controller, historyStore: LocalHistoryStore(directoryURL: path))
        defer { model.stop() }
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ringing)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, surviving.uuid)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, surviving.callID)
        XCTAssertEqual(model.callLifecycleSnapshot.generation, surviving.generation)
        model.callKitDidReceiveIncoming(retired)
        XCTAssertEqual(model.callLifecycleSnapshot.callUUID, surviving.uuid)
        _ = model.receiveOwnedCallEvent(.init(agentID: "A", callID: surviving.callID, state: .ended,
            transport: .vowlan, transportEpoch: 1))
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ended)
        XCTAssertNil(controller.currentSystemCallUUID)
        let replacement = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            callKitController: controller, historyStore: LocalHistoryStore(directoryURL: path))
        defer { replacement.stop() }
        XCTAssertEqual(replacement.callLifecycleSnapshot.state, .idle)
        XCTAssertNil(replacement.remoteCall)
    }

    func testAndroidAnswerRetiresCloudRingingPageWithoutHangup() throws {
        let previous = ConnectionModePreference.selected()
        ConnectionModePreference.set(.automatic)
        defer {
            ConnectionModePreference.set(previous)
            IPhoneCloudCallSession.shared.stop()
        }
        let backend = ReminderBackend()
        let model = AppModel(audioController: AudioSessionController(toneOutput: FixtureToneOutput()),
            deviceBackend: { _, _ in backend })
        defer { model.stop() }
        let cloud = try IncomingVoIPCall(userInfo: [
            "event": "incoming_call", "call_id": "cloud-answer-1",
            "call_uuid": UUID().uuidString, "generation": 2,
            "number": "10086", "agent_id": "A",
        ])
        model.callKitDidReceiveIncoming(cloud)
        XCTAssertEqual(model.callLifecycleSnapshot.callID, "cloud-answer-1")
        XCTAssertEqual(model.callLifecycleSnapshot.state, .ringing)

        _ = model.receiveOwnedCallEvent(DeviceCallEvent(
            agentID: "A", callID: "cloud-answer-1", state: .active,
            transport: .bluetooth, transportEpoch: 1, backendGeneration: 2,
            number: "10086", direction: "incoming"))
        XCTAssertTrue(model.callLifecycleSnapshot.state.isTerminal)
        XCTAssertNil(model.remoteCall)
        XCTAssertTrue(backend.ended.isEmpty, "Android answer must not send a hangup")
        XCTAssertNil(model.callKit.currentSystemCallUUID)
    }
}

@MainActor
private final class ReminderBackend: DeviceCallBackend {
    let epoch: UInt64 = 1
    var ended = [String]()
    var failDial = false
    var answered = [String]()
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        if failDial { throw DeviceCallRoutingError.unavailable }
        return .init(callID: "fixture", backendID: "fixture", generation: nil)
    }
    func answer(callID: String, generation: UInt64?) async throws { answered.append(callID) }
    func end(callID: String, generation: UInt64?, reject: Bool) async throws { ended.append(callID) }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws {}
}
