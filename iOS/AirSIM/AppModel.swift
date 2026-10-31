import Combine
import Foundation
import UIKit

enum AppForegroundRecoveryPolicy {
    /// Foreground return may restart discovery only while idle. An active call keeps
    /// its locked route; network recovery resumes after the call, never as a handover.
    static func shouldRestartVoWLAN(mode: AirSIMConnectionMode, callActive: Bool) -> Bool {
        !callActive && ConnectionModeRuntimePolicy(mode: mode).startsVoWLAN
    }
}

enum AppRefreshPolicy {
    static func shouldRunAgentPolling(mode: AirSIMConnectionMode) -> Bool { mode != .bluetooth }
    static func shouldRefreshSupplementalState(appIsActive: Bool) -> Bool { appIsActive }

    static func shouldQueryCloudStatus(
        cloudModeEnabled: Bool,
        lastAttempt: Date,
        appIsForeground: Bool,
        beforeLiveActivityCall: Bool = false
    ) -> Bool {
        guard cloudModeEnabled, appIsForeground || beforeLiveActivityCall else { return false }
        // Foreground entry explicitly re-arms this sentinel. Elapsed time alone never polls Relay.
        return lastAttempt == .distantPast
    }
}

/// Serializes first-launch permission prompts so the microphone request cannot be
/// displaced by notification or local-network authorization.
@MainActor
final class InitialPermissionCoordinator {
    private(set) var didStartDiscovery = false
    private var didRequestNotifications = false

    func requestIfNeeded(
        isForeground: () -> Bool,
        microphoneIsUndetermined: () -> Bool,
        requestMicrophone: () async -> Void,
        startDiscovery: () -> Void,
        requestNotifications: () -> Void
    ) async {
        guard isForeground() else { return }
        if microphoneIsUndetermined() { await requestMicrophone() }
        // If iOS deferred the prompt while the app was inactive, the next foreground
        // transition retries it instead of recording a request that never happened.
        guard isForeground(), !microphoneIsUndetermined() else { return }
        if !didStartDiscovery {
            didStartDiscovery = true
            startDiscovery()
        }
        if !didRequestNotifications {
            didRequestNotifications = true
            requestNotifications()
        }
    }
}

enum CallPresentationSurface: Equatable, Sendable {
    case system
    case app
}

enum CallAudioStatusPresentation {
    static func text(transport: CallTransport?, bluetoothRunning: Bool,
                     bluetoothError: String?, localAudioActive: Bool,
                     cloudState: CloudCallAudioState) -> String {
        if transport == .bluetooth {
            if bluetoothRunning { return "已连接蓝牙 PCM 链路" }
            return bluetoothError ?? "正在建立蓝牙语音链路"
        }
        switch cloudState {
        case .idle: return localAudioActive ? "语音链路已连接" : "正在建立语音链路"
        case let .connecting(attempt, maximum): return "正在重试云端语音 \(attempt)/\(maximum)"
        case .connected: return "云端语音已连接"
        case let .failed(message): return message
        }
    }
}

/// Orders time-critical call work separately from coalesced metadata/push work.
@MainActor
final class CallUpdateWorkScheduler {
    private var supplementalTask: Task<Void, Never>?
    private var revision = UUID()

    func process(
        isCurrent: @escaping @MainActor () -> Bool,
        synchronizeCall: @MainActor () -> Void,
        updateAudio: @MainActor () async -> Void,
        updateSupplemental: @escaping @MainActor (@escaping @MainActor () -> Bool) async -> Void
    ) async {
        let token = revision
        guard !Task.isCancelled, isCurrent() else { return }
        synchronizeCall()
        guard !Task.isCancelled, revision == token, isCurrent() else { return }
        await updateAudio()
        guard !Task.isCancelled, revision == token, isCurrent(), supplementalTask == nil else { return }
        supplementalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if revision == token { supplementalTask = nil } }
            let canApply: @MainActor () -> Bool = { [weak self] in
                !Task.isCancelled && self?.revision == token && isCurrent()
            }
            guard canApply() else { return }
            await updateSupplemental(canApply)
        }
    }

    func cancel() {
        revision = UUID()
        supplementalTask?.cancel()
        supplementalTask = nil
    }
}

enum CallPresentationPolicy {
    static func inAppCall(
        surface: CallPresentationSurface?,
        local: CallRecord?,
        remote: CallRecord?,
        pending: CallRecord? = nil
    ) -> CallRecord? {
        guard surface == .app else { return nil }
        return [local, remote, pending].compactMap { $0 }.first {
            $0.endedAt == nil && !["ending", "ended", "failed"].contains($0.state)
        }
    }

    static func shouldPresentWhenAppBecomesActive(
        managesSystemCall: Bool,
        hasLocalCall: Bool,
        hasRemoteCall: Bool
    ) -> Bool {
        managesSystemCall || hasLocalCall || hasRemoteCall
    }
}

enum CallAnswerConfirmationPolicy {
    static func shouldMarkActiveImmediately(transport: CallTransport?) -> Bool {
        transport == .vowlan
    }
}

enum CallKitEndDecision {
    enum Route: Equatable {
        case cloudReject
        case cloudEnd
        case localReject
        case localHangup
    }

    static func route(
        transport: CallTransport?,
        cloudSessionPrepared: Bool,
        hasIncomingPush: Bool,
        systemCallAnswered: Bool,
        activeIncomingRinging: Bool
    ) -> Route {
        if hasIncomingPush, !systemCallAnswered,
           transport != .vowlan {
            return .cloudReject
        }
        if transport == .cloud || cloudSessionPrepared { return .cloudEnd }
        return activeIncomingRinging || (hasIncomingPush && !systemCallAnswered)
            ? .localReject : .localHangup
    }
}

/// Authenticated local events may retire the same pushed call, not another
/// device's presentation. An active event only withdraws an unanswered call;
/// a terminal event also closes a call already answered on this iPhone.
enum PushedCallTerminationPolicy {
    enum Action: Equatable {
        case answeredElsewhere
        case ended
    }

    static func matchesBackendCall(_ event: DeviceCallEvent, call: IncomingVoIPCall) -> Bool {
        guard let agentID = call.agentID, !agentID.isEmpty, event.agentID == agentID else { return false }
        return event.callID == call.callID || event.backendCallID == call.callID
            || event.replacesCallID == call.callID
    }

    static func action(
        event: DeviceCallEvent,
        call: IncomingVoIPCall,
        state: CallLifecycleState,
        answered: Bool,
        systemAnswered: Bool
    ) -> Action? {
        guard state.representsCall, matchesBackendCall(event, call: call) else { return nil }
        // Backend generations are scoped to their transport, not Relay's counter.
        // DeviceCallRegistry validates them before this presentation policy runs.
        if event.state.isTerminal { return .ended }
        guard event.state == .active, !answered, !systemAnswered, state != .active else { return nil }
        return .answeredElsewhere
    }
}

enum LocalCallControlTarget {
    static func select<Service>(
        locked: Service?,
        observed: (callID: String, service: Service)?,
        fallback: Service?,
        targetCallID: String?
    ) -> Service? {
        if let locked { return locked }
        guard let targetCallID, !targetCallID.isEmpty else { return nil }
        if let observed {
            return observed.callID == targetCallID ? observed.service : nil
        }
        return fallback
    }
}

enum CallAnswerCompletionCoordinator {
    @MainActor
    static func complete(
        transport: CallTransport?,
        confirmActive: () -> Void,
        startAudio: () async -> Void
    ) async {
        guard CallAnswerConfirmationPolicy.shouldMarkActiveImmediately(
            transport: transport
        ) else { return }
        confirmActive()
        await startAudio()
    }
}

enum AgentEventPollingPolicy {
    static func timeout(hasActiveCall: Bool) -> TimeInterval {
        hasActiveCall ? 3 : 15
    }

    static func shouldFetchSMS(pending: Int, eventRevision: UInt64, observedSMSRevision: UInt64) -> Bool {
        // An earlier fetch or local save may have failed after this revision was observed.
        // The Agent's unacknowledged queue is authoritative, including after a restart.
        pending > 0
    }
}

protocol AgentSMSInboxServicing: Sendable {
    func messages() async throws -> [SMSMessage]
}

extension AirSIMAPI: AgentSMSInboxServicing {}

enum AgentSMSInboxFetch {
    static func fetch<Service: AgentSMSInboxServicing>(
        reportingAgent: Service?, discoveredAgent: Service
    ) async throws -> (agent: Service, messages: [SMSMessage]) {
        let agent = reportingAgent ?? discoveredAgent
        return (agent, try await agent.messages())
    }
}

protocol LegacyAgentPolling: Sendable {
    func callStatus() async throws -> CallStatus
    func smsStatus() async throws -> SMSStatus
}

extension AirSIMAPI: LegacyAgentPolling {}

struct LegacyAgentPollResult: Sendable {
    let call: CallStatus
    let smsChanged: Bool
}

enum LegacyAgentPoller {
    static func next(_ api: some LegacyAgentPolling) async throws -> LegacyAgentPollResult {
        let call = try await api.callStatus()
        let sms = try? await api.smsStatus()
        // Older Agents may not expose /api/sms/status. In that case, fetch the
        // inbox directly instead of silently missing messages.
        return LegacyAgentPollResult(call: call, smsChanged: sms.map { ($0.count ?? 0) > 0 } ?? true)
    }
}

enum AgentEventCursor {
    /// 不可能由正常计数器产生，用于首次连接时要求 Agent 立即返回当前快照。
    static let initial = UInt64.max

    static func advanced(from _: UInt64, to incoming: UInt64) -> UInt64 {
        // Agent 重启后 revision 会回到 0，不能使用 max，否则会持续立即返回形成空转。
        incoming
    }
}

enum ModuleConnectivityPolicy {
    static let offlineFailureThreshold = 3
    static let callTransitionGraceInterval: TimeInterval = 8

    static func shouldConfirmOffline(
        consecutiveFailures: Int,
        now: Date,
        protectedUntil: Date
    ) -> Bool {
        consecutiveFailures >= offlineFailureThreshold && now >= protectedUntil
    }

    static func shouldMarkOffline(
        consecutiveFailures: Int,
        healthRequestSucceeded: Bool,
        now: Date,
        protectedUntil: Date
    ) -> Bool {
        shouldConfirmOffline(
            consecutiveFailures: consecutiveFailures,
            now: now,
            protectedUntil: protectedUntil
        ) && !healthRequestSucceeded
    }
}

/// 移动端 App 的主状态中心：前台轮询模块代理并驱动五个主要页面。
@MainActor
final class AppModel: ObservableObject {
    @Published var activeCall: CallRecord?
    @Published var callHistory: [CallRecord] = []
    @Published var messages: [SMSMessage] = []
    @Published var numberInput = ""
    @Published var isOnline = false
    @Published private(set) var isReconnecting = false
    @Published var connectionMessage: String?
    @Published var isBusy = false
    @Published var isMuted = false
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published private(set) var modemStatus: ModemStatus?
    @Published private(set) var agentVersion: String?
    @Published private(set) var connectionSummary: ModuleConnectionSummary = .offline
    @Published private(set) var cloudAgentStatus: CloudAgentStatus?
    @Published private(set) var cloudAgentDirectory: CloudAgentStatus?
    @Published private(set) var cloudStatusError: String?
    @Published private(set) var remoteCall: CallRecord?
    @Published private(set) var pendingOutgoingCall: CallRecord?
    @Published private(set) var callPresentationSurface: CallPresentationSurface?
    @Published private(set) var cloudCallAudioState: CloudCallAudioState = .idle
    @Published private(set) var callLifecycleSnapshot: CallLifecycleSnapshot = .idle
    private var outgoingAttemptID = UUID()

    let contacts: ContactStore
    let audio: AudioSessionController
    let callKit: CallKitController
    let backgroundStandby = BackgroundStandbyController()
    let vowlan = VoWLANController()
    let vobleHub: VoBLEDeviceHub
    var voble: VoBLECentralController { vobleHub.selected.central }
    private(set) lazy var localDevices = LocalDeviceDirectory(bluetoothReady: { [weak self] id in
        self?.vobleHub.session(for: id) != nil
    })
    private var localDirectoryRefresh: Task<Void, Never>?
    private var localDirectoryRefreshPending = false
    @Published private(set) var pairedDeviceRecords = PairedAndroidDeviceStore.records()
    let incomingNotifier = IncomingCallNotifier()
    let incomingSMSNotifier = IncomingSMSNotifier()
    let liveActivity = LiveActivityController()
    private var liveActivityAgentPage = 0

    private let historyStore: LocalHistoryStore
    private lazy var vobleMode = VoBLEModeController(bluetooth: vobleHub)
    private var ownedBLESession: VoBLEDeviceSession {
        if let agent = deviceCalls.active?.agentID ?? presentedDeviceCall?.agentID,
           let value = vobleHub.retainedBundle(for: agent) { return value }
        return vobleHub.selected
    }
    private var vobleAudio: VoBLEAudioEngine { ownedBLESession.audio }
    private var vobleMedia: VoBLEGATTMediaTransport { ownedBLESession.media }
    private var vobleCalls: VoBLECallCoordinator { ownedBLESession.calls }
    private var cancellables: Set<AnyCancellable> = []

    private var pollingTask: Task<Void, Never>?
    private let callUpdateWork = CallUpdateWorkScheduler()
    private var moduleMetadataTask: Task<Void, Never>?
    private var activeOperationCount = 0
    private let localAudioStartup = LocalCallAudioStartupCoordinator()
    private var currentCallTransport: CallTransport?
    private var lockedCallTransport: LockedCallTransport?
    private var currentLocalAPI: AirSIMAPI?
    private var currentPCMRoute: PCMRoute?
    private var lastSuccessfulLocalAPI: AirSIMAPI?
    private var observedCallLocalAPI: (callID: String, service: AirSIMAPI)?
    private var callLifecycleStore = CallLifecycleStore()
    let deviceCallContext = DeviceCallContext()
    private let deviceBackendOverride: ((String, CallTransport) -> (any DeviceCallBackend)?)?
    var deviceCalls: DeviceCallRegistry {
        get { deviceCallContext.registry }
        set { deviceCallContext.registry = newValue }
    }
    private(set) lazy var deviceCallRouter: DeviceCallActionRouter = {
        let router = DeviceCallActionRouter(context: deviceCallContext) { [weak self] id, transport in
            guard let self else { return nil }
            if let override = self.deviceBackendOverride { return override(id, transport) }
            if transport == .vowlan, self.localDevices.metadata(for: id)?.canonicalCallIDs == true,
               let api = self.localDevices.api(for: id) {
                return WLANDeviceCallBackend(api: api, epoch: self.localDevices.transportEpoch(for: id))
            }
            if transport == .bluetooth, let session = self.vobleHub.bundle(for: id) {
                return BLEDeviceCallBackend(session: session)
            }
            return nil
        }
        router.onActivate = { [weak self] route in self?.activateOwnedRoute(route) }
        router.onFinish = { [weak self] key in
            guard let self, self.presentedDeviceCall == key else { return }
            self.presentOwnedCall(key, state: .ended)
        }
        router.onAnswerFailed = { [weak self] key in self?.restoreRingingAfterAnswerFailure(key) }
        router.onTerminationSettled = { [weak self] in self?.releaseInactiveLocalTransports() }
        return router
    }()
    private var presentedDeviceCall: DeviceCallKey?
    // Retain the backend identity through a local CallKit end (.ending), so
    // a later authoritative terminal event still closes the original lifecycle.
    private var pushedCallIdentity: IncomingVoIPCall?
    private var answerSnapshot: CallLifecycleSnapshot?
    private var callAnswerInFlight = false
    /// A non-terminal local call is currently presented (ringing or owned).
    var ownsLocalCallPresentation: Bool {
        presentedDeviceCall.flatMap { deviceCallRouter.route(for: $0) } != nil
    }
    /// A cloud call owns the primary lifecycle (ringing/connecting/active).
    var cloudCallOwnsPrimaryPresentation: Bool {
        callLifecycleSnapshot.state.representsCall
            && (currentCallTransport == .cloud || callLifecycleSnapshot.source == .relay)
    }
    private var ownedWLANLossTask: Task<Void, Never>?
    private var ownedWLANEpoch: UInt64?
    private var ownedRecords: [DeviceCallKey: CallRecord] = [:]
    private var ownedHistoryFinished = Set<DeviceCallKey>()
    @Published var focusedOtherDeviceCall: OtherDeviceCallReminder?
    private lazy var otherCallReminders: OtherDeviceCallReminderController = {
        let controller = OtherDeviceCallReminderController(lookup: { [weak self] key in self?.lookupOtherCall(key) })
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        controller.onNewReminder = { _ in
            if UIApplication.shared.applicationState == .active { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
        return controller
    }()
    var otherDeviceCallReminders: [OtherDeviceCallReminder] { otherCallReminders.reminders }
    private func lookupOtherCall(_ key: DeviceCallKey) -> OtherDeviceCallReminder? {
        guard key != presentedDeviceCall, let event = deviceCalls.latestEvent(for: key), event.state == .ringing else { return nil }
        let name = pairedAndroidAgents.first { $0.id == key.agentID }?.deviceName ?? "Android 手机"
        return .init(key: key, deviceName: name, number: event.number, stillRinging: true)
    }
    @discardableResult
    func openOtherDeviceCallNotification(_ info: [AnyHashable: Any]) -> Bool {
        guard let key = OtherDeviceCallReminder.key(from: info), let current = lookupOtherCall(key) else { return false }
        focusedOtherDeviceCall = current
        return true
    }
    func answerOtherDeviceCall(_ key: DeviceCallKey) async throws {
        guard deviceCalls.active == nil, deviceCallContext.admissionReservation == nil,
              !cloudCallOwnsPrimaryPresentation else { throw DeviceCallRoutingError.busy }
        guard lookupOtherCall(key) != nil else { throw DeviceCallRoutingError.stale }
        if let previous = presentedDeviceCall, previous != key {
            // End only the iPhone presentation, not the other Android's ringing call.
            if let old = deviceCallRouter.route(for: previous) {
                callKit.withdrawLocalPresentation(uuid: old.systemUUID)
                if let id = callLifecycleSnapshot.callID {
                    _ = applyCallLifecycle(.init(callID: id, callUUID: old.systemUUID,
                        generation: previous.generation, state: .ended, source: .app,
                        timestamp: Date(), traceID: nil, failure: nil))
                }
            }
            presentedDeviceCall = nil; remoteCall = nil
        }
        try deviceCallRouter.renewIdlePresentation(for: key)
        try await answerOwnedCall(key)
        focusedOtherDeviceCall = nil
        otherCallReminders.consume([])
    }

    @discardableResult
    func receiveDeviceCallEvent(_ event: DeviceCallEvent,
                                presentation: CallLifecycleEvent? = nil) -> [DeviceCallEffect] {
        let effects = deviceCalls.apply(event)
        guard let key = deviceCalls.key(agentID: event.agentID, callID: event.callID) else { return effects }
        if finishPushedCallIfNeeded(event, key: key) { return effects }
        // Explicit cloud mode must not turn an Android LAN discovery event into
        // an in-app ringing page. That page has no cloud media URL and its answer
        // falls back to VoWLAN, producing a misleading timeout. Cloud calls enter
        // through PushKit/CallKit or an already prepared cloud session.
        if ConnectionModePreference.selected() == .cloud, event.transport != .cloud {
            return effects
        }
        if presentedDeviceCall == nil, event.state.representsCall { presentedDeviceCall = key }
        if let presentation, deviceCallCanPresent(key),
           deviceCalls.latestEvent(for: key)?.state == event.state,
           deviceCalls.latestEvent(for: key)?.callID == event.callID {
            _ = applyCallLifecycle(presentation, replacingProvisionalCallID: event.replacesCallID)
        }
        if event.state.isTerminal, presentedDeviceCall == key { presentedDeviceCall = nil }
        return effects
    }

    @discardableResult
    func activateDeviceCall(_ key: DeviceCallKey) -> Bool {
        guard deviceCalls.activate(key) else { return false }
        presentedDeviceCall = key
        return true
    }

    private func deviceCallCanPresent(_ key: DeviceCallKey) -> Bool {
        if let owner = deviceCalls.active { return owner == key }
        return presentedDeviceCall == key
    }

    private func activateOwnedRoute(_ route: LockedDeviceCallRoute) {
        presentedDeviceCall = route.key
        currentCallTransport = route.transport
        lockedCallTransport = LockedCallTransport(transport: route.transport, generation: route.key.generation)
        if route.transport == .vowlan, let service = localDevices.api(for: route.key.agentID) {
            ownedWLANEpoch = localDevices.transportEpoch(for: route.key.agentID)
            currentLocalAPI = service
            currentPCMRoute = Self.pcmRoute(for: service.route)
        }
        presentOwnedCall(route.key, state: .connecting)
    }

    /// All local event subscriptions (including unselected phones) enter here.
    /// UI identity is scoped; backend/Telecom IDs remain exclusively in Router.
    @discardableResult
    func receiveOwnedCallEvent(_ event: DeviceCallEvent) -> [DeviceCallEffect] {
        let effects = deviceCallRouter.ingest(event, mode: ConnectionModePreference.selected())
        defer {
            otherCallReminders.consume(effects)
            if let focus = focusedOtherDeviceCall, lookupOtherCall(focus.key) == nil { focusedOtherDeviceCall = nil }
        }
        guard let key = deviceCalls.key(agentID: event.agentID, callID: event.callID),
              let latest = deviceCalls.latestEvent(for: key) else { return effects }
        let previousRecord = ownedRecords[key]
        if effects.contains(.ended(key)) {
            persistOwnedTerminal(key, event: latest, previous: previousRecord)
        } else if !latest.state.isTerminal {
            ownedRecords[key] = CallRecord(id: latest.callID, index: 0, direction: latest.direction,
                state: latest.state.callRecordState, number: latest.number,
                startedAt: previousRecord?.startedAt ?? Date(), updatedAt: Date(), endedAt: nil, missed: false)
        }
        if finishPushedCallIfNeeded(event, key: key) { return effects }
        if latest.state.isTerminal {
            if presentedDeviceCall == key { presentOwnedCall(key, state: latest.state) }
            return effects
        }
        if deviceCallContext.admissionReservation != nil, deviceCalls.active == nil { return effects }
        // A cloud call already owns the primary presentation. A local ringing
        // call on another transport must stay a reminder instead of taking
        // presentedDeviceCall or touching the authoritative lifecycle store.
        if latest.state == .ringing, cloudCallOwnsPrimaryPresentation {
            return effects
        }
        if latest.state == .active, deviceCalls.active != key, presentedDeviceCall == key {
            // Android itself answered. Retire this iPhone's ringing surface,
            // without acquiring PCM or ending the Android conversation.
            if let route = deviceCallRouter.route(for: key) {
                callKit.withdrawLocalPresentation(uuid: route.systemUUID, reason: .answeredElsewhere)
                _ = applyCallLifecycle(.init(callID: localPresentationID(key), callUUID: route.systemUUID,
                    generation: key.generation, state: .ended, source: .agent, timestamp: Date(), traceID: nil, failure: nil))
            }
            remoteCall = nil; presentedDeviceCall = nil
            updateOwnedPrimaryAlerts(nil)
            refreshVoBLELiveActivity()
            return effects
        }
        // An unsolicited Android-local active call never acquires remote media.
        guard deviceCalls.active == key || latest.state == .ringing else { return effects }
        guard deviceCalls.active == key || presentedDeviceCall == nil || presentedDeviceCall == key else { return effects }
        guard deviceCalls.active == nil || deviceCalls.active == key else { return effects }
        let wasPresented = presentedDeviceCall == key
        presentedDeviceCall = key
        if !presentOwnedCall(key, state: latest.state), !wasPresented {
            presentedDeviceCall = nil
        }
        return effects
    }

    private func localPresentationID(_ key: DeviceCallKey) -> String {
        "local:\(Data(key.agentID.utf8).base64EncodedString()):\(key.generation):\(deviceCallRouter.route(for: key)?.systemUUID.uuidString ?? "")"
    }

    /// Preserve the pushed UUID, backend ID and generation. A local registry
    /// key has its own serial and must never replace that primary identity.
    @discardableResult
    private func finishPushedCallIfNeeded(_ event: DeviceCallEvent, key: DeviceCallKey) -> Bool {
        let session = IPhoneCloudCallSession.shared
        guard let call = pushedCallIdentity ?? session.call,
              callLifecycleSnapshot.callID == call.callID,
              callLifecycleSnapshot.callUUID == call.uuid,
              callLifecycleSnapshot.generation == call.generation,
              callKit.currentSystemCallUUID == nil || callKit.currentSystemCallUUID == call.uuid,
              !ownsLocalCallPresentation,
              deviceCalls.active == nil || deviceCalls.active == key,
              deviceCallContext.media.owner == nil || deviceCallContext.media.owner == key,
              let latest = deviceCalls.latestEvent(for: key),
              latest.callID == event.callID, latest.state == event.state,
              latest.transport == event.transport, latest.transportEpoch == event.transportEpoch,
              latest.backendGeneration == event.backendGeneration,
              let action = PushedCallTerminationPolicy.action(
                event: event, call: call, state: callLifecycleSnapshot.state,
                answered: session.answered, systemAnswered: callKit.currentCallIsAnswered
              ) else { return false }

        // Invalidate queued answer/audio work before closing media or invoking
        // CallKit's synchronous callback. No backend hangup is sent here.
        let state: CallLifecycleState = event.state.isTerminal ? event.state : .ended
        guard applyCallLifecycle(.init(
            callID: call.callID, callUUID: call.uuid, generation: call.generation,
            state: state, source: .agent, timestamp: Date(), traceID: nil,
            failure: state == .failed ? "Agent 报告通话失败" : nil
        )) else { return false }
        beginCallTransitionProtection()
        if audio.active || audio.sessionOwner != nil { audio.deactivate() }
        if session.call?.uuid == call.uuid { session.stop() }
        deviceCallRouter.finished(key)
        if callKit.currentSystemCallUUID == call.uuid {
            callKit.reportCurrentCallEnded(reason: action == .answeredElsewhere ? .answeredElsewhere
                : (state == .failed ? .failed : .remoteEnded))
        }
        presentedDeviceCall = nil
        remoteCall = nil
        activeCall = nil
        pendingOutgoingCall = nil
        callPresentationSurface = nil
        updateOwnedPrimaryAlerts(nil)
        clearLockedTransport()
        backgroundStandby.resumeAfterCall()
        return true
    }
    func ownedWatchTarget(uuid: UUID, agentID: String?, presentationID: String? = nil)
        -> (route: LockedDeviceCallRoute, api: AirSIMAPI, backendID: String)? {
        guard let target = deviceCallRouter.wlanTarget(for: uuid, agentID: agentID),
              presentationID == nil || presentationID == localPresentationID(target.route.key) else { return nil }
        return target
    }
    static func pcmRouteForWatch(_ route: LocalAgentRoute) -> PCMRoute { pcmRoute(for: route) }
    func ownedCallUUID(for presentationID: String?) -> UUID? {
        guard let key = presentedDeviceCall, presentationID == localPresentationID(key) else { return nil }
        return deviceCallRouter.route(for: key)?.systemUUID
    }
    func beginOwnedWatchDial(number: String, requestID: UUID, bound: String?) async throws
        -> (route: LockedDeviceCallRoute, api: AirSIMAPI, backendID: String, presentationID: String)? {
        guard !ownsLocalCallPresentation, !cloudCallOwnsPrimaryPresentation else { return nil }
        guard ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN else { return nil }
        await refreshLocalDeviceDirectory()
        let ids = localDevices.agentIDs
        guard let target = bound ?? (ids.count == 1 ? ids.first : nil),
              localDevices.api(for: target) != nil,
              localDevices.metadata(for: target)?.canonicalCallIDs == true else { return nil }
        let uuid = UUID()
        deviceCallRouter.systemUUID = { uuid }
        let route = try await deviceCallRouter.dial(agentID: target, number: number, mode: .vowlan,
            reservationID: requestID, simAccount: selectedSIMSlotID(for: target))
        guard let target = deviceCallRouter.wlanTarget(for: route.systemUUID, agentID: target) else { throw DeviceCallRoutingError.stale }
        return (target.route, target.api, target.backendID, localPresentationID(route.key))
    }

    private func reconcileOwnedWLANAvailability() {
        guard let key = deviceCalls.active, currentCallTransport == .vowlan,
              let epoch = ownedWLANEpoch else { return }
        let recovered = localDevices.api(for: key.agentID) != nil
            && localDevices.transportEpoch(for: key.agentID) == epoch
        if recovered {
            ownedWLANLossTask?.cancel(); ownedWLANLossTask = nil
            return
        }
        guard ownedWLANLossTask == nil else { return }
        ownedWLANLossTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.deviceCalls.active == key, self.currentCallTransport == .vowlan,
                  self.ownedWLANEpoch == epoch,
                  self.localDevices.api(for: key.agentID) == nil
                    || self.localDevices.transportEpoch(for: key.agentID) != epoch,
                  self.deviceCallRouter.route(for: key) != nil else { return }
            try? await self.deviceCallRouter.end(key, rejectIfRinging: false)
            self.errorMessage = "当前安卓的 VoWLAN 链路已断开；本通未切换设备或音频链路，请重新拨号"
        }
    }

    /// Captures the pre-answer lifecycle so a rejected direct answer can
    /// restore the ringing page instead of leaving a false "connecting" call.
    private func answerOwnedCall(_ key: DeviceCallKey) async throws {
        let previous = callLifecycleSnapshot
        answerSnapshot = previous
        defer { answerSnapshot = nil }
        try await deviceCallRouter.answer(key)
    }

    private func restoreRingingAfterAnswerFailure(_ key: DeviceCallKey) {
        // CallKit-managed failures are finalized by callKitDidFail/finishCurrentCall.
        // Only the app-audio/direct path needs the ringing page restored.
        guard callKit.currentSystemCallUUID == nil,
              presentedDeviceCall == key,
              deviceCalls.latestEvent(for: key)?.state == .ringing,
              let previous = answerSnapshot else { return }
        callLifecycleStore.restore(previous)
        callLifecycleSnapshot = callLifecycleStore.snapshot
        presentOwnedCall(key, state: .ringing)
    }

    func answerOwnedCallFromWatch(_ key: DeviceCallKey) async throws {
        try await answerOwnedCall(key)
    }
    func performOwnedIncomingNotificationAction(_ action: String, callID: String) async throws -> Bool {
        guard callID.hasPrefix("local:") else { return false }
        guard let key = presentedDeviceCall, callID == localPresentationID(key),
              deviceCalls.latestEvent(for: key)?.state == .ringing else { throw DeviceCallRoutingError.stale }
        if action == IncomingCallNotification.answerActionIdentifier { try await answerOwnedCall(key) }
        else { try await deviceCallRouter.end(key, rejectIfRinging: true) }
        return true
    }

    @discardableResult
    private func presentOwnedCall(_ key: DeviceCallKey, state: CallLifecycleState) -> Bool {
        guard let route = deviceCallRouter.route(for: key),
              let event = deviceCalls.latestEvent(for: key),
              presentedDeviceCall == key else { return false }
        let id = localPresentationID(key)
        let previous = remoteCall
        let record = CallRecord(id: id, index: 0, direction: event.direction,
            state: state.callRecordState, number: event.number,
            startedAt: previous?.id == id ? previous!.startedAt : Date(), updatedAt: Date(),
            endedAt: state.isTerminal ? Date() : nil, missed: false)
        guard applyCallLifecycle(.init(callID: id, callUUID: route.systemUUID, generation: key.generation,
            state: state, source: .agent, timestamp: Date(), traceID: nil, failure: nil)) else { return false }
        if state.isTerminal {
            persistOwnedTerminal(key, event: event, previous: ownedRecords[key] ?? previous)
            ownedWLANLossTask?.cancel(); ownedWLANLossTask = nil; ownedWLANEpoch = nil
            remoteCall = nil; activeCall = nil; pendingOutgoingCall = nil
            presentedDeviceCall = nil
            if callKit.currentSystemCallUUID == route.systemUUID {
                callKit.reportCurrentCallEnded(reason: .remoteEnded)
            }
            if route.transport == .vowlan, audio.active || audio.sessionOwner != nil { audio.deactivate() }
            else { audio.stopCallTone() }
            updateOwnedPrimaryAlerts(nil)
            clearLockedTransport()
            let policy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
            releaseInactiveLocalTransports()
            callKit.setEnabled(policy.usesCallKit)
            backgroundStandby.resumeAfterCall()
        } else {
            remoteCall = record
            ownedRecords[key] = record
            callKit.synchronizeOwnedCall(record, uuid: route.systemUUID, agentID: key.agentID)
            if state == .ringing, callKit.currentSystemCallUUID == nil,
               ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).usesCallKit {
                let incoming = IncomingVoIPCall(bluetoothCallID: id, uuid: route.systemUUID,
                    generation: key.generation, number: event.number, agentID: key.agentID)
                callKit.reportIncomingPush(incoming) { [weak self] error in
                    guard let self, self.presentedDeviceCall == key, let error else { return }
                    self.errorMessage = error.localizedDescription
                    self.updateOwnedPrimaryAlerts(self.remoteCall)
                }
            }
            updateOwnedPrimaryAlerts(record)
            callPresentationSurface = callPresentationSurface ?? (appIsActive ? .app : .system)
            if state == .active {
                callKit.reportCurrentOutgoingConnected()
                if route.transport == .vowlan, deviceCallContext.media.owner == key {
                    Task { @MainActor [weak self] in await self?.startCallAudioIfReady() }
                }
            }
        }
        WatchCallCoordinator.shared.publish(call: state.isTerminal ? nil : record,
            previous: state.isTerminal ? record : nil, callerName: event.number.map { contacts.displayName(for: $0) },
            transport: route.transport == .bluetooth ? "bluetooth" : "vowlan")
        refreshVoBLELiveActivity()
        otherCallReminders.consume([])
        objectWillChange.send()
        return true
    }

    private func updateOwnedPrimaryAlerts(_ call: CallRecord?) {
        let suppressed = call?.direction == "incoming" && callKit.suppressesInAppIncomingRingtone
        incomingNotifier.update(call: suppressed ? nil : call,
            callerName: call.map { contacts.displayName(for: $0.number) }, appIsActive: appIsActive)
        if suppressed || WatchCallCoordinator.shared.ownsMedia(callID: call?.id) { audio.stopCallTone() }
        else { audio.updateCallTone(for: call) }
    }

    private func persistOwnedTerminal(_ key: DeviceCallKey, event: DeviceCallEvent, previous: CallRecord?) {
        guard ownedHistoryFinished.insert(key).inserted else { return }
        var record = CallRecord(id: event.backendCallID ?? event.callID, index: 0, direction: event.direction,
            state: "ended", number: event.number, startedAt: previous?.startedAt ?? Date(), updatedAt: Date(),
            endedAt: Date(), missed: event.direction == "incoming" && previous?.state != "active" && previous?.state != "held",
            androidID: event.callID)
        record.historyEstimated = true
        _ = persistDeviceHistory([record], agentID: key.agentID)
        ownedRecords.removeValue(forKey: key)
        if ownedHistoryFinished.count > 256 { ownedHistoryFinished = [key] }
    }

    @discardableResult
    private func persistDeviceHistory(_ records: [CallRecord], agentID: String) -> Bool {
        var byID = Dictionary(callHistory.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        for raw in records {
            let record = raw.scopedHistory(to: agentID)
            if let old = byID[record.id] {
                if old.historyEstimated != true && record.historyEstimated == true { continue }
                if old.historyEstimated == record.historyEstimated && old.updatedAt > record.updatedAt { continue }
            }
            byID[record.id] = record
        }
        callHistory = normalizedCallHistory(Array(byID.values))
        return historyStore.saveCallHistory(callHistory)
    }
    private var appIsActive = true
    private let initialPermissionCoordinator = InitialPermissionCoordinator()
    private var initialPermissionTask: Task<Void, Never>?
    private var eventRevision: UInt64 = AgentEventCursor.initial
    private var smsRevision: UInt64 = 0
    private var eventStreamSupported: Bool?
    private var pollingGeneration = 0
    private var hasStarted = false
    private var consecutivePollFailures = 0
    private var callTransitionProtectedUntil = Date.distantPast
    private var nextAudioDiagnosticRefresh = Date.distantPast
    private var nextModuleMetadataRefresh = Date.distantPast
    private var lastCloudStatusRefresh = Date.distantPast
    // Query scheduling can be rearmed/cancelled without invalidating a received
    // Relay result. Never use the query sentinel as connectivity evidence.
    private var lastCloudStatusReceivedAt = Date.distantPast
    private let cloudStatusFetcher: @MainActor () async throws -> CloudAgentStatus
    private let cloudOutgoingStarter: @MainActor (String, CloudCommandTarget) async throws -> IncomingVoIPCall
    private let cloudStatusNow: () -> Date
    private var cloudStatusRefreshTask: Task<Void, Never>?
    private var cloudStatusRefreshGeneration = 0
    private var audioWarmupCallID: String?
    private var lowPowerModeEnabled = true
    private let backgroundStandbyKey = BackgroundStandbyPreference.key
    private let lowPowerModeKey = "airsim.low-power-mode-enabled"
    private let maxCallHistoryCount = 500
    private let maxMessageCount = 2_000

    var inAppPresentedCall: CallRecord? {
        return CallPresentationPolicy.inAppCall(
            surface: callPresentationSurface,
            local: lifecycleRecord(from: activeCall),
            remote: lifecycleRecord(from: remoteCall),
            pending: pendingOutgoingCall
        )
    }

    var callAudioIsActive: Bool {
        (audio.active && audio.transportReady) || bluetoothPCMConnected
            || cloudCallAudioState.isConnected || VirtualCallTTSController.shared.isPrepared
    }

    /// The actual BLE PCM path, not just the selected session. The engine and
    /// media transport live on the call-owned session; looking only at
    /// vobleAudio.running can read a different session and leave the call page
    /// stuck at "establishing" after PCM is already flowing.
    private var bluetoothPCMConnected: Bool {
        guard currentCallTransport == .bluetooth else { return false }
        if let agent = deviceCalls.active?.agentID ?? presentedDeviceCall?.agentID,
           let bundle = vobleHub.retainedBundle(for: agent) {
            return bundle.audio.running || bundle.media.isRunning
        }
        return vobleAudio.running || vobleMedia.isRunning
            || vobleHub.sessions.values.contains { $0.audio.running || $0.media.isRunning }
    }

    /// Explicit diagnostics read only; never fall back to Relay or an unrelated phone.
    var verboseDiagnosticsAPI: AirSIMAPI? {
        guard ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN else { return nil }
        return verifiedVoWLANAPI()
    }

    var connectionModePresentation: ConnectionModePresentation {
        ConnectionModePresentation.make(
            selectedMode: ConnectionModePreference.selected(),
            vowlanOnline: verifiedVoWLANAPI() != nil,
            bluetoothReady: boundBluetoothReady,
            cloudModeEnabled: CloudModePreference.isEnabled(),
            cloudOnline: boundCloudReady
        )
    }

    var vobleDiagnostics: VoBLEDiagnosticsSnapshot {
        VoBLEDiagnosticsSnapshot(
            selectedMode: ConnectionModePreference.selected().title,
            connection: String(describing: vobleHub.pairingState),
            peerAuthenticated: voble.authenticatedIdentity != nil,
            agentType: "Android VoBLE Agent",
            pcmReady: vobleMedia.isRunning,
            codec: "G.711 μ-law / 8 kHz mono",
            queuedFrames: vobleMedia.queuedFrameCount,
            droppedFrames: vobleMedia.droppedFrameCount,
            jitterFrames: vobleMedia.jitterTargetFrames,
            lastError: .classify(voble.errorMessage ?? vobleAudio.errorMessage))
    }

    var pairedAndroidAgents: [AndroidAgentPresentation] {
        androidAgentPresentations(discoveredAgents: vowlan.discoveredAgents)
    }

    func androidAgentPresentations(discoveredAgents: [VoWLANDiscoveredAgent]) -> [AndroidAgentPresentation] {
        let cloudStatus = cloudStatusForPresentation
        let cloudStatusIsFresh = cloudStatus != nil
        var values: [String: AndroidAgentPresentation] = [:]

        for agent in cloudStatus?.agents ?? [] {
            guard PairedAndroidDeviceStore.permits(agent.id) else { continue }
            let name = agent.deviceName?.isEmpty == false
                ? agent.deviceName!
                : [agent.manufacturer, agent.model].compactMap { $0 }.joined(separator: " ")
            values[agent.id] = AndroidAgentPresentation(
                id: agent.id,
                deviceName: name.isEmpty ? "Android 手机" : name,
                phoneNumber: cloudStatusIsFresh && agent.cloudOnline && agent.phoneNumber?.isEmpty == false
                    ? agent.phoneNumber : nil,
                agentKind: agent.agentKind,
                cloudOnline: cloudStatusIsFresh && agent.cloudOnline,
                vowlanOnline: false,
                bluetoothOnline: false,
                isCurrent: false
            )
        }

        let recordedDevices = Dictionary(uniqueKeysWithValues: pairedDeviceRecords.map { ($0.id, $0) })
        for local in discoveredAgents {
            let previous = values[local.id]
            let recorded = recordedDevices[local.id]
            // Bonjour/manual candidates locate a peer; they do not prove pairing
            // or authenticate TXT metadata, even when they claim a known Agent ID.
            guard PairedAndroidDeviceStore.permits(local.id), previous != nil || recorded != nil else { continue }
            values[local.id] = AndroidAgentPresentation(
                id: local.id,
                deviceName: previous?.deviceName ?? recorded?.deviceName ?? "Android 手机",
                phoneNumber: previous?.phoneNumber,
                agentKind: previous?.agentKind ?? recorded?.agentKind,
                cloudOnline: previous?.cloudOnline ?? false,
                vowlanOnline: localDevices.routes(for: local.id)?.vowlan == local.endpoint,
                bluetoothOnline: previous?.bluetoothOnline ?? false,
                isCurrent: false
            )
        }

        let bluetoothReady = boundBluetoothReady
        for bundle in vobleHub.sessions.values {
            let central = bundle.central
            guard central.state == .ready, let bluetoothID = central.authenticatedIdentity,
                  PairedAndroidDeviceStore.permits(bluetoothID) else { continue }
            let previous = values[bluetoothID]
            let information = central.deviceInformation
            values[bluetoothID] = AndroidAgentPresentation(
                id: bluetoothID,
                deviceName: information?.deviceName ?? central.currentDeviceName ?? "Android 蓝牙 Agent",
                // A fresh device_info is authoritative even when the new SIM
                // cannot expose its number. Falling back would retain the old
                // number after a SIM swap.
                phoneNumber: information == nil
                    ? previous?.phoneNumber
                    : Self.agentPhoneNumber(information?.phoneNumber, slots: information?.simSlots),
                agentKind: information?.agentKind ?? previous?.agentKind,
                cloudOnline: previous?.cloudOnline ?? false,
                vowlanOnline: previous?.vowlanOnline ?? false,
                bluetoothOnline: true,
                isCurrent: false
            )
        }

        for id in localDevices.agentIDs {
            guard let health = localDevices.metadata(for: id), PairedAndroidDeviceStore.permits(id) else { continue }
            let previous = values[id]
            values[id] = .init(id: id, deviceName: health.deviceName ?? previous?.deviceName ?? "Android 手机",
                phoneNumber: Self.agentPhoneNumber(health.phoneNumber, slots: health.simSlots),
                agentKind: health.agentKind ?? previous?.agentKind,
                cloudOnline: previous?.cloudOnline ?? false, vowlanOnline: true,
                bluetoothOnline: previous?.bluetoothOnline ?? false, isCurrent: false)
        }

        if values.isEmpty, let cloudStatus, cloudStatusIsFresh, cloudStatus.cloudOnline,
           cloudStatus.activeAgentID.map({ PairedAndroidDeviceStore.permits($0) }) != false {
            let fallbackID = cloudStatus.activeAgentID ?? "cloud-agent"
            values[fallbackID] = AndroidAgentPresentation(
                id: fallbackID,
                deviceName: "Android 手机",
                phoneNumber: nil,
                agentKind: nil,
                cloudOnline: true,
                vowlanOnline: false,
                bluetoothOnline: false,
                isCurrent: false
            )
        }

        let currentID: String? = {
            // A bound device that is currently unreachable must not make the
            // dial pad present a different phone as current while callKitStart
            // still routes to the binding. Show no current device instead so
            // the user explicitly rebinds/selects an online phone.
            if let bound = AndroidAgentBindingPreference.selected() {
                return values[bound] != nil ? bound : nil
            }
            if values.count > 1 { return nil }
            if let api = selectedDirectoryAPI, case let .vowlan(endpoint, _) = api.route {
                return localDevices.agentIDs.first { localDevices.routes(for: $0)?.vowlan == endpoint }
            }
            let route = DialRouteSelector.preferred(
                mode: ConnectionModePreference.selected(),
                vowlanReady: vowlan.availability.isOnlineForDisplay,
                bluetoothReady: bluetoothReady,
                cloudReady: CloudModePreference.isEnabled()
                    && cloudStatusIsFresh && cloudStatus?.cloudOnline == true
            )
            if route == .vowlan, let endpoint = vowlan.availability.endpoint {
                return discoveredAgents.first(where: { $0.endpoint == endpoint })?.id
            }
            if route == .bluetooth { return voble.authenticatedIdentity }
            if route == .cloud {
                return cloudStatus?.activeAgentID
                    ?? cloudStatus?.agents.first(where: \.cloudOnline)?.id
            }
            return nil
        }()

        return values.values.map { item in
            AndroidAgentPresentation(
                id: item.id,
                deviceName: item.deviceName,
                phoneNumber: item.phoneNumber,
                agentKind: item.agentKind,
                cloudOnline: item.cloudOnline,
                vowlanOnline: item.vowlanOnline,
                bluetoothOnline: item.bluetoothOnline,
                isCurrent: item.id == currentID
            )
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            let leftOnline = $0.vowlanOnline || $0.bluetoothOnline || $0.cloudOnline
            let rightOnline = $1.vowlanOnline || $1.bluetoothOnline || $1.cloudOnline
            if leftOnline != rightOnline { return leftOnline }
            return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
        }
    }

    var currentAndroidAgent: AndroidAgentPresentation? {
        pairedAndroidAgents.first(where: \.isCurrent)
    }

    /// The Agent identity number can arrive via BLE metadata or VoWLAN health;
    /// one transport may omit it while SIM slots still carry a display number.
    /// Prefer the authoritative current SIM slot; empty means the SIM exists
    /// but its number is unavailable, not "keep the previous number".
    static func agentPhoneNumber(_ direct: String?, slots: [AndroidSIMSlot]?) -> String? {
        if let value = direct?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let slots = slots ?? []
        return slots.first(where: { $0.isDefault == true })?.displayNumber
            ?? slots.compactMap(\.displayNumber).first
    }

    // MARK: - SIM / PhoneAccount selection

    private var simSlotOverrides: [String: [AndroidSIMSlot]] = [:]

    private func simSlotPreferenceKey(_ agentID: String) -> String {
        "airsim.sim-account.\(agentID)"
    }

    /// Slots are authoritative from the session that owns this agent: BLE
    /// device_info first, then VoWLAN health. Both are in-memory only.
    func simSlots(for agentID: String) -> [AndroidSIMSlot] {
        if let slots = simSlotOverrides[agentID], !slots.isEmpty { return slots }
        if let bundle = vobleHub.retainedBundle(for: agentID),
           let slots = bundle.central.deviceInformation?.simSlots, !slots.isEmpty {
            return slots
        }
        if let slots = localDevices.metadata(for: agentID)?.simSlots, !slots.isEmpty {
            return slots
        }
        if vobleHub.selected.central.authenticatedIdentity == agentID,
           let slots = vobleHub.selected.central.deviceInformation?.simSlots, !slots.isEmpty {
            return slots
        }
        return []
    }

    func selectedSIMSlotID(for agentID: String) -> String? {
        let slots = simSlots(for: agentID)
        guard !slots.isEmpty else { return nil }
        let key = simSlotPreferenceKey(agentID)
        if let saved = UserDefaults.standard.string(forKey: key),
           slots.contains(where: { $0.id == saved }) { return saved }
        return slots.first(where: { $0.isDefault == true })?.id ?? slots.first?.id
    }

    func selectedSIMSlot(for agentID: String) -> AndroidSIMSlot? {
        let id = selectedSIMSlotID(for: agentID)
        return simSlots(for: agentID).first { $0.id == id }
    }

    func selectSIMSlot(_ id: String, for agentID: String) {
        guard simSlots(for: agentID).contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: simSlotPreferenceKey(agentID))
        objectWillChange.send()
    }

    /// History retains identity/name only; numbers and online state come from the live session.
    var pairedDeviceHistory: [AndroidAgentPresentation] {
        var values = Dictionary(uniqueKeysWithValues: pairedDeviceRecords.map {
            ($0.id, AndroidAgentPresentation(id: $0.id, deviceName: $0.deviceName, phoneNumber: nil,
                agentKind: $0.agentKind, cloudOnline: false, vowlanOnline: false, isCurrent: false))
        })
        let registeredCloudIDs = Set((cloudAgentDirectory ?? cloudAgentStatus)?.agents.map(\.id) ?? [])
        for agent in pairedAndroidAgents where values[agent.id] != nil || registeredCloudIDs.contains(agent.id)
                || agent.cloudOnline || agent.bluetoothOnline || agent.vowlanOnline {
            values[agent.id] = agent
        }
        return values.values.filter { PairedAndroidDeviceStore.permits($0.id) }
            .sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
    }

    private func rememberVerifiedDevices() {
        let registeredCloudIDs = Set((cloudAgentDirectory ?? cloudAgentStatus)?.agents.map(\.id) ?? [])
        for agent in pairedAndroidAgents where registeredCloudIDs.contains(agent.id)
                || agent.cloudOnline || agent.bluetoothOnline
                || (agent.vowlanOnline && vowlan.availability.isOnlineForDisplay
                    && vowlan.discoveredAgents.contains { $0.id == agent.id && $0.endpoint == vowlan.availability.endpoint }) {
            PairedAndroidDeviceStore.remember(.init(id: agent.id, deviceName: agent.deviceName, agentKind: agent.agentKind))
        }
        let records = PairedAndroidDeviceStore.records()
        if records != pairedDeviceRecords { pairedDeviceRecords = records }
    }

    func forgetAndroidDevice(_ agentID: String) async throws {
        guard !callLifecycleSnapshot.state.representsCall else {
            throw NSError(domain: "AirSIM.Pairing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先结束当前通话，再删除配对设备"])
        }
        // Block before awaiting unpair, so delayed discovery/status callbacks cannot restore it.
        PairedAndroidDeviceStore.forget(agentID)
        if CloudAgentTargetStore.last() == agentID {
            CloudAgentTargetStore.forget()
        }
        // A stale Agent target is enough for cloud dialing. Clear the last-known
        // target when the user removes the final paired device, otherwise a
        // removed phone can still produce a cloud call page.
        if PairedAndroidDeviceStore.records().isEmpty {
            AndroidAgentBindingPreference.set(nil)
            CloudAgentTargetStore.forget()
        }
        pairedDeviceRecords = PairedAndroidDeviceStore.records()
        vowlan.forget(agentID)
        try await localDevices.forget(agentID: agentID)
        try await vobleHub.forget(agentID: agentID)
        objectWillChange.send()
        if hasStarted { restartPolling() }
    }

    func refreshPairedDeviceInformation() async {
        if ConnectionModePreference.selected() != .bluetooth { await vowlan.probeNow() }
        if voble.state == .ready { await voble.refreshDeviceInformation() }
        // This is a user-triggered one-shot refresh, never a new Relay polling loop.
        if CloudModePreference.isEnabled() { _ = await refreshCloudStatusForDiagnostics() }
        rememberVerifiedDevices()
    }

    func bindAndroidAgent(_ agentID: String) {
        guard PairedAndroidDeviceStore.permits(agentID) else { return }
        AndroidAgentBindingPreference.set(agentID)
        CloudAgentTargetStore.remember(agentID)
        liveActivityAgentPage = 0
        if let peer = PairedAndroidDeviceStore.peripheralID(for: agentID) { vobleHub.select(peripheralID: peer) }
        vobleHub.ensureConnected(agentID: agentID)
        vowlan.bind(to: agentID)
        objectWillChange.send()
        if hasStarted, deviceCalls.active == nil { restartPolling() }
    }

    private var boundAgentID: String? { AndroidAgentBindingPreference.selected() }

    func completeLocalPairing(agentID: String, registration: AgentPushRegistration,
                              endpoint: VoWLANEndpoint? = nil,
                              clockOffset: TimeInterval = 0) async throws {
        guard let encoded = registration.vowlanSecret else { throw VoWLANAuthError.invalidSecret }
        let credential = try VoWLANCredential(encodedSecret: encoded, clockOffset: clockOffset)
        localDevices.stagePairing(agentID: agentID, credential: credential)
        if let endpoint {
            // The claim's route proof already authenticated this endpoint and
            // secret. Save it before the optional health probe so a slow
            // Tailscale/VPN round trip does not throw away a valid pairing.
            try? await localDevices.persistPairing(
                agentID: agentID, credential: credential, endpoint: endpoint,
                deviceName: nil)
            try? await localDevices.verifyPairing(
                agentID: agentID, endpoint: endpoint, credential: credential)
        }
        await vowlan.refreshAfterPairing()
        await refreshLocalDeviceDirectory()
    }

    private func refreshLocalDeviceDirectory() async {
        localDirectoryRefreshPending = true
        if let localDirectoryRefresh { await localDirectoryRefresh.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            while self.localDirectoryRefreshPending, !Task.isCancelled {
              self.localDirectoryRefreshPending = false
              let candidates = self.vowlan.discoveredAgents
              await self.localDevices.verifyCandidates(candidates)
              guard !Task.isCancelled else { return }
              for candidate in candidates { self.rememberVerifiedLocalDevice(candidate) }
            }
            self.pairedDeviceRecords = PairedAndroidDeviceStore.records()
        }
        localDirectoryRefresh = task
        await task.value
        localDirectoryRefresh = nil
    }

    func rememberVerifiedLocalDevice(_ candidate: VoWLANDiscoveredAgent) {
        guard PairedAndroidDeviceStore.permits(candidate.id),
              let identity = localDevices.metadata(for: candidate.id) else { return }
        let recorded = PairedAndroidDeviceStore.records().first { $0.id == candidate.id }
        let name = identity.deviceName.flatMap { $0.isEmpty ? nil : $0 }
        PairedAndroidDeviceStore.remember(.init(id: candidate.id,
            deviceName: name ?? recorded?.deviceName ?? "Android 手机",
            agentKind: identity.agentKind ?? recorded?.agentKind))
    }

    private var boundVoWLANAgent: VoWLANDiscoveredAgent? {
        guard let boundAgentID else {
            return vowlan.availability.endpoint.flatMap { endpoint in
                vowlan.discoveredAgents.first(where: { $0.endpoint == endpoint })
            }
        }
        return vowlan.discoveredAgents.first(where: { $0.id == boundAgentID })
    }

    private func permitsVoWLANEndpoint(_ endpoint: VoWLANEndpoint?) -> Bool {
        guard let endpoint else { return false }
        if let agent = vowlan.discoveredAgents.first(where: { $0.endpoint == endpoint }),
           !PairedAndroidDeviceStore.permits(agent.id) { return false }
        guard boundAgentID != nil else { return true }
        return boundVoWLANAgent?.endpoint == endpoint
    }

    private var boundBluetoothReady: Bool {
        if let id = boundAgentID { return vobleHub.bundle(for: id) != nil && PairedAndroidDeviceStore.permits(id) }
        guard voble.state == .ready else { return false }
        guard let id = voble.authenticatedIdentity, PairedAndroidDeviceStore.permits(id) else { return false }
        return AndroidAgentBindingPreference.permits(voble.authenticatedIdentity)
    }

    /// Dialing needs a target, not a fresh heartbeat. The bound agent or the last
    /// known agent remains valid while Relay status is stale/unavailable.
    private var boundCloudReady: Bool { cloudDialTarget() != nil }

    private func cloudDialTarget(bound: String? = nil) -> CloudCommandTarget? {
        guard CloudModePreference.isEnabled() else { return nil }
        for candidate in [bound ?? boundAgentID, CloudAgentTargetStore.last()] {
            guard let candidate, CloudAgentRouting.validID(candidate),
                  PairedAndroidDeviceStore.permits(candidate) else { continue }
            return CloudCommandTarget(agentID: candidate, routingVersion: 1)
        }
        guard let status = cloudAgentDirectory ?? cloudAgentStatus else { return nil }
        return try? cloudTarget(status: status, bound: bound, requireOnline: false)
    }

    private var cloudStatusForPresentation: CloudAgentStatus? {
        guard CloudModePreference.isEnabled(),
              lastCloudStatusReceivedAt != .distantPast else { return nil }
        // Idle foreground/background do not poll Relay. Keep the last confirmed snapshot
        // instead of turning missing observations into an invented offline result.
        // Foreground entry/dial/explicit diagnostics still obtain fresh status;
        // this presentation cache never authorizes a carrier command by itself.
        return cloudAgentDirectory ?? cloudAgentStatus
    }

    private func cloudTarget(status: CloudAgentStatus, bound: String?,
                             requireOnline: Bool = true) throws -> CloudCommandTarget {
        try CloudAgentRouting.select(boundAgentID: bound,
            agents: status.agents.filter { PairedAndroidDeviceStore.permits($0.agentID) },
            relayRoutingVersion: status.commandRoutingVersion,
            requireOnline: requireOnline)
    }

    private func startCloudStatusQueryIfNeeded(beforeBackgroundCall: Bool = false) {
        let isForeground = appIsActive
        guard AppRefreshPolicy.shouldQueryCloudStatus(
                cloudModeEnabled: CloudModePreference.isEnabled(),
                lastAttempt: lastCloudStatusRefresh,
                appIsForeground: isForeground,
                beforeLiveActivityCall: beforeBackgroundCall
              ) else { return }
        lastCloudStatusRefresh = cloudStatusNow()
        // Keep the last known snapshot while refreshing. Clearing it here made a
        // transient /devices/status failure disable cloud dialing entirely.
        let generation = cloudStatusRefreshGeneration
        cloudStatusRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await self.cloudStatusFetcher()
                guard !Task.isCancelled,
                      generation == self.cloudStatusRefreshGeneration else { return }
                self.cloudAgentDirectory = status
                self.cloudAgentStatus = status
                self.cloudStatusError = nil
                self.lastCloudStatusReceivedAt = self.cloudStatusNow()
                if let target = try? self.cloudTarget(
                    status: status, bound: self.boundAgentID, requireOnline: false) {
                    CloudAgentTargetStore.remember(target.agentID)
                }
                self.rememberVerifiedDevices()
                if !self.isOnline && !self.vowlan.availability.isOnlineForDisplay {
                    self.connectionSummary = ModuleConnectionPolicy.summary(
                        localControlReachable: false,
                        cloudHeartbeatFresh: status.cloudOnline,
                        cellularState: status.cellularState
                    )
                }
            } catch {
                guard !Task.isCancelled,
                      generation == self.cloudStatusRefreshGeneration else { return }
                self.cloudStatusError = error.localizedDescription
                // Retain cloudAgentStatus / cloudAgentDirectory. A failed probe is
                // not proof that the previously known Agent disappeared.
            }
        }
    }

    private func awaitCloudStatusForLiveActivity(call: CallRecord?) async {
        // An incoming call can update an existing Live Activity while the App is backgrounded.
        // Query once before that update, but never poll Relay for idle background updates.
        startCloudStatusQueryIfNeeded(beforeBackgroundCall: call != nil)
        await cloudStatusRefreshTask?.value
    }

    @discardableResult
    func refreshCloudStatusForDiagnostics() async -> CloudAgentStatus? {
        guard CloudModePreference.isEnabled() else {
            cloudAgentStatus = nil
            cloudAgentDirectory = nil
            lastCloudStatusReceivedAt = .distantPast
            return nil
        }
        do {
            let status = try await cloudStatusFetcher()
            cloudAgentStatus = status
            cloudAgentDirectory = status
            cloudStatusError = nil
            lastCloudStatusReceivedAt = cloudStatusNow()
            if let target = try? cloudTarget(status: status, bound: boundAgentID,
                                             requireOnline: false) {
                CloudAgentTargetStore.remember(target.agentID)
            }
            rememberVerifiedDevices()
            lastCloudStatusRefresh = cloudStatusNow()
            if !vowlan.availability.isOnlineForDisplay {
                connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: status.cloudOnline,
                    cellularState: status.cellularState
                )
            }
            return status
        } catch {
            // Diagnostics must not destroy the last valid target. Keep the
            // snapshot and let enqueue decide whether cloud dialing is possible.
            cloudStatusError = error.localizedDescription
            return nil
        }
    }

    var callUsesVoWLAN: Bool { currentCallTransport == .vowlan }

    var dialPadTransportPresentation: DialPadTransportPresentation? {
        DialPadTransportPresentation.make(
            mode: ConnectionModePreference.selected(),
            vowlanOnline: verifiedVoWLANAPI() != nil,
            cloudOnline: boundCloudReady,
            bluetoothReady: boundBluetoothReady
        )
    }

    /// 拨号页不能只依赖 `isOnline`：该字段代表 VoWLAN 本地控制链路，Android 仅通过
    /// Relay 保持心跳时会刻意为 false。云端模式开启且心跳新鲜时，同样允许
    /// 用户发起拨号，实际执行仍会在 CallKit action 中再次鉴权和确认状态。
    var canStartOutgoingCommand: Bool {
        OutgoingCommandAvailability.isAvailable(
            mode: ConnectionModePreference.selected(),
            localControlReachable: verifiedVoWLANAPI() != nil,
            bluetoothReady: boundBluetoothReady,
            cloudModeEnabled: CloudModePreference.isEnabled(),
            cloudHeartbeatFresh: boundCloudReady
        )
    }

    var callAudioStatusText: String {
        if currentCallTransport == .vowlan,
           !audio.transportReady, let error = audio.errorMessage { return error }
        return CallAudioStatusPresentation.text(
            transport: currentCallTransport, bluetoothRunning: bluetoothPCMConnected,
            bluetoothError: vobleAudio.errorMessage, localAudioActive: audio.active && audio.transportReady,
            cloudState: cloudCallAudioState)
    }

    init(audioController: AudioSessionController? = nil,
         contactStore: ContactStore? = nil,
         deviceBackend: ((String, CallTransport) -> (any DeviceCallBackend)?)? = nil,
         localDirectory: LocalDeviceDirectory? = nil,
         bluetoothHub: VoBLEDeviceHub? = nil,
         callKitController: CallKitController? = nil,
         historyStore: LocalHistoryStore? = nil,
         cloudStatusFetcher: @escaping @MainActor () async throws -> CloudAgentStatus = {
             try await VoIPPushController.shared.fetchCloudAgentStatus()
         },
         cloudOutgoingStarter: @escaping @MainActor (String, CloudCommandTarget) async throws -> IncomingVoIPCall = { number, target in
             try await VoIPPushController.shared.startCloudOutgoingCall(number: number, target: target)
         },
         cloudStatusNow: @escaping () -> Date = Date.init) {
        self.contacts = contactStore ?? ContactStore()
        self.cloudStatusFetcher = cloudStatusFetcher
        self.cloudOutgoingStarter = cloudOutgoingStarter
        self.cloudStatusNow = cloudStatusNow
        self.audio = audioController ?? AudioSessionController()
        self.historyStore = historyStore ?? LocalHistoryStore()
        self.callKit = callKitController ?? .shared
        (UIApplication.shared.delegate as? AirSIMNotificationDelegate)?
            .releaseColdLaunchHandler()
        self.vobleHub = bluetoothHub ?? VoBLEDeviceHub()
        self.deviceBackendOverride = deviceBackend
        if let localDirectory { self.localDevices = localDirectory }
        let runtimePolicy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
        VoIPPushController.shared.registrationAPIs = { [weak self] in
            guard let self else { return [] }
            var apis = self.localDevices.agentIDs.filter { PairedAndroidDeviceStore.permits($0) }
                .compactMap { self.localDevices.api(for: $0) }
            if let legacy = self.verifiedVoWLANAPI(), !apis.contains(where: { $0.route == legacy.route }) {
                apis.append(legacy)
            }
            return apis
        }
        localDevices.onVerified = { api in
            Task { await VoIPPushController.shared.syncRegistration(with: api) }
        }
        localDevices.onCallEvent = { [weak self] event in _ = self?.receiveOwnedCallEvent(event) }
        localDevices.onHistory = { [weak self] records, source in self?.persistDeviceHistory(records, agentID: source) ?? false }
        localDevices.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.reconcileOwnedWLANAvailability() }
        }
            .store(in: &cancellables)
        if runtimePolicy.startsVoWLAN { localDevices.start() }
        callKit.handler = self
        callKit.setEnabled(runtimePolicy.usesCallKit)
        WatchCallCoordinator.shared.configure(model: self)
        WatchCallCoordinator.shared.start()
        IPhoneCloudCallSession.shared.onAudioStateChange = { [weak self] state in
            self?.cloudCallAudioState = state
            if state.isConnected { self?.audio.retryRequestedSpeakerRoute() }
        }
        IPhoneCloudCallSession.shared.onLifecycleEvent = { [weak self] event in
            guard let self else { return }
            guard self.deviceCalls.active == nil else { return }
            let applied = self.applyCallLifecycle(event)
            if event.state.isTerminal {
                self.callPresentationSurface = nil
                if event.state == .failed { self.errorMessage = event.failure }
                // End even when applyCallLifecycle rejected a duplicate/reordered ended
                // event; otherwise the island keeps counting with a dead hangup button.
                Task { @MainActor [weak self] in
                    await self?.refreshLiveActivityIdle()
                }
            }
            guard applied else { return }
            if event.state == .active {
                self.callKit.reportCurrentOutgoingConnected()
                self.updateRemoteCallState("active")
                Task { @MainActor [weak self] in await self?.startCallAudioIfReady() }
            }
        }
        LiveActivityActionBridge.handler = { [weak self] action, callID in
            guard let self else { return false }
            return await self.performLiveActivityAction(action, callID: callID)
        }
        LiveActivityActionBridge.agentSelectionHandler = { [weak self] agentID in
            guard let self else { return false }
            return await self.selectAndroidAgent(agentID)
        }
        vowlan.onAvailabilityChange = { [weak self] availability in
            guard let self else { return }
            self.objectWillChange.send()
            if availability.isOnlineForDisplay {
                Task { @MainActor in self.rememberVerifiedDevices() }
            }
            if case let .verified(endpoint, _) = availability,
               let credential = self.credentialForVoWLANEndpoint(endpoint),
               CloudSignalingPreference.isEnabled() {
                let vowlanAPI = AirSIMAPI(route: .vowlan(
                    endpoint: endpoint,
                    credential: credential
                ))
                Task {
                    await VoIPPushController.shared.syncRegistration(with: vowlanAPI)
                }
            }
            guard self.currentCallTransport == .vowlan,
                  self.deviceCalls.active == nil,
                  case .unavailable = availability,
                  self.callLifecycleSnapshot.state.representsCall else { return }
            Task { @MainActor [weak self] in await self?.endVoWLANCallAfterPathLoss() }
        }
        vowlan.onDiscoveredAgentsChange = { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in await self?.refreshLocalDeviceDirectory() }
        }
        vowlan.callInProgress = { [weak self] in
            guard let self else { return false }
            return VoWLANNetworkChangePolicy.preservesCallRoute(
                state: self.callLifecycleSnapshot.state,
                transportLocked: self.currentCallTransport != nil,
                cloudCallActive: IPhoneCloudCallSession.shared.hasActiveCall)
        }
        vowlan.onNetworkRecoveryVerified = { [weak self] in
            guard let self, self.hasStarted,
                  !self.callLifecycleSnapshot.state.representsCall,
                  !IPhoneCloudCallSession.shared.hasActiveCall else { return }
            self.restartPolling()
        }
        vobleHub.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        vobleHub.onSessionCreated = { [weak self] bundle in self?.configureVoBLESession(bundle) }
        configureVoBLESession(vobleHub.placeholder)
        if ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsBluetooth {
            vobleHub.restoreInBackgroundIfAuthorized()
        }
        // PushKit may have reported the call to the cold-launch handler before
        // this model existed. Adopt that exact surviving call before an answer
        // captures lifecycle validity; never replay an ended/replaced UUID.
        if let incoming = callKit.currentIncomingPush,
           callKit.matchesCurrentCall(callID: incoming.callID, uuid: incoming.uuid,
                agentID: incoming.agentID, generation: incoming.generation) {
            callKitDidReceiveIncoming(incoming)
            let session = IPhoneCloudCallSession.shared
            if callLifecycleSnapshot.callUUID == incoming.uuid,
               session.call?.uuid == incoming.uuid, session.lifecycleState.representsCall {
                _ = applyCallLifecycle(.init(callID: incoming.callID, callUUID: incoming.uuid,
                    generation: incoming.generation, state: session.lifecycleState, source: .relay,
                    timestamp: Date(), traceID: nil, failure: nil))
            } else if callLifecycleSnapshot.callUUID == incoming.uuid, callKit.currentCallIsAnswered {
                applyCurrentCallIntent(.active, source: .callKit)
                updateRemoteCallState("active")
            }
        }
    }

    private func configureVoBLESession(_ bundle: VoBLEDeviceSession) {
        let central = bundle.central
        central.onSMS = { [weak self, weak central] sms in
            guard let self, let central else { return }
            self.receiveVoBLESMS(sms, agentID: central.authenticatedIdentity)
        }
        central.$state
            .dropFirst()
            .removeDuplicates()
            // @Published emits before mutation; consume on the next main turn.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak central] state in
                guard let self, let central, central.state == state else { return }
                self.objectWillChange.send()
                if state == .ready {
                    Task {
                        self.rememberVerifiedDevices()
                        await central.refreshDeviceInformation()
                    }
                }
                if ConnectionModePreference.selected() == .bluetooth {
                    self.updateBluetoothConnectionPresentation()
                } else if self.hasStarted, self.deviceCalls.active == nil { self.restartPolling() }
                self.refreshVoBLELiveActivity()
            }
            .store(in: &cancellables)
        central.$deviceInformation
            .dropFirst()
            .sink { [weak self] information in
                guard let self else { return }
                if let information {
                    PairedAndroidDeviceStore.remember(.init(id: information.agentID,
                        deviceName: information.deviceName, agentKind: information.agentKind))
                    self.pairedDeviceRecords = PairedAndroidDeviceStore.records()
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        bundle.audio.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        configureVoBLECallCoordinator(bundle)
    }

    private func configureVoBLECallCoordinator(_ bundle: VoBLEDeviceSession) {
        let calls = bundle.calls
        let central = bundle.central
        calls.onOutgoingIntent = { [weak self, weak central] identity in
            self?.vobleHub.setCallActive(true)
            self?.applyVoBLEState(identity: identity, state: .connecting, agentID: central?.authenticatedIdentity)
        }
        calls.mediaPermission = { [weak self, weak central] identity in
            guard let self, let agentID = central?.authenticatedIdentity,
                  let key = self.deviceCalls.key(agentID: agentID, callID: identity.callID) else { return false }
            return self.deviceCalls.active == key && self.deviceCallContext.media.owner == key
                && self.lockedCallTransport?.transport == .bluetooth
        }
        calls.audioSessionContext = { [weak self] in
            guard let self else { return (true, false) }
            return (self.callKit.managesCurrentCall, self.callKit.audioSessionIsActive)
        }
        calls.onIncoming = { [weak self, weak central] call in
            guard let self, let agentID = central?.authenticatedIdentity else { return }
            self.vobleHub.setCallActive(true)
            _ = self.receiveOwnedCallEvent(DeviceCallEvent(agentID: agentID, callID: call.callID,
                state: .ringing, transport: .bluetooth, transportEpoch: central?.transportEpoch ?? 0,
                backendGeneration: call.generation, number: call.number))
        }
        calls.onState = { [weak self, weak central] identity, state in
            self?.vobleHub.setCallActive(!(state.isTerminal || state == .ending))
            // A session that is still re-authenticating has no ready backend.
            // Only terminal/ending handoffs may use recoverableIdentity; a
            // ringing/active event there would create a sticky presentation
            // with no route to answer it.
            let authenticated = central?.authenticatedIdentity
            let recoverable = (state == .ending || state.isTerminal) ? central?.recoverableIdentity : nil
            self?.applyVoBLEState(identity: identity, state: state, agentID: authenticated ?? recoverable)
        }
        calls.onEnded = { [weak self, weak central] identity in
            self?.vobleHub.setCallActive(false)
            self?.finishVoBLECall(identity, agentID: central?.authenticatedIdentity ?? central?.recoverableIdentity)
        }
        calls.onError = { [weak self] message in
            self?.vobleHub.setCallActive(false)
            self?.errorMessage = message
        }
    }

    private func applyVoBLEState(identity: VoBLECallIdentity, state: CallLifecycleState, agentID: String?) {
        guard let agentID else { return }
        let owned = deviceCallRouter.route(for: identity.uuid)
        let provisional = owned.flatMap { route -> String? in
            guard route.key.agentID == agentID, let previous = deviceCalls.latestEvent(for: route.key),
                  previous.callID != identity.callID, previous.state == .connecting else { return nil }
            return previous.callID
        }
        let epoch = vobleHub.retainedBundle(for: agentID)?.central.transportEpoch ?? 0
        _ = receiveOwnedCallEvent(.init(agentID: agentID, callID: identity.callID,
            replacesCallID: provisional, state: state, transport: .bluetooth, transportEpoch: epoch,
            backendGeneration: identity.generation, number: identity.number, direction: identity.direction))
        let key = deviceCalls.key(agentID: agentID, callID: identity.callID)
        let adopted = key != nil && deviceCalls.latestEvent(for: key!)?.state == state
        Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "voble",
            phase: "call_state", title: "蓝牙通话身份衔接",
            fields: ["state": state.rawValue, "generation": String(identity.generation),
                     "epoch": String(epoch), "alias": String(provisional != nil),
                     "adopted": String(adopted), "provisional": String(identity.isProvisional)],
            isFailure: !adopted) }
    }

    private func applyLegacyVoBLEState(identity: VoBLECallIdentity, state: CallLifecycleState, agentID: String?) {
        guard let agentID else { return }
        let provisionalID = !identity.isProvisional
            && callLifecycleSnapshot.callID != identity.callID
            && callLifecycleSnapshot.callUUID == identity.uuid
            ? callLifecycleSnapshot.callID : nil
        let event = DeviceCallEvent(agentID: agentID, callID: identity.callID,
            replacesCallID: provisionalID, state: state, transport: .bluetooth,
            transportEpoch: 1, backendGeneration: identity.generation,
            number: identity.number, direction: identity.direction)
        _ = receiveDeviceCallEvent(event, presentation: CallLifecycleEvent(
            callID: identity.callID, callUUID: identity.uuid,
            generation: identity.generation, state: state, source: .agent,
            timestamp: Date(), traceID: "voble-\(identity.generation)-\(state.rawValue)",
            failure: nil))
        guard let key = deviceCalls.key(agentID: agentID, callID: identity.callID),
              deviceCallCanPresent(key), callLifecycleSnapshot.callUUID == identity.uuid else { return }
        if let lockedCallTransport, lockedCallTransport.transport != .bluetooth { return }
        if identity.isProvisional, identity.direction == "outgoing" { _ = activateDeviceCall(key) }
        currentCallTransport = .bluetooth
        lockedCallTransport = LockedCallTransport(
            transport: .bluetooth, generation: identity.generation)
        let record = CallRecord(
            id: identity.callID, index: 0, direction: identity.direction,
            state: state.callRecordState, number: identity.number,
            startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false)
        remoteCall = record
        // CallKit must only bind Android's authoritative Telecom ID. Binding
        // iOS's temporary dial ID makes the subsequent adoption end the call.
        if !identity.isProvisional {
            callKit.synchronize(
                call: record, previous: nil,
                callerName: identity.number.map { contacts.displayName(for: $0) })
            if state == .active { callKit.reportCurrentOutgoingConnected() }
        }
        WatchCallCoordinator.shared.publish(
            call: record, previous: nil,
            callerName: identity.number.map { contacts.displayName(for: $0) },
            transport: "bluetooth")
        refreshVoBLELiveActivity()
    }

    private func finishVoBLECall(_ identity: VoBLECallIdentity, agentID: String?) {
        guard let agentID else { return }
        _ = receiveOwnedCallEvent(.init(agentID: agentID, callID: identity.callID, state: .ended,
            transport: .bluetooth, transportEpoch: vobleHub.retainedBundle(for: agentID)?.central.transportEpoch ?? 0,
            backendGeneration: identity.generation, number: identity.number, direction: identity.direction))
    }

    private func finishLegacyVoBLECall(_ identity: VoBLECallIdentity, agentID: String?) {
        guard let agentID,
              let key = deviceCalls.key(agentID: agentID, callID: identity.callID) else { return }
        let mayFinishPresentation = deviceCallCanPresent(key)
        deviceCalls.finish(key)
        guard mayFinishPresentation else { return }
        guard callLifecycleSnapshot.callUUID == identity.uuid,
              callLifecycleSnapshot.generation == identity.generation else { return }
        let provisionalID = callLifecycleSnapshot.callID != identity.callID
            ? callLifecycleSnapshot.callID : nil
        let previous = remoteCall ?? CallRecord(
            id: identity.callID, index: 0, direction: identity.direction,
            state: callLifecycleSnapshot.state.callRecordState, number: identity.number,
            startedAt: Date(), updatedAt: Date(), endedAt: Date(), missed: false)
        let ended = CallRecord(
            id: identity.callID, index: previous.index, direction: previous.direction,
            state: "ended", number: previous.number, startedAt: previous.startedAt,
            updatedAt: Date(), endedAt: Date(), missed: previous.missed)
        guard applyCallLifecycle(CallLifecycleEvent(
            callID: identity.callID, callUUID: identity.uuid,
            generation: identity.generation, state: .ended, source: .agent,
            timestamp: Date(), traceID: "voble-\(identity.generation)-ended", failure: nil),
            replacingProvisionalCallID: provisionalID) else { return }
        deviceCalls.finish(key)
        if presentedDeviceCall == key { presentedDeviceCall = nil }
        remoteCall = nil
        callKit.synchronize(call: nil, previous: ended, callerName: nil)
        WatchCallCoordinator.shared.publish(
            call: nil, previous: ended, callerName: nil, transport: "bluetooth")
        refreshVoBLELiveActivity()
        clearLockedTransport()
        backgroundStandby.resumeAfterCall()
    }

    private func refreshVoBLELiveActivity() {
        Task { [weak self] in
            guard let self else { return }
            // Resolve NOW, not when this task was queued. A captured active
            // record must never overwrite a later hangup or replacement call.
            let call = self.lifecycleRecord(from: self.remoteCall)
                ?? self.lifecycleRecord(from: self.activeCall)
            let bluetoothReady = self.voble.state == .ready
            // A BLE state notification may arrive while another transport owns the
            // call. Never relabel an already locked VoWLAN/cloud call as VoBLE.
            let activeTransport: AirSIMCallActivityAttributes.ContentState.Transport? = {
                guard let callTransport = self.lockedCallTransport?.transport
                    ?? self.currentCallTransport else { return nil }
                switch callTransport {
                case .vowlan: return .vowlan
                case .bluetooth: return .bluetooth
                case .cloud: return .cloud
                }
            }()
            let transport = call == nil
                ? self.liveActivityTransport
                : (activeTransport ?? self.liveActivityTransport)
            let localRouteReady: Bool
            switch transport {
            case .bluetooth:
                // 保留正在进行中的三秒 VoBLE 重连窗口；超时后 coordinator 会结束通话。
                localRouteReady = bluetoothReady || call != nil
            case .vowlan:
                localRouteReady = self.vowlan.availability.isOnlineForDisplay
            case .cloud, nil:
                localRouteReady = false
            }
            let cloudReady = transport == .cloud && CloudModePreference.isEnabled()
                && (self.cloudAgentStatus?.cloudOnline == true || call != nil)
            await self.liveActivity.update(
                call: call,
                callerName: call?.number.map { self.contacts.displayName(for: $0) },
                moduleOnline: localRouteReady,
                cloudOnline: cloudReady,
                transport: transport,
                radio: nil,
                agent: self.liveActivityAgentSnapshot,
                appIsActive: self.appIsActive)
        }
    }

    func start(sceneIsActive: Bool) {
        guard !hasStarted else { return }
        hasStarted = true
        appIsActive = sceneIsActive
        requestMicrophoneOnForegroundIfNeeded()
        startCloudStatusQueryIfNeeded()
        let storedValue = UserDefaults.standard.object(forKey: backgroundStandbyKey)
            .map { _ in UserDefaults.standard.bool(forKey: backgroundStandbyKey) }
        let storedLowPowerValue = UserDefaults.standard.object(forKey: lowPowerModeKey) as? Bool
        lowPowerModeEnabled = storedLowPowerValue ?? true
        liveActivity.setEnabled(LiveActivityVisibilityPreference.isEnabled())
        backgroundStandby.setEnabled(storedValue ?? false)
        // 先加载手机副本，再启动轮询，避免模块暂时离线时界面显示为空。
        restoreLocalHistory()
        Task { await contacts.loadIfAuthorized() }
        if IncomingCallPresentationRequest.isPending() { presentCurrentCallInApp() }
        presentManagedCallAfterForegroundTransition()
        restartPolling()
    }

    /// 每次从锁屏或后台回来都舍弃旧连接，避免休眠前的超时结果覆盖新状态。
    func didBecomeActive() {
        appIsActive = true
        vobleHub.setApplicationIsBackground(false)
        if voble.state == .ready { Task { await voble.refreshDeviceInformation() } }
        let discoveryWasAlreadyStarted = initialPermissionCoordinator.didStartDiscovery
        let callWasActive = callLifecycleSnapshot.state.representsCall
            || IPhoneCloudCallSession.shared.hasActiveCall
            || vobleCalls.currentIdentity != nil
        let selectedMode = ConnectionModePreference.selected()
        requestMicrophoneOnForegroundIfNeeded()
        startCloudStatusQueryIfNeeded()
        if discoveryWasAlreadyStarted {
            if AppForegroundRecoveryPolicy.shouldRestartVoWLAN(
                mode: selectedMode, callActive: callWasActive
            ) {
                Task { await vowlan.refreshAfterForeground() }
            }
            // VoBLE is the persistent standby/control link; keep it alive even
            // when the selected mode is VoWLAN or cloud.
            vobleHub.start()
        }
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "lifecycle", phase: "foreground",
                title: "App 回到前台",
                fields: [
                    "call_active": callWasActive ? "true" : "false",
                    "mode": selectedMode.rawValue,
                    "vowlan": voWLANAvailabilityLabel,
                    "discovery_started": discoveryWasAlreadyStarted ? "true" : "false",
                ]
            )
        }
        eventStreamSupported = nil
        eventRevision = AgentEventCursor.initial
        localDevices.refreshAfterForeground()
        consecutivePollFailures = 0
        isReconnecting = false
        backgroundStandby.setApplicationIsBackground(false)
        guard hasStarted else {
            start(sceneIsActive: true)
            return
        }
        // App 可能在首次解锁前被 PushKit/后台任务唤醒，此时受保护文件会暂时读成空。
        // 回到前台重新做并集合并，不能让早期空读取覆盖手机里的持久化记录。
        restoreLocalHistory()
        Task { await contacts.loadIfAuthorized() }
        if IncomingCallPresentationRequest.isPending() { presentCurrentCallInApp() }
        presentManagedCallAfterForegroundTransition()
        restartPolling()
    }

    func willResignActive() {
        backgroundStandby.prepareForBackground()
    }

    func didEnterBackground() {
        appIsActive = false
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "lifecycle", phase: "background",
                title: "App 进入后台",
                fields: ["vowlan": voWLANAvailabilityLabel,
                         "cloud": CloudModePreference.isEnabled() ? "enabled" : "disabled"]
            )
        }
        vobleHub.setApplicationIsBackground(true)
        cloudStatusRefreshTask?.cancel()
        cloudStatusRefreshTask = nil
        cloudStatusRefreshGeneration &+= 1
        lastCloudStatusRefresh = .distantPast
        backgroundStandby.setApplicationIsBackground(true)
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        restartPolling()
    }

    private var voWLANAvailabilityLabel: String {
        switch vowlan.availability {
        case .unpaired: return "unpaired"
        case .discovering: return "discovering"
        case .discovered: return "discovered"
        case .verified: return "verified"
        case .unavailable: return "unavailable"
        }
    }

    private func requestMicrophoneOnForegroundIfNeeded() {
        guard initialPermissionTask == nil,
              appIsActive else { return }
        initialPermissionTask = Task { [weak self] in
            guard let self else { return }
            await self.initialPermissionCoordinator.requestIfNeeded(
                isForeground: { self.appIsActive },
                microphoneIsUndetermined: { self.audio.microphonePermissionIsUndetermined },
                requestMicrophone: { _ = await self.audio.requestMicrophonePermission() },
                startDiscovery: {
                    let policy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
                    if policy.startsVoWLAN { self.vowlan.startBrowsing() }
                    // Pairing/standby keeps BLE independent of the selected mode.
                    self.vobleHub.start()
                },
                requestNotifications: { self.incomingNotifier.requestAuthorization() }
            )
            self.initialPermissionTask = nil
        }
    }

    func setBackgroundStandbyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: backgroundStandbyKey)
        backgroundStandby.setEnabled(UserDefaults.standard.bool(forKey: backgroundStandbyKey))
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: lowPowerModeKey)
        lowPowerModeEnabled = enabled
        // 立即重建轮询任务，让用户切换后无需等待旧睡眠周期结束。
        if hasStarted { restartPolling() }
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: LiveActivityVisibilityPreference.key)
        liveActivity.setEnabled(enabled)
        VoIPPushController.shared.setLiveActivityEnabled(enabled)
        if enabled {
            cloudStatusRefreshTask?.cancel()
            cloudStatusRefreshTask = nil
            cloudStatusRefreshGeneration &+= 1
            lastCloudStatusRefresh = .distantPast
            startCloudStatusQueryIfNeeded()
            Task { [weak self] in
                guard let self else { return }
                await self.cloudStatusRefreshTask?.value
                guard LiveActivityVisibilityPreference.isEnabled() else { return }
                let call = self.lifecycleRecord(from: self.activeCall ?? self.remoteCall)
                await self.liveActivity.update(
                    call: call,
                    callerName: call.map { self.contacts.displayName(for: $0.number) },
                    moduleOnline: self.isOnline,
                    cloudOnline: CloudModePreference.isEnabled()
                        && self.cloudAgentStatus?.cloudOnline == true,
                    transport: self.liveActivityTransport,
                    radio: self.modemStatus,
                    agent: self.liveActivityAgentSnapshot,
                    appIsActive: self.appIsActive
                )
            }
        }
    }

    func setLocalModeEnabled(_ enabled: Bool) {
        setCloudSignalingEnabled(!enabled)
    }

    func setCloudSignalingEnabled(_ enabled: Bool) {
        CloudSignalingPreference.set(enabled)
        VoIPPushController.shared.setSignalingEnabled(enabled)
        if enabled {
            UIApplication.shared.registerForRemoteNotifications()
            Task { [weak self] in
                guard let self else { return }
                if let (api, _) = await self.readyVoWLANRoute() {
                    await VoIPPushController.shared.syncRegistration(with: api)
                } else {
                    await VoIPPushController.shared.syncRegistration()
                }
            }
        }
        Task { [weak self] in
            guard let self, let (api, _) = await self.readyVoWLANRoute() else { return }
            try? await api.setPushCloudEnabled(enabled)
        }
    }

    private func releaseInactiveLocalTransports() {
        guard !deviceCallRouter.hasPendingTermination else { return }
        // Do not tear down VoBLE here: the BLE link is kept across mode changes
        // and reconnects independently of the active VoWLAN/cloud route.
        let policy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
        if !policy.startsVoWLAN, !(deviceCalls.active != nil && currentCallTransport == .vowlan) {
            localDevices.stop()
        }
    }

    func setConnectionMode(_ mode: AirSIMConnectionMode) {
        ConnectionModePreference.set(mode)
        // Explicit cloud/automatic media needs Relay signaling; VoWLAN keeps
        // whatever notification choice the user made.
        if mode == .cloud || mode == .automatic {
            CloudSignalingPreference.set(true)
        }
        eventStreamSupported = nil
        let policy = ConnectionModeRuntimePolicy(mode: mode)
        if policy.startsVoWLAN { localDevices.start() }
        else if !deviceCallRouter.hasPendingTermination {
            localDevices.stop(except: currentCallTransport == .vowlan ? deviceCalls.active?.agentID : nil)
        }
        _ = vobleMode.activate(mode)
        cloudStatusRefreshTask?.cancel()
        cloudStatusRefreshTask = nil
        cloudStatusRefreshGeneration &+= 1
        lastCloudStatusRefresh = .distantPast
        if !CloudSignalingPreference.isEnabled() {
            cloudAgentStatus = nil
            cloudAgentDirectory = nil
            lastCloudStatusReceivedAt = .distantPast
        }
        callKit.setEnabled(policy.usesCallKit || deviceCalls.active != nil)
        // Media mode never turns APNs/PushKit off. Signaling is independent.
        VoIPPushController.shared.setSignalingEnabled(CloudSignalingPreference.isEnabled())
        WatchCallCoordinator.shared.refreshMediaPolicy()
        if CloudSignalingPreference.isEnabled() {
            Task { [weak self] in
                guard let self, let (api, _) = await self.readyVoWLANRoute() else { return }
                try? await api.setPushCloudEnabled(true)
            }
        }
        if policy.startsVoWLAN {
            vowlan.restartBrowsing()
            Task { await vowlan.probeNow() }
        } else {
            vowlan.stopBrowsing()
        }
        if policy.startsCloud { startCloudStatusQueryIfNeeded() }
        objectWillChange.send()
        refreshVoBLELiveActivity()
        if hasStarted { restartPolling() }
    }

    private func updateBluetoothConnectionPresentation() {
        let ready = voble.state == .ready
        if isOnline { isOnline = false }
        if isReconnecting != !ready { isReconnecting = !ready }
        let message = ready ? "蓝牙 Agent 已连接" : "正在连接蓝牙 Agent"
        if connectionMessage != message { connectionMessage = message }
        consecutivePollFailures = 0
        eventStreamSupported = nil
    }

    func restartPolling() {
        callUpdateWork.cancel()
        pollingGeneration &+= 1
        let generation = pollingGeneration
        pollingTask?.cancel()
        pollingTask = nil
        guard AppRefreshPolicy.shouldRunAgentPolling(mode: ConnectionModePreference.selected()) else {
            updateBluetoothConnectionPresentation()
            return
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(generation: generation)
                guard let delay = self?.nextPollingDelay else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Agent 在线时与其 1 秒 AT 轮询对齐；离线后退避，避免断开时持续唤醒手机和网络栈。
    private var nextPollingDelay: TimeInterval {
        if !isOnline, boundBluetoothReady { return appIsActive ? 1 : (lowPowerModeEnabled ? 10 : 2) }
        if consecutivePollFailures > 0 {
            let maximumDelay: TimeInterval = appIsActive ? 3 : 30
            return min(maximumDelay, pow(2, Double(consecutivePollFailures - 1)))
        }
        if !appIsActive {
            // 长轮询本身已经等待最多 15 秒；返回后只需短暂让出执行权再继续等待。
            if eventStreamSupported == true { return 0.1 }
            return lowPowerModeEnabled ? 10 : 2
        }
        if eventStreamSupported == true { return 0.1 }
        return 1
    }

    func stop() {
        localDirectoryRefresh?.cancel()
        localDevices.stop()
        callUpdateWork.cancel()
        localAudioStartup.cancel()
        pollingGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        audio.deactivate()
        backgroundStandby.setEnabled(false)
        Task { await liveActivity.stop() }
        if let samsungAPI = verifiedVoWLANAPI() {
            Task { try? await samsungAPI.setAudioHostEnabled(false) }
        }
        vobleHub.stop()
    }

    private func poll(generation: Int) async {
        let selectedMode = ConnectionModePreference.selected()
        let preferredRoute = (callLifecycleSnapshot.state.representsCall ? currentCallTransport : nil) ?? DialRouteSelector.preferred(
            mode: selectedMode,
            vowlanReady: verifiedVoWLANAPI() != nil,
            bluetoothReady: boundBluetoothReady,
            cloudReady: boundCloudReady
        )
        if selectedMode == .bluetooth || preferredRoute == .bluetooth {
            // isOnline 专指 HTTP Agent 链路，不能用 BLE 就绪伪装，否则会复用失效的
            // VoWLAN 缓存并把下一次自动拨号错误地送回旧 IP。
            updateBluetoothConnectionPresentation()
            return
        }
        do {
            let result = try await nextAgentEvent()
            let status = result.call
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            let canonicalSource = result.agentID.flatMap { source in
                localDevices.metadata(for: source)?.canonicalCallIDs == true ? source : nil
            }
            if ownsLocalCallPresentation || canonicalSource != nil {
                // The per-device subscription owns call presentation. Unified
                // polling remains for SMS/metadata, not a second global call path.
                if let source = canonicalSource {
                    if let call = status.active { _ = applyAgentCallRecord(call, agentID: source) }
                    for call in status.history ?? [] where call.endedAt != nil {
                        _ = applyAgentCallRecord(call, forcedState: .ended, agentID: source)
                    }
                }
                // Directory delivers history for every authenticated peer and
                // acknowledges it only on the API that produced the snapshot.
                isOnline = true; isReconnecting = false; consecutivePollFailures = 0
                lastSuccessfulLocalAPI = result.api
                if result.smsChanged {
                    await loadMessagesFromAgent(silently: true, notifyIfBackground: true, reportingAgent: result.api)
                }
                if AppRefreshPolicy.shouldRefreshSupplementalState(appIsActive: appIsActive) {
                    scheduleModuleMetadataRefresh(generation: generation, api: result.api)
                }
                return
            }
            let previousCall = activeCall
            let history = await mergeCallHistory(status.history ?? [], agentID: result.agentID, source: result.api)
            let confirmedEndedCall = previousCall.flatMap { previous in
                status.history?.first { $0.id == previous.id && $0.endedAt != nil }
            }
            let acceptedActiveLifecycle: Bool
            if let active = status.active {
                acceptedActiveLifecycle = applyAgentCallRecord(active, agentID: result.agentID)
            } else if let ended = confirmedEndedCall {
                acceptedActiveLifecycle = false
                _ = applyAgentCallRecord(ended, forcedState: .ended, agentID: result.agentID)
            } else {
                acceptedActiveLifecycle = false
            }
            if let active = status.active {
                observedCallLocalAPI = (callID: active.id, service: result.api)
                // Agent 状态与统一生命周期真正汇合后才能撤掉临时呼出页。
                // 否则上一通 ending 的晚到事件会让用户在几秒后掉回拨号页。
                if acceptedActiveLifecycle || callLifecycleSnapshot.callID == active.id {
                    pendingOutgoingCall = nil
                }
                if activeCall != active { activeCall = active }
            } else if confirmedEndedCall != nil, activeCall != nil {
                activeCall = nil
                observedCallLocalAPI = nil
            }
            if let active = status.active {
                if remoteCall?.id == active.id { remoteCall = nil }
                if callPresentationSurface == nil,
                   !callLifecycleStore.suppressesPresentation(callID: active.id) {
                    callPresentationSurface = appIsActive ? .app : .system
                }
            } else if previousCall != nil,
                      callLifecycleSnapshot.state.isTerminal,
                      !IPhoneCloudCallSession.shared.hasActiveCall {
                callPresentationSurface = nil
                remoteCall = nil
            }
            if callHistory != history { callHistory = history }
            consecutivePollFailures = 0
            if isReconnecting { isReconnecting = false }
            lastSuccessfulLocalAPI = result.api

            if let call = status.active,
               ["dialing", "alerting", "incoming", "waiting"].contains(call.state),
               audioWarmupCallID != call.id {
                audioWarmupCallID = call.id
                // 预热只加载驱动和校准，把最慢的冷启动提前到接通之前。
                Task { [weak self] in
                    guard let self else { return }
                    try? await AgentPollingRouteSelector.select(
                        primary: result.api,
                        lockedLocal: self.currentLocalAPI,
                        transport: self.currentCallTransport
                    ).warmAudioHost()
                }
            } else if status.active == nil, previousCall != nil {
                audioWarmupCallID = nil
            }
            // HTTP 已成功返回就说明 Android Agent 在线。last_poll_error 只是 Agent 内部 AT+CLCC
            // 的最近轮询结果，通话建立期间可能短暂非空，不能据此把整条 VoWLAN 链路判为离线。
            if !isOnline { isOnline = true }
            cloudAgentStatus = nil
            updateLocalConnectionSummary(cellularState: modemStatus?.cellularState)
            let callSyncSnapshot = callLifecycleSnapshot
            let callSyncAttempt = outgoingAttemptID
            // No push registration, cloud query or ActivityKit await may precede
            // connected-state synchronization, ringback stop and local PCM startup.
            await callUpdateWork.process(isCurrent: { [weak self] in
                guard let self else { return false }
                return generation == self.pollingGeneration
                    && self.callLifecycleSnapshot.callID == callSyncSnapshot.callID
                    && self.callLifecycleSnapshot.callUUID == callSyncSnapshot.callUUID
                    && self.callLifecycleSnapshot.generation == callSyncSnapshot.generation
                    && self.callLifecycleSnapshot.state == callSyncSnapshot.state
                    && self.outgoingAttemptID == callSyncAttempt
            }, synchronizeCall: {
                let lifecycleCall = lifecycleRecord(from: status.active ?? previousCall)
                let systemCall = status.active.flatMap {
                    callLifecycleStore.suppressesPresentation(callID: $0.id) ? nil : $0
                }
                let callerName = (systemCall ?? lifecycleCall).map { contacts.displayName(for: $0.number) }
                // 必须先请求 CallKit，再决定是否发送本地通知。否则后台来电会同时出现
                // 系统通话界面和一条带接听按钮的通知；CallKit 上报失败时下一轮再自动降级。
                if !WatchCallCoordinator.shared.ownsMedia(callID: systemCall?.id) {
                    callKit.synchronize(
                        // Preserve real Agent state except for identities explicitly
                        // ending/ended locally; a late poll must not create a new CXCall.
                        call: systemCall,
                        previous: confirmedEndedCall ?? previousCall,
                        callerName: callerName
                    )
                }
                WatchCallCoordinator.shared.publish(
                    call: lifecycleCall,
                    previous: confirmedEndedCall ?? previousCall,
                    callerName: callerName ?? previousCall.map { contacts.displayName(for: $0.number) }
                )
                // CallKit 成功后由系统负责锁屏来电界面；仅在 CallKit 不可用或上报失败时发普通通知兜底。
                if !callKit.suppressesInAppIncomingRingtone {
                    incomingNotifier.update(
                        call: lifecycleCall,
                        callerName: callerName,
                        appIsActive: appIsActive
                    )
                }
                if lifecycleCall?.direction == "incoming", callKit.suppressesInAppIncomingRingtone {
                    // CallKit 已负责系统铃声，不能再叠加应用内铃声。
                    audio.stopCallTone()
                } else {
                    audio.updateCallTone(for: lifecycleCall)
                }

            }, updateAudio: {
                // 接通期间持续确认本地音频仍在工作。CallKit 或系统音频服务重置后，
                // 即使模块状态没有发生变化，下一轮也必须能够重建网络 PCM。
                if status.active?.state == "active" {
                    await startCallAudioIfReady()
                } else if status.active == nil, previousCall != nil {
                    // 远端挂断不会经过 App 的挂断按钮；同样开启切换保护，避免媒体路由
                    // 退出时的短暂网络/AT 抖动被误报为整个 Agent 离线。
                    beginCallTransitionProtection()
                    // 云端回退通话可能在本地模块状态消失后仍然有效；不能让本地轮询
                    // 清除共享 AVAudioSession 的扬声器覆盖或打断公网 PCM。
                    if currentCallTransport != .cloud,
                       !IPhoneCloudCallSession.shared.hasActiveCall {
                        audio.deactivate()
                    }
                    guard !Task.isCancelled, generation == pollingGeneration else { return }
                    backgroundStandby.resumeAfterCall()
                    isMuted = false
                    isRecording = false
                }
            }, updateSupplemental: { [weak self] canApply in
                guard let self, canApply() else { return }
                // Keep existing registration fingerprint/backoff and one-shot cloud
                // query policies; only remove them from the call's critical path.
                await VoIPPushController.shared.syncRegistration(with: result.api)
                guard canApply() else { return }
                if AppRefreshPolicy.shouldRefreshSupplementalState(appIsActive: self.appIsActive) {
                    self.scheduleModuleMetadataRefresh(generation: generation, api: result.api)
                }
                let call = self.lifecycleRecord(from: self.activeCall ?? self.remoteCall)
                await self.awaitCloudStatusForLiveActivity(call: call)
                guard canApply() else { return }
                let current = self.lifecycleRecord(from: self.activeCall ?? self.remoteCall)
                await self.liveActivity.update(
                    call: current,
                    callerName: current.map { self.contacts.displayName(for: $0.number) },
                    moduleOnline: true,
                    transport: self.liveActivityTransport,
                    radio: self.modemStatus,
                    agent: self.liveActivityAgentSnapshot,
                    appIsActive: self.appIsActive
                )
            })
            guard !Task.isCancelled, generation == pollingGeneration,
                  callLifecycleSnapshot == callSyncSnapshot, outgoingAttemptID == callSyncAttempt else { return }
            if appIsActive, status.active?.state == "active",
               Date() >= nextAudioDiagnosticRefresh,
               let audioConfig = try? await AgentPollingRouteSelector.select(
                   primary: result.api,
                   lockedLocal: currentLocalAPI,
                   transport: currentCallTransport
               ).audioHostConfig() {
                // 诊断统计无需跟随每次通话轮询，降低额外 TCP 建连和 JSON 解码频率。
                nextAudioDiagnosticRefresh = Date().addingTimeInterval(3)
                audio.updateModuleDiagnostics(audioConfig)
            }
            if result.smsChanged {
                await loadMessagesFromAgent(
                    silently: true, notifyIfBackground: true, reportingAgent: result.api
                )
            }
        } catch {
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            if deviceCalls.active != nil { return }
#if DEBUG
            print("[AirSIM Poll] module status failed: \(error.localizedDescription)")
#endif
            consecutivePollFailures += 1
            isReconnecting = true
            let failedRouteName: String = {
                guard let route = lastSuccessfulLocalAPI?.route else { return "本地控制链路" }
                if case .vowlan = route { return "VoWLAN" }
                return "模块本地链路"
            }()
            connectionMessage = "正在重新连接\(failedRouteName)：\(error.localizedDescription)"

            // 一次长轮询中断不能代表 VoWLAN 已离线。通话动作后的 8 秒保护期内
            // 保留最后一次在线状态；其后也必须连续失败三次并让独立 health 请求失败。
            guard ModuleConnectivityPolicy.shouldConfirmOffline(
                consecutiveFailures: consecutivePollFailures,
                now: Date(),
                protectedUntil: callTransitionProtectedUntil
            ) else { return }

            // 用最后实际成功的本地路线复核健康状态。VoWLAN 的长轮询偶发断开时，
            // 不能再转去探测非当前地址并据此把三星 Agent 判为离线。
            let mayPollLocal = AgentPollingRouteSelector.shouldPollLocal(mode: selectedMode,
                activeTransport: callLifecycleSnapshot.state.representsCall ? currentCallTransport : nil)
            let healthAPI = mayPollLocal ? (lastSuccessfulLocalAPI ?? verifiedVoWLANAPI()) : nil
            let health = try? await healthAPI?.health()
            guard ModuleConnectivityPolicy.shouldMarkOffline(
                consecutiveFailures: consecutivePollFailures,
                healthRequestSucceeded: health != nil,
                now: Date(),
                protectedUntil: callTransitionProtectedUntil
            ) else {
                guard !Task.isCancelled, generation == pollingGeneration else { return }
                consecutivePollFailures = 0
                isReconnecting = health?.ok == false
                if !isOnline { isOnline = true }
                cloudAgentStatus = nil
                updateLocalConnectionSummary(cellularState: health?.cellularState)
                if health?.ok == false {
                    connectionMessage = health?.cellularRecovery?.isEmpty == false
                        ? "模块已连接，AT 通道恢复中 · \(health!.cellularRecovery!)"
                        : "模块已连接，AT 通道正在自动恢复"
                }
                return
            }

            guard !Task.isCancelled, generation == pollingGeneration else { return }
            if IPhoneCloudCallSession.shared.hasActiveCall || IPhoneCloudCallSession.shared.isRecovering {
                // 已建立的公网媒体会话本身就是独立的云端在线证据。接听时本地网络
                // 路由短暂抖动不能把整台模块标成离线，也不能结束灵动岛状态。
                consecutivePollFailures = 0
                if isOnline { isOnline = false }
                isReconnecting = true
                connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: true,
                    cellularState: cloudAgentStatus?.cellularState ?? modemStatus?.cellularState
                )
                connectionMessage = IPhoneCloudCallSession.shared.isRecovering
                    ? "云端通话在线，公网 PCM 正在重新连接"
                    : "云端通话在线，本地网络正在重新连接"
                var lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await awaitCloudStatusForLiveActivity(call: lifecycleCall)
                lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
                return
            }
            if isOnline { isOnline = false }
            lastSuccessfulLocalAPI = nil
            audio.stopCallTone()
            await awaitCloudStatusForLiveActivity(call: nil)
            let cloudStatus = cloudStatusForPresentation
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            cloudAgentStatus = cloudStatus
            connectionSummary = ModuleConnectionPolicy.summary(
                localControlReachable: false,
                cloudHeartbeatFresh: cloudStatus?.cloudOnline == true,
                cellularState: cloudStatus?.cellularState
            )
            if cloudStatus?.cloudOnline == true {
                isReconnecting = true
                if let version = cloudStatus?.agentVersion, !version.isEmpty { agentVersion = version }
                connectionMessage = cloudConnectionMessage(for: cloudStatus!)
                // VoWLAN 本地控制不可达不等于 Agent 离线。Relay 心跳新鲜时保留灵动岛待机，
                // 来电仍可由 PushKit 唤醒并走公网 PCM。
                let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
            } else {
                isReconnecting = false
                connectionMessage = "模块本地与云端均不可达：\(error.localizedDescription)"
                await liveActivity.markOffline(
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
            }
        }

    }

    private struct AgentPollResult {
        let call: CallStatus
        let smsChanged: Bool
        let api: AirSIMAPI
        let agentID: String?
    }

    private func nextAgentEvent() async throws -> AgentPollResult {
        guard AgentPollingRouteSelector.shouldPollLocal(mode: ConnectionModePreference.selected(),
            activeTransport: callLifecycleSnapshot.state.representsCall ? currentCallTransport : nil) else {
            throw CallKitBridgeError.noReachableTransport
        }
        if verifiedVoWLANAPI() == nil {
            await vowlan.recoverIfNeeded()
        }
        guard let samsungAPI = verifiedVoWLANAPI() else {
            throw CallKitBridgeError.noReachableTransport
        }
        let pollingAPI = AgentPollingRouteSelector.select(
            primary: samsungAPI,
            lockedLocal: currentLocalAPI,
            transport: currentCallTransport
        )
        let sourceAgentID: String?
        if case let .vowlan(endpoint, _) = pollingAPI.route {
            sourceAgentID = localDevices.agentIDs.first { localDevices.routes(for: $0)?.vowlan == endpoint }
                ?? vowlan.discoveredAgents.first { $0.endpoint == endpoint }?.id
        } else { sourceAgentID = nil }
        if eventStreamSupported != false {
            do {
                let event = try await pollingAPI.waitForAgentEvent(
                    after: eventRevision,
                    timeout: AgentEventPollingPolicy.timeout(hasActiveCall: callLifecycleSnapshot.state.representsCall)
                )
                eventStreamSupported = true
                if let slots = event.simSlots, let sourceAgentID, !slots.isEmpty {
                    simSlotOverrides[sourceAgentID] = slots
                    objectWillChange.send()
                }
                eventRevision = AgentEventCursor.advanced(from: eventRevision, to: event.revision)
                let shouldFetchSMS = AgentEventPollingPolicy.shouldFetchSMS(
                    pending: event.smsPending,
                    eventRevision: event.smsRevision,
                    observedSMSRevision: smsRevision
                )
                smsRevision = event.smsRevision
                return AgentPollResult(
                    call: event.call,
                    smsChanged: shouldFetchSMS,
                    api: pollingAPI,
                    agentID: sourceAgentID
                )
            } catch APIError.http(404, _) {
                // 0.3.18 等旧 Agent 没有统一事件接口；保留兼容轮询直到模块升级。
                eventStreamSupported = false
            }
        }
        let legacy = try await LegacyAgentPoller.next(pollingAPI)
        return AgentPollResult(call: legacy.call, smsChanged: legacy.smsChanged, api: pollingAPI,
            agentID: sourceAgentID)
    }

    private func verifiedVoWLANAPI() -> AirSIMAPI? {
        if let directoryAPI = selectedDirectoryAPI { return directoryAPI }
        guard vowlan.availability.isOnlineForDisplay,
              let endpoint = vowlan.availability.endpoint,
              permitsVoWLANEndpoint(endpoint),
              let credential = credentialForVoWLANEndpoint(endpoint) else { return nil }
        return AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
    }

    private var selectedDirectoryAPI: AirSIMAPI? {
        if let bound = boundAgentID { return localDevices.api(for: bound) }
        let ready = localDevices.agentIDs.filter { localDevices.api(for: $0) != nil && PairedAndroidDeviceStore.permits($0) }
        // Never turn discovery order into an implicit choice between phones.
        guard ready.count == 1, let id = ready.first else { return nil }
        return localDevices.api(for: id)
    }

    private func credentialForVoWLANEndpoint(_ endpoint: VoWLANEndpoint) -> VoWLANCredential? {
        if let id = vowlan.discoveredAgents.first(where: { $0.endpoint == endpoint })?.id,
           let credential = VoWLANCredentialStore.load(agentID: id) { return credential }
        return VoWLANCredentialStore.load()
    }

    private var reachableLocalAPI: AirSIMAPI? {
        if let currentLocalAPI, AirSIMRoutePolicy.permits(currentLocalAPI.route) {
            return currentLocalAPI
        }
        guard isOnline, !isReconnecting else { return nil }
        guard let lastSuccessfulLocalAPI,
              AirSIMRoutePolicy.permits(lastSuccessfulLocalAPI.route) else { return nil }
        return lastSuccessfulLocalAPI
    }

    private var localCallControlAPI: AirSIMAPI? {
        LocalCallControlTarget.select(
            locked: currentLocalAPI,
            observed: observedCallLocalAPI,
            fallback: reachableLocalAPI,
            targetCallID: activeCall?.id
        )
    }

    private var liveActivityTransport: AirSIMCallActivityAttributes.ContentState.Transport? {
        switch currentCallTransport {
        case .vowlan: return .vowlan
        case .bluetooth: return .bluetooth
        case .cloud: return .cloud
        case nil: break
        }
        switch DialRouteSelector.preferred(
            mode: ConnectionModePreference.selected(),
            vowlanReady: verifiedVoWLANAPI() != nil,
            bluetoothReady: boundBluetoothReady,
            cloudReady: boundCloudReady
        ) {
        case .vowlan: return .vowlan
        case .bluetooth: return .bluetooth
        case .cloud: return .cloud
        case nil: return nil
        }
    }

    private var liveActivityAgentSnapshot: LiveActivityAgentSnapshot? {
        let agents = LiveActivityAgentOrder.ordered(pairedAndroidAgents)
        guard !agents.isEmpty else { return nil }
        let current = deviceCalls.active.flatMap { owner in
            agents.first { $0.id == owner.agentID }
        } ?? agents.first(where: \.isCurrent)
        return LiveActivityAgentSnapshot(
            agent: current,
            pairedAgentCount: agents.count,
            agents: agents,
            currentID: current?.id,
            page: liveActivityAgentPage
        )
    }

    var liveActivityOrderedAgents: [AndroidAgentPresentation] {
        LiveActivityAgentOrder.ordered(pairedAndroidAgents)
    }

    func toggleLiveActivityAgentPin(_ agentID: String) {
        LiveActivityAgentOrder.togglePin(agentID)
        liveActivityAgentPage = 0
        objectWillChange.send()
        Task { await refreshLiveActivityIdle() }
    }

    func moveLiveActivityAgent(_ agentID: String, by delta: Int) {
        LiveActivityAgentOrder.move(agentID, by: delta,
            agents: pairedAndroidAgents)
        liveActivityAgentPage = 0
        objectWillChange.send()
        Task { await refreshLiveActivityIdle() }
    }

    private var liveActivityPageCount: Int {
        LiveActivityAgentPaging.pageCount(for: liveActivityOrderedAgents.count)
    }

    private func advanceLiveActivityAgentPage() {
        liveActivityAgentPage = (LiveActivityAgentPaging.pageIndex(
            liveActivityAgentPage, for: liveActivityOrderedAgents.count) + 1) % liveActivityPageCount
    }

    private static func pcmRoute(for route: LocalAgentRoute) -> PCMRoute {
        switch route {
        case let .vowlan(endpoint, credential):
            return .vowlan(endpoint: endpoint, credential: credential)
        }
    }

    /// 蜂窝状态和版本不必跟随每秒通话轮询；独立刷新避免慢 AT 状态接口拖住来电检测。
    private func scheduleModuleMetadataRefresh(generation: Int, api: AirSIMAPI) {
        guard moduleMetadataTask == nil, Date() >= nextModuleMetadataRefresh else { return }
        nextModuleMetadataRefresh = Date().addingTimeInterval(10)
        moduleMetadataTask = Task { [weak self] in
            await self?.refreshModuleMetadata(generation: generation, api: api)
        }
    }

    private func refreshModuleMetadata(generation: Int, api: AirSIMAPI) async {
        defer { moduleMetadataTask = nil }
        async let radioRequest = try? api.modemStatus()
        let radio = await radioRequest
        guard !Task.isCancelled, generation == pollingGeneration, isOnline, appIsActive else { return }
        if let radio, modemStatus != radio { modemStatus = radio }
        updateLocalConnectionSummary(cellularState: radio?.cellularState ?? modemStatus?.cellularState)
        var lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
        await awaitCloudStatusForLiveActivity(call: lifecycleCall)
        lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
        await liveActivity.update(
            call: lifecycleCall,
            callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
            moduleOnline: true,
            transport: liveActivityTransport,
            radio: modemStatus,
            agent: liveActivityAgentSnapshot,
            appIsActive: appIsActive
        )
    }

    private func updateLocalConnectionSummary(cellularState: String?) {
        connectionSummary = ModuleConnectionPolicy.summary(
            localControlReachable: true,
            cloudHeartbeatFresh: false,
            cellularState: cellularState
        )
        switch connectionSummary {
        case .localOnline:
            connectionMessage = nil
        case .localOnlineNoService:
            let detail = modemStatus?.cellularRecovery ?? modemStatus?.registrationText
            connectionMessage = detail?.isEmpty == false
                ? "本地网络已连接 · \(detail!)"
                : "本地网络已连接，蜂窝网络正在恢复"
        case .cloudOnly, .offline:
            break
        }
    }

    private func cloudConnectionMessage(for status: CloudAgentStatus) -> String {
        let local = "本地网络中断，Android 云端在线"
        if status.cellularState == "registered" {
            return local + "，来电将通过云端接听"
        }
        let detail = status.cellularRecovery?.isEmpty == false
            ? status.cellularRecovery!
            : (status.cellularRegistration?.isEmpty == false ? status.cellularRegistration! : "蜂窝网络恢复中")
        return local + " · " + detail
    }

    func dial() async {
        let number = Self.validatedNumber(numberInput)
        guard !number.isEmpty else { return }
        callPresentationSurface = .app
        let now = Date()
        pendingOutgoingCall = CallRecord(
            id: "pending-\(UUID().uuidString.lowercased())",
            index: 0,
            direction: "outgoing",
            state: "dialing",
            number: number,
            startedAt: now,
            updatedAt: now,
            endedAt: nil,
            missed: false
        )
        debugDialLog(LocalModePreference.isEnabled() ? "本地模式直接呼出" : "开始提交 CallKit 系统呼出")
        await perform {
            if LocalModePreference.isEnabled() {
                try await self.callKitStart(number: number)
                return
            }
            do {
                try await self.callKit.startOutgoingCall(number: number)
                debugDialLog("CallKit 呼出事务已提交")
            } catch CallKitBridgeError.unavailable {
                // 受限签名或系统禁用 CallKit 时仍允许用户拨出，但不伪造系统 UUID。
                // 仍复用标准路由选择，确保 VoWLAN 在线时控制与 PCM 都锁定到热点。
                try await self.callKitStart(number: number)
                debugDialLog("CallKit 不可用，已按当前传输路由直拨")
            }
        }
    }

    func answer() async {
        // CallKit may have already fulfilled the system answer while the app was
        // coming to foreground. Do not send a second answer transaction.
        if callKit.currentCallIsAnswered || IPhoneCloudCallSession.shared.answered {
            presentCurrentCallInApp()
            return
        }
        beginCallTransitionProtection()
        audio.stopCallTone()
        callPresentationSurface = .app
        // Do not publish .connecting until the transport accepts the answer.
        // The authoritative store cannot move back to .ringing, so an
        // optimistic transition here would strand the call on failure.
        if callKit.managesCurrentCall {
            await perform {
                do {
                    try await self.callKit.answerCurrentCall(presentInApp: true)
                } catch CallKitBridgeError.staleSystemCall {
                    // 系统界面重建期间仍复用标准路线选择，不能回退到未经鉴权的地址。
                    try await self.callKitAnswer(origin: .app)
                }
            }
        } else {
            await perform { try await self.callKitAnswer(origin: .app) }
        }
    }

    func presentCurrentCallInApp() {
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            let answered = callKit.currentCallIsAnswered || IPhoneCloudCallSession.shared.answered
            remoteCall = Self.remoteCallRecord(from: incoming, state: answered ? "active" : "incoming")
        }
        guard callLifecycleSnapshot.state.representsCall else { return }
        _ = IncomingCallPresentationRequest.consume()
        callPresentationSurface = .app
    }

    /// 正常情况下系统接听会停留在 CallKit。若 iOS、普通 APNs 或用户手势实际把
    /// AirSIM 拉到前台，则必须展示同一通电话，而不是让用户掉回拨号/设置页面。
    private func presentManagedCallAfterForegroundTransition() {
        guard appIsActive,
              CallPresentationPolicy.shouldPresentWhenAppBecomesActive(
                  managesSystemCall: callKit.managesCurrentCall,
                  hasLocalCall: lifecycleRecord(from: activeCall) != nil,
                  hasRemoteCall: lifecycleRecord(from: remoteCall) != nil
              ) else { return }
        let answered = callKit.currentCallIsAnswered || IPhoneCloudCallSession.shared.answered
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            remoteCall = Self.remoteCallRecord(
                from: incoming,
                state: answered ? "active" : "incoming"
            )
        } else if answered {
            updateRemoteCallState("active")
        }
        callPresentationSurface = .app
    }

    func reject() async {
        if let key = presentedDeviceCall, let route = deviceCallRouter.route(for: key) {
            await perform(allowWhileBusy: true) { try await self.callKitEnd(uuid: route.systemUUID) }
            return
        }
        outgoingAttemptID = UUID()
        beginCallTransitionProtection()
        audio.stopCallTone()
        if callKit.managesCurrentCall {
            await perform(allowWhileBusy: true) {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.rejectUsingAvailableTransport()
                }
            }
        } else {
            await perform(allowWhileBusy: true) { try await self.rejectUsingAvailableTransport() }
        }
    }

    func hangup() async {
        if let key = presentedDeviceCall, let route = deviceCallRouter.route(for: key) {
            await perform(allowWhileBusy: true) { try await self.callKitEnd(uuid: route.systemUUID) }
            return
        }
        outgoingAttemptID = UUID()
        beginCallTransitionProtection()
        audio.stopCallTone()
        if callKit.managesCurrentCall {
            await perform(allowWhileBusy: true) {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.hangupUsingAvailableTransport()
                }
            }
        } else {
            await perform(allowWhileBusy: true) { try await self.hangupUsingAvailableTransport() }
        }
    }

    /// Unified entry point for Live Activity buttons. Matches the same call by any
    /// transport, then reuses the normal answer/reject/hangup paths.
    @MainActor
    func performLiveActivityAction(_ action: AirSIMLiveActivityAction, callID: String) async -> Bool {
        if action == .switchAgent {
            // The top-right island control pages through the Agent list; it does
            // not move media/control ownership during a call.
            guard !callLifecycleSnapshot.state.representsCall,
                  !IPhoneCloudCallSession.shared.hasActiveCall else { return true }
            advanceLiveActivityAgentPage()
            await refreshLiveActivityIdle()
            return true
        }
        let matchesLifecycle = callLifecycleSnapshot.callID == callID
        let matchesPush = callKit.currentIncomingPush?.callID == callID
        let matchesCloud = IPhoneCloudCallSession.shared.call?.callID == callID
        let matchesVoBLE = vobleCalls.currentIdentity?.callID == callID
        let matchesDevice = presentedDeviceCall.map { localPresentationID($0) == callID } ?? false
        guard matchesLifecycle || matchesPush || matchesCloud || matchesVoBLE || matchesDevice else {
            // Stale island: keep the persistent standby activity, but stop showing a call.
            await refreshLiveActivityIdle()
            return true
        }
        if callLifecycleSnapshot.state.isTerminal || callLifecycleSnapshot.state == .ending {
            await refreshLiveActivityIdle()
            return true
        }
        switch action {
        case .answer: await answer()
        case .reject: await reject()
        case .hangup: await hangup()
        case .switchAgent: break // handled above
        }
        return true
    }

    /// Cycle to the next known Android Agent, preferring an online phone with a
    /// known number. Binding updates VoBLE/VoWLAN ownership and the standby card.
    private func switchToNextAndroidAgent() {
        let agents = pairedAndroidAgents
        guard agents.count > 1 else { return }
        // Cycle in a stable order. The displayed list puts the current Agent
        // first, so filtering "first online candidate" would alternate between
        // the first two devices and never reach a third one.
        let currentID = agents.first(where: \.isCurrent)?.id ?? boundAgentID
        guard let nextID = AndroidAgentCycle.nextID(in: agents, currentID: currentID) else { return }
        bindAndroidAgent(nextID)
    }

    /// Selects one specific row from the lock-screen/expanded list. The Live
    /// Activity intent only opens the app process; binding still goes through the
    /// same paired-Agent path as the in-app switcher.
    @MainActor
    private func selectAndroidAgent(_ agentID: String) async -> Bool {
        guard !callLifecycleSnapshot.state.representsCall,
              !IPhoneCloudCallSession.shared.hasActiveCall else { return true }
        guard pairedAndroidAgents.contains(where: { $0.id == agentID }) else { return false }
        bindAndroidAgent(agentID)
        await refreshLiveActivityIdle()
        return true
    }

    /// Returns the island to standby without ending the persistent activity.
    @MainActor
    private func refreshLiveActivityIdle() async {
        await liveActivity.update(
            call: nil,
            callerName: nil,
            moduleOnline: isOnline,
            cloudOnline: CloudModePreference.isEnabled() && cloudAgentStatus?.cloudOnline == true,
            transport: liveActivityTransport,
            radio: modemStatus,
            agent: liveActivityAgentSnapshot,
            appIsActive: appIsActive,
            force: true
        )
    }

    func performVoBLELiveActivityAction(
        _ action: AirSIMLiveActivityAction,
        callID: String
    ) async {
        if let key = presentedDeviceCall, deviceCallRouter.route(for: key) != nil {
            guard callID == localPresentationID(key), deviceCalls.latestEvent(for: key)?.state.isTerminal == false else {
                errorMessage = "该本地通话已结束或已被另一通电话替换"; return
            }
            switch action {
            case .answer: await answer()
            case .reject: await reject()
            case .hangup: await hangup()
            case .switchAgent: return
            }
            return
        }
        guard let identity = vobleCalls.currentIdentity,
              identity.callID == callID else {
            errorMessage = "该蓝牙通话已经结束或被另一通电话替换"
            return
        }
        switch action {
        case .answer:
            await answer()
        case .reject:
            await reject()
        case .hangup:
            await hangup()
        case .switchAgent:
            return
        }
    }

    private func rejectUsingAvailableTransport() async throws {
        if ConnectionModePreference.selected() == .cloud {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        if let localAPI = reachableLocalAPI {
            _ = try await localAPI.rejectCall(callID: localAPICallID)
            return
        }
        if let pushedCall = callKit.currentIncomingPush,
           pushedCall.authenticatedMediaURL != nil {
            try await IPhoneCloudCallSession.shared.reject(pushedCall)
            return
        }
        throw CallKitBridgeError.noReachableTransport
    }

    /// Android snapshots use an iOS-only "android-…" id plus the real Telecom id.
    /// CallKit must send the Telecom id; sending the snapshot id causes
    /// "active call id mismatch" and an automatic hangup.
    private var localAPICallID: String? {
        guard let call = activeCall else { return nil }
        return call.androidID?.isEmpty == false ? call.androidID : call.id
    }

    private func hangupUsingAvailableTransport() async throws {
        if ConnectionModePreference.selected() == .cloud {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.hangupCall(callID: localAPICallID)
    }

    private func beginCallTransitionProtection() {
        callTransitionProtectedUntil = Date().addingTimeInterval(
            ModuleConnectivityPolicy.callTransitionGraceInterval
        )
    }
    func sendDTMF(_ digit: String) async {
        await perform {
            if self.callKit.managesCurrentCall {
                do {
                    // App 内键盘与系统通话页共用 CallKit 事务，避免两边的 DTMF 顺序不一致。
                    try await self.callKit.playDTMF(digit)
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.sendDTMFUsingAvailableTransport(digit)
                }
            } else {
                try await self.sendDTMFUsingAvailableTransport(digit)
            }
        }
    }

    private func sendDTMFUsingAvailableTransport(_ digit: String) async throws {
        if let key = deviceCalls.active, deviceCallRouter.route(for: key) != nil {
            try await deviceCallRouter.sendDTMF(digit, for: key); return
        }
        if currentCallTransport == .cloud {
            guard let call = IPhoneCloudCallSession.shared.call else { throw CloudCommandError.unavailable }
            try await VoIPPushController.shared.sendCloudDTMF(digit, call: call)
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.sendDTMF(digit)
    }

    func toggleMute() async {
        let target = !isMuted
        if let key = deviceCalls.active, let route = deviceCallRouter.route(for: key) {
            await callKitSetMuted(target, uuid: route.systemUUID); return
        }
        if callKit.managesCurrentCall {
            do {
                try await callKit.setMuted(target)
                errorMessage = nil
            } catch {
                // CallKit UUID 可能因系统重置而短暂失效；本地 PCM 仍可可靠控制麦克风。
                if case CallKitBridgeError.staleSystemCall = error {
                    isMuted = target
                    audio.setMuted(target)
                    errorMessage = nil
                } else {
                    errorMessage = "系统静音切换失败：\(error.localizedDescription)"
                }
            }
            return
        }
        // 移动端上行语音由本地 PCM 管线产生，必须先本地静音，不能依赖模块 AT 命令成功。
        isMuted = target
        audio.setMuted(target)
        // 部分 Android 固件不实现 AT+CMUT；本地 PCM 已经是移动端的权威静音状态，
        // 后台同步失败不能阻断通话或弹出误导性的“麦克风已静音”错误。
        if let localAPI = reachableLocalAPI {
            Task { try? await localAPI.setAudioMuted(target) }
        }
        errorMessage = nil
    }

    func toggleSpeaker() {
        // 扬声器切换只作用于当前系统音频会话；如果 CallKit 尚未完成激活，
        // AudioSessionController 会保留请求并短暂重试，不弹出 OSStatus -50。
        audio.toggleSpeakerRoute()
        errorMessage = nil
    }

    func toggleRecording() async {
        let target = !isRecording
        do {
            guard let samsungAPI = verifiedVoWLANAPI() else {
                throw CallKitBridgeError.noReachableTransport
            }
            let response = try await samsungAPI.setCallRecording(target)
            isRecording = response.recording
            errorMessage = nil
        } catch {
            debugDialLog("操作失败：\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// 真机联调阶段输出拨号链路，不记录电话号码；Release 构建会完全移除。
    private func debugDialLog(_ message: String) {
#if DEBUG
        print("[AirSIM Dial] \(message)")
#endif
    }

    func sendSMS(to phone: String, content: String) async -> Bool {
        let boundAtStart = boundAgentID
        let target = Self.validatedNumber(phone)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !body.isEmpty, body.count <= 2_000 else { return false }
        var smsRoute = "none"
        var smsSlotLabel = "-"
        do {
            // The outgoing SMS selection is independent of the current call's
            // immutable PCM route and of the legacy default browser's status.
            let localAPI: AirSIMAPI?
            if let boundAtStart {
                localAPI = localDevices.api(for: boundAtStart) ?? verifiedVoWLANAPI()
            } else {
                localAPI = verifiedVoWLANAPI()
            }
            // A signed VoWLAN health check is the reachability authority. The global
            // polling flags can briefly lag during route switches and must not disable SMS.
            let localReachable = localAPI != nil
            let smsSlot = (boundAtStart ?? currentAndroidAgent?.id)
                .flatMap { selectedSIMSlotID(for: $0) }
            let voBLEReady = voble.state == .ready
                && (boundAtStart == nil || voble.authenticatedIdentity == boundAtStart)
            if localReachable {
                smsRoute = "vowlan"
            } else if voBLEReady {
                smsRoute = "voble"
            } else {
                smsRoute = CloudModePreference.isEnabled() ? "cloud" : "none"
            }
            smsSlotLabel = smsSlot ?? "-"
            let startRoute = smsRoute
            let startSlot = smsSlotLabel
            let startChars = body.count
            let startBound = boundAtStart != nil
            Task {
                await AgentVerboseTraceRecorder.shared.recordEvent(
                    source: "ios", category: "sms", phase: "send_start",
                    title: "发送短信",
                    fields: ["route": startRoute, "slot": startSlot,
                             "chars": String(startChars),
                             "bound": String(startBound)]
                )
            }
            let result: SMSSendResult
            if localReachable {
                result = try await localAPI!.sendSMS(to: target, message: body, simAccount: smsSlot)
            } else if voBLEReady {
                let response = try await voble.sendSMS(
                    to: target, message: body, simAccount: smsSlot)
                guard response.success else {
                    throw VoBLECentralError.bluetooth(
                        response.detail.isEmpty ? response.code : response.detail)
                }
                result = SMSSendResult(sent: true, segments: Int(response.detail) ?? 1)
            } else if CloudModePreference.isEnabled() {
                let route: CloudCommandTarget
                if let cached = cloudDialTarget(bound: boundAtStart) {
                    route = cached
                    CloudAgentTargetStore.remember(route.agentID)
                } else {
                    let status = try await VoIPPushController.shared.fetchCloudAgentStatus()
                    route = try cloudTarget(status: status, bound: boundAtStart,
                                            requireOnline: false)
                    CloudAgentTargetStore.remember(route.agentID)
                }
                result = try await VoIPPushController.shared.sendCloudSMS(to: target, message: body, target: route)
            } else {
                throw CloudCommandError.cloudModeDisabled
            }
            let sentPhase = result.sent ? "sent" : "not_sent"
            let sentTitle = result.sent ? "短信已发送" : "短信未发送"
            let sentSegments = result.segments ?? 0
            let sentRoute = smsRoute
            let sentSlot = smsSlotLabel
            let sent = result.sent
            Task {
                await AgentVerboseTraceRecorder.shared.recordEvent(
                    source: "ios", category: "sms",
                    phase: sentPhase, title: sentTitle,
                    fields: ["route": sentRoute, "slot": sentSlot,
                             "segments": String(sentSegments)],
                    isFailure: !sent
                )
            }
            if result.sent {
                saveSentMessage(recipient: target, content: body)
            }
            if localReachable { await refreshMessages(silently: true) }
            return result.sent
        } catch {
            let failureDetail = error.localizedDescription
            let failureType = String(describing: type(of: error))
            let failureRoute = smsRoute
            let failureSlot = smsSlotLabel
            Task {
                await AgentVerboseTraceRecorder.shared.recordEvent(
                    source: "ios", category: "sms", phase: "send_failed",
                    title: "短信发送失败",
                    detail: failureDetail,
                    fields: ["route": failureRoute, "slot": failureSlot,
                             "error_type": failureType],
                    isFailure: true
                )
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func receiveVoBLESMS(_ sms: VoBLEAndroidSMS, agentID: String?) {
        guard !sms.content.isEmpty else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.date(from: sms.timestamp)
            ?? ISO8601DateFormatter().date(from: sms.timestamp)
            ?? Date()
        var message = SMSMessage(
            sender: sms.sender.isEmpty ? "未知号码" : sms.sender,
            content: sms.content,
            code: nil,
            timestamp: timestamp,
            deliveryID: sms.deliveryID.isEmpty ? nil : sms.deliveryID,
            direction: .incoming,
            sourceAgentID: agentID,
            simSlot: sms.simSlot.isEmpty ? nil : sms.simSlot
        )
        if let agentID, !agentID.isEmpty { message.sourceAgentID = agentID }
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        var updated = messages
        updated.append(message)
        updated = normalizedMessages(historyStore.visibleMessages(updated))
        messages = updated
        _ = historyStore.saveMessages(updated)
        SMSVerificationCodeClipboard.handle([message])
        incomingSMSNotifier.notify(
            message: message,
            displayName: contacts.displayName(for: message.sender),
            appIsActive: appIsActive)
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "sms", phase: "received_voble",
                title: "VoBLE 收到短信",
                fields: ["slot": message.simSlot ?? "-"]
            )
        }
    }

    func refreshMessages(silently: Bool = false) async {
        do {
            guard let samsungAPI = verifiedVoWLANAPI() else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await samsungAPI.refreshSMS()
            await loadMessagesFromAgent(silently: silently, reportingAgent: samsungAPI)
            if !silently { errorMessage = nil }
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }

    /// URC 已经让 Agent 读取了单条短信；事件路径只取交付队列，不再触发全量 CMGL。
    func loadMessagesFromAgent(
        silently: Bool = false,
        notifyIfBackground: Bool = false,
        reportingAgent: AirSIMAPI? = nil
    ) async {
        do {
            guard let currentAgent = verifiedVoWLANAPI() ?? reportingAgent else {
                throw CallKitBridgeError.noReachableTransport
            }
            let producer = reportingAgent ?? currentAgent
            // Snapshot a verified producer before suspension; never trust an
            // inbox-supplied device label or the selection after the await.
            let producerID = localDevices.agentIDs.first { localDevices.api(for: $0)?.route == producer.route }
            let fetched = try await AgentSMSInboxFetch.fetch(
                reportingAgent: reportingAgent, discoveredAgent: currentAgent
            )
            let remoteMessages = fetched.messages.map { original in
                var message = original
                message.sourceAgentID = producerID
                return message
            }
            let existingIDs = Set(messages.map(\.id))
            let newlyReceived = remoteMessages
                .filter { !existingIDs.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
            SMSVerificationCodeClipboard.handle(newlyReceived)
            let mergedMessages = await mergeMessages(remoteMessages, acknowledgingOn: fetched.agent)
            if messages != mergedMessages { messages = mergedMessages }
            if notifyIfBackground {
                for message in historyStore.visibleMessages(newlyReceived).suffix(3) {
                    incomingSMSNotifier.notify(
                        message: message,
                        displayName: contacts.displayName(for: message.sender),
                        appIsActive: appIsActive
                    )
                }
            }
            if !silently { errorMessage = nil }
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }

    func clearLocalMessages() {
        deleteMessages(ids: Set(messages.map(\.id)))
    }

    func deleteMessages(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        guard historyStore.deleteMessages(ids: ids, from: messages) else {
            errorMessage = "无法删除本机短信，请稍后重试"
            return
        }
        messages = historyStore.visibleMessages(messages)
        errorMessage = nil
    }

    func deleteCallHistory(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let remaining = callHistory.filter { !ids.contains($0.id) }
        guard historyStore.saveCallHistory(remaining) else {
            errorMessage = "无法删除本机通话记录，请稍后重试"
            return
        }
        callHistory = remaining
        errorMessage = nil
    }

    func reloadMessagesFromLocalStore() {
        restoreLocalHistory()
    }

    /// 将磁盘副本并入当前内存，只增加或更新记录，绝不以空读取清掉界面数据。
    private func restoreLocalHistory() {
        let storedCalls = historyStore.loadCallHistory()
        if !storedCalls.isEmpty {
            var callsByID: [String: CallRecord] = [:]
            for record in callHistory { callsByID[record.id] = record }
            for record in storedCalls {
                if let existing = callsByID[record.id], existing.updatedAt >= record.updatedAt {
                    continue
                }
                callsByID[record.id] = record
            }
            callHistory = normalizedCallHistory(Array(callsByID.values))
        }

        let storedMessages = historyStore.loadMessages()
        if !storedMessages.isEmpty {
            var messagesByID: [String: SMSMessage] = [:]
            for message in messages { messagesByID[message.id] = message }
            for message in storedMessages { messagesByID[message.id] = message }
            messages = normalizedMessages(historyStore.visibleMessages(Array(messagesByID.values)))
        }
    }

    /// 远端列表可能因模块重启、自动清理或离线而变短，因此只做并集，不删除手机副本。
    private func mergeCallHistory(_ remote: [CallRecord], agentID: String?, source: AirSIMAPI) async -> [CallRecord] {
        if let agentID {
            if persistDeviceHistory(remote, agentID: agentID) {
                try? await source.acknowledgeCallHistory(ids: remote.map(\.id))
            }
            return callHistory
        }
        var byID: [String: CallRecord] = [:]
        for record in callHistory {
            if let existing = byID[record.id], existing.updatedAt >= record.updatedAt { continue }
            byID[record.id] = record
        }
        for record in remote {
            if let local = byID[record.id], local.updatedAt > record.updatedAt {
                continue
            }
            byID[record.id] = record
        }
        let merged = normalizedCallHistory(Array(byID.values))
        if !remote.isEmpty, historyStore.saveCallHistory(merged) {
            // 只有手机副本写入成功才确认模块，断线时模块仍会保留未交付队列。
            let persistedIDs = Set(merged.map(\.id))
            let acknowledgedIDs = remote.map(\.id).filter { persistedIDs.contains($0) }
            try? await source.acknowledgeCallHistory(ids: acknowledgedIDs)
        }
        return merged
    }

    private func mergeMessages(
        _ remote: [SMSMessage], acknowledgingOn source: AirSIMAPI
    ) async -> [SMSMessage] {
        var byID: [String: SMSMessage] = [:]
        for message in messages { byID[message.id] = message }
        for var message in remote {
            // 旧版模块没有 delivery_id 时保留手机已有标识，避免新旧版本来回覆盖。
            if message.deliveryID == nil { message.deliveryID = byID[message.id]?.deliveryID }
            byID[message.id] = message
        }
        let merged = normalizedMessages(historyStore.visibleMessages(Array(byID.values)))
        if !remote.isEmpty, historyStore.saveMessages(merged) {
            // A durably deleted delivery is also consumed; do not keep redelivering it.
            let visibleRemoteIDs = Set(historyStore.visibleMessages(remote).map(\.id))
            let persistedIDs = Set(historyStore.loadMessages().map(\.id)).union(remote.map(\.id).filter {
                !visibleRemoteIDs.contains($0)
            })
            let acknowledgedIDs = remote
                .filter { persistedIDs.contains($0.id) }
                .compactMap(\.deliveryID)
            try? await source.acknowledgeMessages(ids: acknowledgedIDs)
        }
        // A deletion can happen while the delivery acknowledgement is suspended.
        return normalizedMessages(historyStore.visibleMessages(merged + historyStore.loadMessages()))
    }

    /// 模块不会在收件箱接口回传已发送短信，因此发送成功后立即写入手机本地历史。
    private func saveSentMessage(recipient: String, content: String) {
        let updatedMessages = SMSHistoryPolicy.appendingSentMessage(
            recipient: recipient,
            content: content,
            at: .now,
            to: messages,
            limit: maxMessageCount
        )
        messages = updatedMessages
        if !historyStore.saveMessages(updatedMessages) {
            errorMessage = "短信已发送，但保存到本机失败，请稍后刷新确认"
        }
    }

    private func normalizedCallHistory(_ records: [CallRecord]) -> [CallRecord] {
        Array(records
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxCallHistoryCount))
    }

    private func normalizedMessages(_ records: [SMSMessage]) -> [SMSMessage] {
        Array(SMSHistoryPolicy.deduplicated(records.filter { !Self.isSystemSMSStatus($0) })
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxMessageCount))
    }

    private static func isSystemSMSStatus(_ message: SMSMessage) -> Bool {
        // MIUI Messages posts a service-status notification with this text;
        // it is not an SMS and must not appear in the conversation list.
        (message.sender.contains("短信") && message.sender.contains("正在运行"))
            || message.content.contains("点按即可了解详情或停止应用")
    }

    private func perform(
        allowWhileBusy: Bool = false,
        _ operation: () async throws -> Void
    ) async {
        guard allowWhileBusy || !isBusy else { return }
        activeOperationCount += 1
        isBusy = true
        defer {
            activeOperationCount -= 1
            isBusy = activeOperationCount > 0
        }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func makeLocalAudioStartupInvalidationCheck() -> () -> LocalCallAudioRollbackReason? {
        let startupTransport = currentCallTransport
        let startupPCMRoute = currentPCMRoute
        if let key = presentedDeviceCall, let route = deviceCallRouter.route(for: key) {
            return { [weak self] in
                guard let self else { return .callChanged }
                guard !Task.isCancelled else { return .taskCancelled }
                guard self.presentedDeviceCall == key, self.deviceCalls.active == key else { return .callChanged }
                guard self.deviceCallContext.media.owner == key else { return .mediaOwnerChanged }
                guard self.deviceCallRouter.route(for: key) == route,
                      self.currentCallTransport == startupTransport,
                      self.currentPCMRoute == startupPCMRoute else { return .routeChanged }
                guard self.deviceCalls.latestEvent(for: key)?.state == .active else { return .callNotActive }
                return nil
            }
        }
        let startupCall = callLifecycleSnapshot
        let startupAttempt = outgoingAttemptID
        return { [weak self] in
            guard let self else { return .callChanged }
            guard !Task.isCancelled else { return .taskCancelled }
            let current = self.callLifecycleSnapshot
            guard current.callID == startupCall.callID, current.callUUID == startupCall.callUUID,
                  current.generation == startupCall.generation,
                  self.outgoingAttemptID == startupAttempt else { return .callChanged }
            guard current.state == .active else { return .callNotActive }
            guard !WatchCallCoordinator.shared.ownsMedia(callID: current.callID),
                  self.deviceCallContext.media.owner == nil else { return .mediaOwnerChanged }
            guard self.currentCallTransport == startupTransport,
                  self.currentPCMRoute == startupPCMRoute else { return .routeChanged }
            return nil
        }
    }

    private func startCallAudioIfReady() async {
        guard !Task.isCancelled else { return }
        let cloudSession = IPhoneCloudCallSession.shared
        if cloudSession.call != nil, cloudSession.answered {
            await performCallAudioStartup()
            return
        }
        guard callLifecycleSnapshot.state == .active, !audio.active else { return }
        await localAudioStartup.run { [weak self] in
            await self?.performCallAudioStartup()
        }
    }

    private func performCallAudioStartup() async {
        guard !Task.isCancelled else { return }
        if let key = presentedDeviceCall, deviceCallRouter.route(for: key) != nil {
            guard deviceCallContext.media.owner == key, currentCallTransport == .vowlan else { return }
        }
        if WatchCallCoordinator.shared.ownsMedia(callID: activeCall?.id)
            || WatchCallCoordinator.shared.ownsMedia(callID: remoteCall?.id)
            || WatchCallCoordinator.shared.ownsMedia(callID: callLifecycleSnapshot.callID) {
            return
        }
        let managedByCallKit = callKit.managesCurrentCall
        let cloudSession = IPhoneCloudCallSession.shared
        if cloudSession.call != nil, cloudSession.answered {
            if CloudCallAudioStartupPolicy.shouldStart(
                answered: true,
                mediaPrepared: cloudSession.isPrepared,
                lifecycleState: cloudSession.lifecycleState,
                isOutgoing: cloudSession.call?.isOutgoing == true,
                managedByCallKit: managedByCallKit,
                callKitAudioSessionActive: callKit.audioSessionIsActive
            ) {
                backgroundStandby.suspendForCall()
                currentCallTransport = .cloud
                cloudSession.startAudioWithRetry()
            }
            return
        }
        guard !managedByCallKit || callKit.audioSessionIsActive else { return }
        guard !Task.isCancelled, callLifecycleSnapshot.state == .active, !audio.active else { return }
        let owner = UUID()
        let invalidationReason = makeLocalAudioStartupInvalidationCheck()
        let isCurrent = { invalidationReason() == nil }
        backgroundStandby.suspendForCall()

        do {
            guard let localAPI = reachableLocalAPI else {
                backgroundStandby.resumeAfterCall()
                errorMessage = "本地语音路由尚未锁定"
                return
            }
            let pcmRoute = currentPCMRoute ?? Self.pcmRoute(for: localAPI.route)
            // 先完成麦克风授权和 AVAudioEngine 启动，再让 Agent 开始等待 PCM
            // 客户端。否则首次授权停留超过 Agent 的等待窗口时，helper 会被提前杀死。
            let outcome = try await LocalCallAudioStartupCoordinator.start(
                invalidationReason: invalidationReason,
                activatePhoneAudio: { [audio] in
                    await audio.activateForCall(route: pcmRoute, sessionAlreadyActive: managedByCallKit,
                                                owner: owner, isCurrent: isCurrent)
                },
                registerAgentAudio: {
                    let started = ProcessInfo.processInfo.systemUptime
                    Task { await AgentVerboseTraceRecorder.shared.recordAudioStartup(phase: "agent_register") }
                    let outcome: CallAudioRegistrationOutcome
                    do { outcome = try await CallAudioRegistrationCoordinator.register(service: localAPI) }
                    catch {
                        Task { await AgentVerboseTraceRecorder.shared.recordAudioStartup(phase: "failed") }
                        throw error
                    }
                    let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                    Task { await AgentVerboseTraceRecorder.shared.recordAudioStartup(
                        phase: outcome == .registered ? "agent_ready" : "failed", elapsedMilliseconds: elapsed
                    ) }
                    return outcome
                },
                rollbackPhoneAudio: { [audio] reason in
                    Task { await AgentVerboseTraceRecorder.shared.recordAudioStartup(
                        phase: "rollback", rollbackReason: reason) }
                    guard audio.sessionOwner == owner else { return }
                    // A replaced BLE/cloud call may already own AVAudioSession.
                    audio.deactivate(preservingSharedSession: !isCurrent())
                    if isCurrent() { try? await localAPI.setAudioHostEnabled(false) }
                }
            )
            guard outcome == .started else {
                if isCurrent() || !callLifecycleSnapshot.state.representsCall {
                    backgroundStandby.resumeAfterCall()
                }
                return
            }
            if currentCallTransport == nil {
                let transport: CallTransport
                switch localAPI.route {
                case .vowlan: transport = .vowlan
                }
                lockLocalTransport(transport, api: localAPI, pcmRoute: pcmRoute)
            }
        } catch {
            // The coordinator already rolled back only this startup's resources.
            guard isCurrent() else { return }
            backgroundStandby.resumeAfterCall()
            errorMessage = "无法登记通话音频：\(error.localizedDescription)"
            return
        }
    }

    private func waitForLocalIncomingRoute() async -> (AirSIMAPI, PCMRoute)? {
        // Cold launch from CallKit can answer before Bonjour/VoWLAN discovery has
        // completed. Retry briefly instead of failing the call immediately.
        for attempt in 0..<8 {
            if let route = await readyVoWLANRoute() { return route }
            // A cloud media URL in the APNs payload does not mean the local
            // route is ready. Keep waiting unless another call already owns
            // the local presentation.
            if activeCall != nil { return nil }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        return nil
    }

    func readyVoWLANRoute() async -> (AirSIMAPI, PCMRoute)? {
        if let api = selectedDirectoryAPI { return (api, Self.pcmRoute(for: api.route)) }
        vowlan.startBrowsing()
        await vowlan.probeNow()
        if vowlan.availability.isReady(),
           let endpoint = vowlan.availability.endpoint,
           permitsVoWLANEndpoint(endpoint),
           let credential = credentialForVoWLANEndpoint(endpoint) {
            return (
                AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential)),
                .vowlan(endpoint: endpoint, credential: credential)
            )
        }
        // PushKit 可在后台先于 Bonjour 浏览器恢复。最近一次成功轮询若明确来自
        // VoWLAN，就复用同一已鉴权端点；绝不能把通用 isOnline 误当成 VoWLAN 可达。
        guard isOnline, !isReconnecting, let cached = lastSuccessfulLocalAPI,
              case let .vowlan(endpoint, credential) = cached.route,
              permitsVoWLANEndpoint(endpoint) else { return nil }
        return (cached, .vowlan(endpoint: endpoint, credential: credential))
    }

    private func lockLocalTransport(
        _ transport: CallTransport,
        api: AirSIMAPI,
        pcmRoute: PCMRoute
    ) {
        currentCallTransport = transport
        currentLocalAPI = api
        currentPCMRoute = pcmRoute
        lockedCallTransport = LockedCallTransport(
            transport: transport,
            generation: callLifecycleSnapshot.generation
        )
        // 取消仍绑定旧本地路由的长轮询，让 active 状态立即从 VoWLAN 返回。
        restartPolling()
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "call_transport", phase: "locked",
                title: transport == .vowlan ? "本通已锁定 VoWLAN" : "本通已锁定模块本地链路",
                fields: ["generation": String(callLifecycleSnapshot.generation)]
            )
        }
    }

    private func clearLockedTransport() {
        currentCallTransport = nil
        currentLocalAPI = nil
        currentPCMRoute = nil
        lockedCallTransport = nil
    }

    private func endVoWLANCallAfterPathLoss() async {
        guard currentCallTransport == .vowlan else { return }
        let localAPI = currentLocalAPI
        audio.deactivate()
        try? await localAPI?.hangupCall(callID: localAPICallID)
        errorMessage = "VoWLAN 局域网已断开；当前通话已结束，下一通将自动选择云端"
        await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "ios", category: "call_transport", phase: "ended",
            title: "hotspot_lost_no_midcall_handover",
            detail: "VoWLAN 局域网路径丢失，结束当前通话；未迁移到云端",
            fields: ["generation": String(lockedCallTransport?.generation ?? 0)],
            isFailure: true
        )
        try? await callKit.endCurrentCall()
    }

    /// 仅允许电话网络常见字符，防止意外把 AT 控制字符传入模块代理。
    private static func validatedNumber(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        guard trimmed.count <= 82,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return trimmed
    }

    private static func remoteCallRecord(
        from incoming: IncomingVoIPCall,
        state: String,
        startedAt: Date = Date()
    ) -> CallRecord {
        CallRecord(
            id: incoming.callID,
            index: 0,
            direction: "incoming",
            state: state,
            number: incoming.number,
            startedAt: startedAt,
            updatedAt: Date(),
            endedAt: nil,
            missed: false
        )
    }

    private func updateRemoteCallState(_ state: String) {
        guard let incoming = callKit.currentIncomingPush else { return }
        remoteCall = Self.remoteCallRecord(
            from: incoming,
            state: state,
            startedAt: remoteCall?.startedAt ?? Date()
        )
    }
    private func publishWatchLifecycle(
        _ event: CallLifecycleEvent, phase: WatchCallPhase,
        previous: CallLifecycleSnapshot
    ) {
        if let incoming = callKit.currentIncomingPush {
            let continuesPushedCall = incoming.uuid == event.callUUID
                || incoming.callID == event.callID
                || (previous.callID == incoming.callID
                    && previous.callUUID == incoming.uuid
                    && previous.generation == event.generation)
            if continuesPushedCall {
                let aliases = event.callID == incoming.callID ? [] : [event.callID]
                WatchCallCoordinator.shared.publish(
                    callID: incoming.callID, callUUID: incoming.uuid, aliases: aliases, phase: phase,
                    number: incoming.number, callerName: incoming.callerName,
                    transport: currentCallTransport == .bluetooth ? "bluetooth" : "vowlan"
                )
                return
            }
        }
        let record = activeCall ?? remoteCall
        WatchCallCoordinator.shared.publish(
            callID: event.callID, callUUID: event.callUUID, phase: phase,
            number: record?.number, callerName: record.map { contacts.displayName(for: $0.number) },
            transport: currentCallTransport == .bluetooth ? "bluetooth" : "vowlan"
        )
    }


    @discardableResult
    private func applyCallLifecycle(_ event: CallLifecycleEvent,
                                    replacingProvisionalCallID: String? = nil) -> Bool {
        let previous = callLifecycleSnapshot
        guard callLifecycleStore.apply(event, replacingProvisionalCallID: replacingProvisionalCallID) else { return false }
        callLifecycleSnapshot = callLifecycleStore.snapshot
        if let call = pushedCallIdentity,
           event.state.isTerminal || call.uuid != event.callUUID || call.generation != event.generation {
            pushedCallIdentity = nil
        }
        if previous.callID != callLifecycleSnapshot.callID
            || previous.callUUID != callLifecycleSnapshot.callUUID
            || previous.generation != callLifecycleSnapshot.generation
            || previous.state != callLifecycleSnapshot.state {
            callUpdateWork.cancel()
            // Poll refreshes leave this task alone; a changed call revokes it.
            if previous.callID != callLifecycleSnapshot.callID
                || previous.callUUID != callLifecycleSnapshot.callUUID
                || previous.generation != callLifecycleSnapshot.generation
                || callLifecycleSnapshot.state != .active {
                localAudioStartup.cancel()
            }
        }
        if event.state == .active {
            // Publish the authoritative answer state before any audio or UI await.
            publishWatchLifecycle(event, phase: .active, previous: previous)
            audio.stopCallTone(deactivateSession: false)
            if previous.state != .active {
                Task { await AgentVerboseTraceRecorder.shared.recordAudioStartup(phase: "answer_observed") }
                // CallKit audio activation can arrive before the lifecycle store
                // reaches .active. Retry here so local/cloud audio starts even when
                // the earlier didActivate callback was too early.
                Task { @MainActor [weak self] in await self?.startCallAudioIfReady() }
            }
        }
        if event.state == .ending || event.state.isTerminal {
            callPresentationSurface = nil
            pendingOutgoingCall = nil
            if event.state.isTerminal {
                // A remote end must not leave .bluetooth/.cloud behind for the next
                // incoming call: callKitAnswer used to answer a cloud push over a
                // stale VoBLE transport, showing a "Bluetooth link ended" status.
                clearLockedTransport()
            }
            publishWatchLifecycle(event, phase: .ended, previous: previous)
            // Return to the persistent standby activity (the island must remain visible
            // in the background); force the update so a stale call timer cannot linger.
            Task { @MainActor [weak self] in
                await self?.refreshLiveActivityIdle()
            }
        }
        return true
    }

    private func applyCurrentCallIntent(_ state: CallLifecycleState, source: CallLifecycleSource) {
        if let key = presentedDeviceCall {
            if state == .connecting { _ = activateDeviceCall(key) }
            if state == .ending || state.isTerminal { deviceCallRouter.finished(key) }
        }
        guard let callID = callLifecycleSnapshot.callID,
              let callUUID = callLifecycleSnapshot.callUUID,
              callLifecycleSnapshot.generation > 0 else { return }
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: callID,
            callUUID: callUUID,
            generation: callLifecycleSnapshot.generation,
            state: state,
            source: source,
            timestamp: Date(),
            traceID: "app-\(UUID().uuidString.lowercased())",
            failure: nil
        ))
    }

    @discardableResult
    func applyAgentCallRecord(
        _ call: CallRecord,
        forcedState: CallLifecycleState? = nil,
        agentID: String? = nil
    ) -> Bool {
        // A poll issued before a BLE dial can return after ownership is locked.
        // Legacy snapshots do not prove operation→Telecom aliases and must not
        // insert a second registry identity or replace the native presentation.
        if ownsLocalCallPresentation, agentID.flatMap({ localDevices.metadata(for: $0)?.canonicalCallIDs }) != true {
            return false
        }
        if let agentID, localDevices.metadata(for: agentID)?.canonicalCallIDs == true {
            let state = forcedState ?? Self.lifecycleState(for: call.state)
            _ = receiveOwnedCallEvent(.init(agentID: agentID, callID: call.androidID ?? call.id,
                state: state, transport: .vowlan, transportEpoch: localDevices.transportEpoch(for: agentID),
                number: call.number, direction: call.direction, backendCallID: call.id))
            return presentedDeviceCall?.agentID == agentID && deviceCalls.active == presentedDeviceCall
        }
        let incoming = callKit.currentIncomingPush
        let sameSnapshot = callLifecycleSnapshot.callID == call.id
        let callUUID = (incoming?.callID == call.id ? incoming?.uuid : nil)
            ?? (sameSnapshot ? callLifecycleSnapshot.callUUID : nil)
            ?? callKit.watchCallUUID(for: call.id)
            ?? UUID()
        let generation = (incoming?.callID == call.id ? incoming?.generation : nil)
            ?? (sameSnapshot ? callLifecycleSnapshot.generation : nil)
            ?? max(1, callLifecycleSnapshot.generation &+ 1)
        let state = forcedState ?? Self.lifecycleState(for: call.state)
        let presentation = CallLifecycleEvent(
            callID: call.id,
            callUUID: callUUID,
            generation: generation,
            state: state,
            source: .agent,
            timestamp: call.updatedAt,
            traceID: "agent-poll-\(call.id)-\(generation)",
            failure: state == .failed ? "Agent 报告通话失败" : nil
        )
        if let agentID {
            let effects = receiveDeviceCallEvent(DeviceCallEvent(agentID: agentID, callID: call.id,
                state: state, transport: .vowlan, transportEpoch: UInt64(max(0, pollingGeneration)),
                number: call.number, direction: call.direction), presentation: presentation)
            guard let key = deviceCalls.key(agentID: agentID, callID: call.id),
                  deviceCallCanPresent(key) || (state.isTerminal && effects.contains(.ended(key))) else { return false }
            return callLifecycleSnapshot.callUUID == callUUID && callLifecycleSnapshot.state == state
        }
        return applyCallLifecycle(presentation)
    }

    private func lifecycleRecord(from record: CallRecord?) -> CallRecord? {
        callLifecycleStore.presentationRecord(from: record)
    }

    private static func lifecycleState(for agentState: String) -> CallLifecycleState {
        switch agentState {
        case "incoming", "waiting": return .ringing
        case "dialing", "alerting": return .connecting
        case "active", "held": return .active
        case "ending": return .ending
        case "ended": return .ended
        default: return .connecting
        }
    }
}

protocol OutgoingCallServicing: Sendable {
    func warmAudioHost() async throws
    func setAudioHostEnabled(_ enabled: Bool) async throws
    func dial(number: String) async throws
}

extension AirSIMAPI: OutgoingCallServicing {}

protocol CallAudioRegistrationServicing: Sendable {
    func setAudioHostEnabled(_ enabled: Bool) async throws
    func callStatus() async throws -> CallStatus
}

extension AirSIMAPI: CallAudioRegistrationServicing {}

enum CallAudioRegistrationOutcome: Equatable, Sendable {
    case registered
    case callNoLongerActive
    case temporarilyUnavailable
}

enum CallAudioRegistrationCoordinator {
    static func register(
        service: any CallAudioRegistrationServicing,
        retryDelay: Duration = .milliseconds(250)
    ) async throws -> CallAudioRegistrationOutcome {
        // Enabling the audio host is idempotent. A locked/backgrounded iPhone can
        // report "wiredPathUnavailable" while Wi-Fi is waking up; retrying avoids
        // a false audio-start failure and the subsequent automatic hangup.
        for attempt in 0..<4 {
            do {
                try await service.setAudioHostEnabled(true)
                return .registered
            } catch APIError.http(409, _) {
                // 通话事件与媒体注册是两个请求。旧 Agent 在其间完成 CLCC 刷新时，
                // 重新读取状态，避免把短暂竞争当成致命拨号错误。
                let latest = try await service.callStatus()
                guard latest.active?.state == "active" else {
                    return .callNoLongerActive
                }
                if retryDelay > .zero {
                    try await Task.sleep(for: retryDelay)
                }
                do {
                    try await service.setAudioHostEnabled(true)
                    return .registered
                } catch APIError.http(409, _) {
                    // 0.3.39 的 DSCI 与 CLCC 会在接通瞬间短暂交错。此时保持
                    // CallKit 通话并交给下一轮事件重试，不能把媒体尚未就绪显示成拨号失败。
                    return .temporarilyUnavailable
                }
            } catch {
                guard attempt < 3, WiredHTTPTransport.isRetryableTransportFailure(error) else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(400))
            }
        }
        return .temporarilyUnavailable
    }
}

enum LocalCallAudioStartupOutcome: Equatable, Sendable {
    case started
    case phoneAudioUnavailable
    case callNoLongerActive
    case temporarilyUnavailable
}

enum LocalCallAudioRollbackReason: String, Sendable {
    case taskCancelled = "task_cancelled"
    case callChanged = "call_changed"
    case callNotActive = "call_not_active"
    case mediaOwnerChanged = "media_owner_changed"
    case routeChanged = "route_changed"
    case agentCallInactive = "agent_call_inactive"
    case registrationUnavailable = "registration_unavailable"
    case registrationFailed = "registration_failed"
}

@MainActor
final class LocalCallAudioStartupCoordinator {
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        while let existing = task {
            guard !Task.isCancelled else { return }
            await existing.value
            guard !Task.isCancelled else { return }
            // A cancelled flight cannot satisfy a new startup request. Wait for
            // its owner-scoped rollback before retrying, then re-check the slot:
            // another observer may already have started the replacement.
            if existing.isCancelled { continue }
            return
        }
        guard !Task.isCancelled else { return }
        // Unstructured on purpose: polling and CallKit are observers, not owners.
        let startup = Task { @MainActor in
            defer { self.task = nil }
            await operation()
        }
        task = startup
        await startup.value
    }

    func cancel() { task?.cancel() }

    static func start(
        invalidationReason: () -> LocalCallAudioRollbackReason? = { nil },
        activatePhoneAudio: () async -> Bool,
        registerAgentAudio: () async throws -> CallAudioRegistrationOutcome,
        rollbackPhoneAudio: (LocalCallAudioRollbackReason) async -> Void
    ) async rethrows -> LocalCallAudioStartupOutcome {
        func invalidation() -> LocalCallAudioRollbackReason? {
            Task.isCancelled ? .taskCancelled : invalidationReason()
        }
        guard invalidation() == nil else { return .callNoLongerActive }
        let activated = await activatePhoneAudio()
        if let reason = invalidation() {
            if activated { await rollbackPhoneAudio(reason) }
            return .callNoLongerActive
        }
        guard activated else { return .phoneAudioUnavailable }
        do {
            let outcome = try await registerAgentAudio()
            if let reason = invalidation() {
                await rollbackPhoneAudio(reason)
                return .callNoLongerActive
            }
            switch outcome {
            case .registered:
                return .started
            case .callNoLongerActive:
                await rollbackPhoneAudio(.agentCallInactive)
                return .callNoLongerActive
            case .temporarilyUnavailable:
                await rollbackPhoneAudio(.registrationUnavailable)
                return .temporarilyUnavailable
            }
        } catch {
            await rollbackPhoneAudio(invalidation() ?? .registrationFailed)
            throw error
        }
    }
}

enum OutgoingCommandAvailability {
    static func isAvailable(
        mode: AirSIMConnectionMode = .automatic,
        localControlReachable: Bool,
        bluetoothReady: Bool = false,
        cloudModeEnabled: Bool,
        cloudHeartbeatFresh: Bool
    ) -> Bool {
        DialRouteSelector.preferred(
            mode: mode,
            vowlanReady: localControlReachable,
            bluetoothReady: bluetoothReady,
            cloudReady: cloudModeEnabled && cloudHeartbeatFresh
        ) != nil
    }
}

enum OutgoingCallCoordinator {
    static func start(number: String, service: any OutgoingCallServicing) async throws {
        try? await service.warmAudioHost()
        try await service.dial(number: number)
    }
}

enum OutgoingCallRouteResult<CloudResult: Sendable>: Sendable {
    case vowlan
    case cloud(CloudResult)
}

extension OutgoingCallRouteResult: Equatable where CloudResult: Equatable {}

enum OutgoingCallFallbackPolicy {
    static func permitsCloudFallback(after error: Error, cloudModeEnabled: Bool) -> Bool {
        guard cloudModeEnabled, !(error is CancellationError) else { return false }
        // 收到 Agent HTTP 响应说明命令已到达执行边界。拨号是非幂等操作，
        // 明确拒绝或返回业务错误时不能再经 Relay 重放。
        if error is APIError { return false }
        return true
    }
}

@MainActor
enum OutgoingCallRouteCoordinator {
    static func start<CloudResult: Sendable>(
        number: String,
        vowlanService: (any OutgoingCallServicing)?,
        cloudModeEnabled: Bool,
        isCurrent: () -> Bool = { true },
        discardCloud: (CloudResult) async -> Void = { _ in },
        startCloud: () async throws -> CloudResult
    ) async throws -> OutgoingCallRouteResult<CloudResult> {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        if let vowlanService {
            do {
                try await OutgoingCallCoordinator.start(number: number, service: vowlanService)
                guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
                return .vowlan
            } catch {
                guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
                guard OutgoingCallFallbackPolicy.permitsCloudFallback(
                    after: error,
                    cloudModeEnabled: cloudModeEnabled
                ) else {
                    throw error
                }
            }
        } else if !cloudModeEnabled {
            throw CloudCommandError.cloudModeDisabled
        }

        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        let cloud = try await startCloud()
        guard !Task.isCancelled, isCurrent() else {
            await discardCloud(cloud)
            throw CancellationError()
        }
        return .cloud(cloud)
    }
}

enum AgentPollingRouteSelector {
    static func shouldPollLocal(mode: AirSIMConnectionMode, activeTransport: CallTransport?) -> Bool {
        if let activeTransport { return activeTransport == .vowlan }
        return ConnectionModeRuntimePolicy(mode: mode).startsVoWLAN
    }
    static func select<Service>(
        primary: Service,
        lockedLocal: Service?,
        transport: CallTransport?
    ) -> Service {
        if transport == .vowlan, let lockedLocal { return lockedLocal }
        return primary
    }
}

enum CallKitAudioPreparationCoordinator {
    static func prepare(
        suspendStandby: () -> Void,
        configureCallAudio: () throws -> Void,
        resumeStandby: () -> Void
    ) throws {
        suspendStandby()
        do {
            try configureCallAudio()
        } catch {
            resumeStandby()
            throw error
        }
    }
}

extension AppModel: CallKitActionHandling {
    func callKitAnswer(uuid: UUID, origin: CallAnswerOrigin) async throws {
        if let route = deviceCallRouter.route(for: uuid) {
            audio.stopCallTone(deactivateSession: false)
            backgroundStandby.suspendForCall()
            callPresentationSurface = origin == .app ? .app : .system
            try await answerOwnedCall(route.key)
            return
        }
        guard !deviceCallRouter.contains(uuid: uuid), callKit.currentSystemCallUUID == uuid else {
            throw DeviceCallRoutingError.stale
        }
        try await callKitAnswer(origin: origin)
    }

    func callKitEnd(uuid: UUID) async throws {
        if let route = deviceCallRouter.route(for: uuid) {
            let ringing = deviceCalls.latestEvent(for: route.key)?.state == .ringing
            // Retire UI before the asynchronous backend reply; target is held by Router.
            try await deviceCallRouter.end(route.key, rejectIfRinging: ringing)
            return
        }
        if deviceCallRouter.contains(uuid: uuid) { return }
        guard callKit.currentSystemCallUUID == uuid else { throw DeviceCallRoutingError.stale }
        try await callKitEnd()
    }

    func callKitSetMuted(_ muted: Bool, uuid: UUID) async {
        if let route = deviceCallRouter.route(for: uuid) {
            guard deviceCallContext.media.owner == route.key else { return }
            isMuted = muted
            if route.transport == .bluetooth { vobleHub.retainedBundle(for: route.key.agentID)?.calls.setMuted(muted) }
            else { audio.setMuted(muted) }
            return
        }
        guard !deviceCallRouter.contains(uuid: uuid), callKit.currentSystemCallUUID == uuid else { return }
        await callKitSetMuted(muted)
    }

    func callKitPlayDTMF(_ digits: String, uuid: UUID) async throws {
        if let route = deviceCallRouter.route(for: uuid) { try await deviceCallRouter.sendDTMF(digits, for: route.key); return }
        guard !deviceCallRouter.contains(uuid: uuid), callKit.currentSystemCallUUID == uuid else { throw DeviceCallRoutingError.stale }
        try await callKitPlayDTMF(digits)
    }

    func callKitPrepareAudioSession() throws {
        try CallKitAudioPreparationCoordinator.prepare(
            suspendStandby: { backgroundStandby.suspendForCall() },
            configureCallAudio: {
                if ConnectionModePreference.selected() == .cloud,
                   callKit.currentIncomingPush?.authenticatedMediaURL != nil {
                    try IPhoneCloudCallSession.shared.prepareAudioForCallKit()
                } else {
                    try audio.prepareForCallKit()
                }
            },
            resumeStandby: { backgroundStandby.resumeAfterCall() }
        )
    }

    func callKitStart(number: String) async throws {
        guard deviceCalls.active == nil, deviceCallContext.media.owner == nil,
              deviceCallContext.admissionReservation == nil,
              !ownsLocalCallPresentation, !cloudCallOwnsPrimaryPresentation else {
            throw DeviceCallRoutingError.busy
        }
        let boundAtStart = boundAgentID
        let attempt = UUID()
        outgoingAttemptID = attempt
        beginCallTransitionProtection()
        if callPresentationSurface == nil { callPresentationSurface = .system }
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        do {
            let selectedMode = ConnectionModePreference.selected()
            let runtimePolicy = ConnectionModeRuntimePolicy(mode: selectedMode)
            if selectedMode != .cloud {
                if runtimePolicy.startsVoWLAN { await refreshLocalDeviceDirectory() }
                // Only verified local peers count. A stale peer whose poll failed
                // remains in LocalDeviceDirectory.agentIDs but is not dialable and
                // must not force a false "multiple devices" refusal.
                let verifiedWLAN = localDevices.agentIDs.filter { localDevices.api(for: $0) != nil }
                let known = Set(verifiedWLAN
                    + vobleHub.sessions.values.compactMap { $0.central.authenticatedIdentity })
                if boundAtStart == nil, known.count > 1 { throw DeviceCallRoutingError.noSelection }
                let target = boundAtStart ?? (known.count == 1 ? known.first : nil)
                if let target {
                    if runtimePolicy.startsVoWLAN, let endpoint = localDevices.routes(for: target)?.vowlan {
                        try? await localDevices.verify(agentID: target, endpoint: endpoint)
                    }
                    guard outgoingAttemptID == attempt, !Task.isCancelled else { return }
                    let canWLAN = localDevices.api(for: target) != nil && localDevices.metadata(for: target)?.canonicalCallIDs == true
                    let canBLE = vobleHub.bundle(for: target) != nil
                    if DialRouteSelector.preferred(mode: selectedMode, vowlanReady: canWLAN,
                        bluetoothReady: canBLE, cloudReady: false) != nil {
                        let uuid = callKit.currentSystemCallUUID ?? UUID()
                        deviceCallRouter.systemUUID = { uuid }
                        let route = try await deviceCallRouter.dial(agentID: target, number: number,
                            mode: selectedMode, simAccount: selectedSIMSlotID(for: target))
                        if deviceCalls.active == route.key { presentOwnedCall(route.key, state: deviceCalls.latestEvent(for: route.key)?.state ?? .connecting) }
                        return
                    }
                }
                if !runtimePolicy.startsCloud { throw DeviceCallRoutingError.unavailable }
            }
            // Local commands above have an immutable source. Cloud fallback is
            // selected only before dialing, never after an uncertain local reply.
            let vowlanRoute: (AirSIMAPI, PCMRoute)? = nil
            guard outgoingAttemptID == attempt, !Task.isCancelled else { return }
            if selectedMode == .bluetooth
                || (selectedMode == .automatic && vowlanRoute == nil && boundBluetoothReady) {
                guard boundBluetoothReady else { throw VoBLECentralError.notReady }
                let legacyTarget = boundAtStart ?? voble.authenticatedIdentity
                let identity = try await vobleCalls.startOutgoing(
                    number: number, simAccount: legacyTarget.flatMap { selectedSIMSlotID(for: $0) })
                currentCallTransport = .bluetooth
                lockedCallTransport = LockedCallTransport(
                    transport: .bluetooth, generation: identity.generation)
                pendingOutgoingCall = CallRecord(
                    id: identity.callID, index: 0, direction: "outgoing", state: "dialing",
                    number: number, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false)
                return
            }
            let cloudModeEnabled = CloudModePreference.isEnabled()
            let routeResult = try await OutgoingCallRouteCoordinator.start(
                number: number,
                vowlanService: vowlanRoute?.0,
                cloudModeEnabled: cloudModeEnabled,
                isCurrent: { self.outgoingAttemptID == attempt },
                discardCloud: { (outgoing: IncomingVoIPCall) in
                    self.callLifecycleStore.retire(callID: outgoing.callID, uuid: outgoing.uuid)
                    IPhoneCloudCallSession.shared.endUnadoptedOutgoing(outgoing)
                }
            ) {
                // A bound/last-known Agent is enough to attempt dialing. Do not
                // make the command wait for a fresh /devices/status observation.
                if let target = self.cloudDialTarget(bound: boundAtStart) {
                    CloudAgentTargetStore.remember(target.agentID)
                    return try await self.cloudOutgoingStarter(number, target)
                }
                let queryGeneration = self.cloudStatusRefreshGeneration
                let status: CloudAgentStatus
                do {
                    status = try await self.cloudStatusFetcher()
                } catch {
                    if self.outgoingAttemptID == attempt, !Task.isCancelled,
                       queryGeneration == self.cloudStatusRefreshGeneration {
                        self.cloudStatusError = error.localizedDescription
                        // Keep the previous snapshot; only the attempt itself may
                        // report that the selected target is unreachable.
                    }
                    throw error
                }
                guard self.outgoingAttemptID == attempt, !Task.isCancelled else { throw CancellationError() }
                self.cloudAgentStatus = status
                self.cloudAgentDirectory = status
                self.cloudStatusError = nil
                self.lastCloudStatusReceivedAt = self.cloudStatusNow()
                self.lastCloudStatusRefresh = self.cloudStatusNow()
                guard let target = self.cloudDialTarget(bound: boundAtStart)
                    ?? (try? self.cloudTarget(status: status, bound: boundAtStart,
                                             requireOnline: false)) else {
                    throw CloudAgentRoutingError.unavailable
                }
                CloudAgentTargetStore.remember(target.agentID)
                return try await self.cloudOutgoingStarter(number, target)
            }

            switch routeResult {
            case .vowlan:
                guard let (vowlanAPI, pcmRoute) = vowlanRoute else {
                    throw CloudCommandError.unavailable
                }
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            case let .cloud(outgoing):
                guard applyCallLifecycle(CallLifecycleEvent(
                    callID: outgoing.callID, callUUID: outgoing.uuid,
                    generation: outgoing.generation, state: .connecting, source: .callKit,
                    timestamp: Date(), traceID: "callkit-start-\(outgoing.uuid.uuidString.lowercased())",
                    failure: nil
                )) else {
                    IPhoneCloudCallSession.shared.endUnadoptedOutgoing(outgoing)
                    return
                }
                try await IPhoneCloudCallSession.shared.answer(outgoing)
                guard outgoingAttemptID == attempt, !Task.isCancelled,
                      !callLifecycleStore.suppressesPresentation(callID: outgoing.callID) else {
                    if IPhoneCloudCallSession.shared.call?.uuid == outgoing.uuid {
                        await IPhoneCloudCallSession.shared.end()
                    }
                    return
                }
                currentCallTransport = .cloud
                lockedCallTransport = LockedCallTransport(
                    transport: .cloud, generation: callLifecycleSnapshot.generation
                )
                remoteCall = CallRecord(
                    id: outgoing.callID, index: 0, direction: "outgoing", state: "dialing",
                    number: number, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false
                )
                pendingOutgoingCall = nil
                await startCallAudioIfReady()
            }
        } catch {
            guard outgoingAttemptID == attempt else { return }
            // A direct (CallKit-less) dial failure must not leave the in-app
            // pending call page or the system presentation behind.
            pendingOutgoingCall = nil
            if presentedDeviceCall == nil { callPresentationSurface = nil }
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        // CallKit can deliver an answer action while the cloud early-answer path
        // is still completing. A second local answer races the successful cloud
        // answer, gets HTTP 502, and makes CallKit finish the call.
        guard !callAnswerInFlight else { return }
        callAnswerInFlight = true
        defer { callAnswerInFlight = false }
        if IPhoneCloudCallSession.shared.answered || IPhoneCloudCallSession.shared.isPrepared
            || currentCallTransport == .cloud {
            currentCallTransport = .cloud
            updateRemoteCallState("active")
            callPresentationSurface = origin == .app ? .app : .system
            return
        }
        if let key = presentedDeviceCall, let route = deviceCallRouter.route(for: key),
           deviceCalls.latestEvent(for: key)?.state.isTerminal == false {
            try await callKitAnswer(uuid: route.systemUUID, origin: origin); return
        }
        let answeringCall = callLifecycleSnapshot
        let isCurrent = { [self] in
            let current = callLifecycleSnapshot
            return current.callID == answeringCall.callID && current.callUUID == answeringCall.callUUID
                && current.generation == answeringCall.generation
                && current.state.representsCall && current.state != .ending
        }
        beginCallTransitionProtection()
        // CallKit may already own the shared session at this point. Stopping the
        // ringtone must not setActive(false) or iOS deactivates CallKit audio
        // immediately after answer.
        audio.stopCallTone(deactivateSession: false)
        backgroundStandby.suspendForCall()
        audio.resetSpeakerPreferenceForNewCall()
        callPresentationSurface = origin == .app ? .app : .system
        if origin == .system { _ = IncomingCallPresentationRequest.consume() }
        do {
            if currentCallTransport == .bluetooth {
                try await vobleCalls.answer()
                guard isCurrent() else { throw CancellationError() }
                currentCallTransport = .bluetooth
                return
            }
            // App 内来电页不一定经过 CallKit push 回调；纯云端模式的
            // authoritative call 已经在 IPhoneCloudCallSession 中。回退到
            // currentIncomingPush 会让内页接听误走 VoWLAN/local。
            let pushedCall = callKit.currentIncomingPush
                ?? IPhoneCloudCallSession.shared.call
            if let pushedCall, pushedCall.isVirtual {
                try VirtualCallTTSController.shared.prepare(pushedCall)
                clearLockedTransport()
                updateRemoteCallState("active")
                return
            }
            let cloudMediaEnabled = CloudModePreference.isEnabled()
            let selectedMode = ConnectionModePreference.selected()
            // Do not probe VoWLAN from an explicit cloud answer. A local probe
            // timeout used to consume the answer path before any cloud request.
            var vowlanRoute: (AirSIMAPI, PCMRoute)? =
                selectedMode == .cloud ? nil : await readyVoWLANRoute()
            // APNs normally carries a cloud media URL. That must not make the
            // CallKit answer skip VoWLAN discovery: answering from the system
            // UI can happen before Bonjour/Tailscale has restored the route,
            // while the in-app answer button is pressed later. Wait for the
            // local route in every non-cloud mode before choosing media.
            if vowlanRoute == nil, selectedMode != .cloud {
                vowlanRoute = await waitForLocalIncomingRoute()
            }
            guard isCurrent() else { throw CancellationError() }
            let transport = CallTransportPolicy.preferred(
                mode: selectedMode,
                vowlanReady: vowlanRoute != nil,
                cloudMediaAvailable: pushedCall?.authenticatedMediaURL != nil,
                cloudMediaEnabled: cloudMediaEnabled
            )
            switch transport {
            case .vowlan:
                guard let (vowlanAPI, pcmRoute) = vowlanRoute else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try audio.prepareForCallKit()
                try await vowlanAPI.answerCall(callID: localAPICallID)
                guard isCurrent() else { throw CancellationError() }
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            case .bluetooth:
                guard vobleCalls.currentIdentity != nil else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try await vobleCalls.answer()
                guard isCurrent() else { throw CancellationError() }
                currentCallTransport = .bluetooth
            case .cloud:
                guard let pushedCall else { throw CallKitBridgeError.noReachableTransport }
                try await IPhoneCloudCallSession.shared.answer(pushedCall)
                guard isCurrent() else { throw CancellationError() }
                currentLocalAPI = nil
                currentPCMRoute = nil
                currentCallTransport = .cloud
                lockedCallTransport = LockedCallTransport(
                    transport: .cloud, generation: callLifecycleSnapshot.generation
                )
                await startCallAudioIfReady()
            case nil:
                if !cloudMediaEnabled,
                   pushedCall?.authenticatedMediaURL != nil {
                    throw CallKitBridgeError.cloudMediaDisabled
                }
                throw CallKitBridgeError.noReachableTransport
            }
            guard isCurrent() else { throw CancellationError() }
            await CallAnswerCompletionCoordinator.complete(
                transport: currentCallTransport,
                confirmActive: {
                    self.applyCurrentCallIntent(
                        .active,
                        source: origin == .app ? .app : .callKit
                    )
                    self.updateRemoteCallState("active")
                },
                startAudio: { await self.startCallAudioIfReady() }
            )
        } catch {
            if isCurrent() || !callLifecycleSnapshot.state.representsCall { backgroundStandby.resumeAfterCall() }
            throw error
        }
    }

    func callKitEnd() async throws {
        if let key = presentedDeviceCall, let route = deviceCallRouter.route(for: key) {
            try await callKitEnd(uuid: route.systemUUID); return
        }
        outgoingAttemptID = UUID()
        beginCallTransitionProtection()
        audio.stopCallTone()
        let wasRinging = callLifecycleSnapshot.state == .ringing
        let pushedCall = callKit.currentIncomingPush
        let endRoute = CallKitEndDecision.route(
            transport: currentCallTransport,
            cloudSessionPrepared: IPhoneCloudCallSession.shared.isPrepared,
            hasIncomingPush: pushedCall != nil,
            systemCallAnswered: callKit.currentCallIsAnswered,
            activeIncomingRinging: activeCall?.direction == "incoming"
                && ["incoming", "waiting"].contains(activeCall?.state ?? "")
        )
        if currentCallTransport == .bluetooth {
            try await vobleCalls.end(rejectIfRinging: wasRinging)
            return
        }
        if VirtualCallTTSController.shared.isPrepared || callKit.currentIncomingPush?.isVirtual == true {
            VirtualCallTTSController.shared.stop()
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .cloudReject, let pushedCall {
            try await IPhoneCloudCallSession.shared.reject(pushedCall)
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .cloudEnd {
            await IPhoneCloudCallSession.shared.end()
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .vowlan,
           case .unavailable = vowlan.availability {
            // 三星端在热点接口消失时直接通过 Telecom 结束所属通话；这里让
            // CallKit 事务立即成功，避免因已断开的控制 socket 把系统界面卡住。
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .localReject {
            do {
                guard let localAPI = localCallControlAPI else {
                    throw CallKitBridgeError.noReachableTransport
                }
                _ = try await localAPI.rejectCall(callID: localAPICallID)
            } catch {
                guard let pushedCall else { throw error }
                try await IPhoneCloudCallSession.shared.reject(pushedCall)
            }
        } else {
            guard let localAPI = localCallControlAPI else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await localAPI.hangupCall(callID: localAPICallID)
        }
    }

    func callKitSetMuted(_ muted: Bool) async {
        isMuted = muted
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.setMuted(muted)
            errorMessage = nil
            return
        }
        audio.setMuted(muted)
        IPhoneCloudCallSession.shared.setMuted(muted)
        if currentCallTransport == .bluetooth {
            vobleCalls.setMuted(muted)
            errorMessage = nil
            return
        }
        // CallKit 的静音动作直接作用于本地 PCM 编码器；模块 AT+CMUT 失败不应影响双向音频。
        if currentCallTransport != .cloud {
            if let localAPI = reachableLocalAPI {
                Task { try? await localAPI.setAudioMuted(muted) }
            }
        }
        errorMessage = nil
    }

    func callKitPlayDTMF(_ digits: String) async throws {
        if VirtualCallTTSController.shared.isPrepared { return }
        if currentCallTransport == .bluetooth {
            try await vobleCalls.sendDTMF(digits)
            return
        }
        for digit in digits where "0123456789*#".contains(digit) {
            if currentCallTransport == .cloud {
                guard let call = IPhoneCloudCallSession.shared.call else { throw CloudCommandError.unavailable }
                try await VoIPPushController.shared.sendCloudDTMF(String(digit), call: call)
            } else {
                guard let localAPI = reachableLocalAPI else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try await localAPI.sendDTMF(String(digit))
            }
        }
    }

    func callKitAudioSessionDidActivate() async {
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.start()
            return
        }
        if currentCallTransport == .bluetooth {
            vobleCalls.setCallKitAudioActive(true)
            return
        }
        await startCallAudioIfReady()
    }

    func callKitAudioSessionDidDeactivate() {
        localAudioStartup.cancel()
        beginCallTransitionProtection()
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.stop()
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .bluetooth {
            vobleCalls.setCallKitAudioActive(false)
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            IPhoneCloudCallSession.shared.stopAudio()
            return
        }
        audio.deactivate()
        audioWarmupCallID = nil
        backgroundStandby.resumeAfterCall()
    }

    func callKitProviderDidReset() async {
        localAudioStartup.cancel()
        beginCallTransitionProtection()
        if vobleCalls.currentIdentity != nil {
            vobleCalls.setCallKitAudioActive(false)
        }
        // CXProvider reset 只代表系统通话界面失效，绝不等于用户挂断真实模块通话。
        // 清理本地音频后交给下一轮状态同步按 App 内通话模式自动恢复。
        let wasVirtual = VirtualCallTTSController.shared.isPrepared
        if wasVirtual {
            VirtualCallTTSController.shared.stop()
        } else if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            IPhoneCloudCallSession.shared.stopAudio()
        } else {
            audio.deactivate()
        }
        if !callLifecycleSnapshot.state.representsCall { backgroundStandby.resumeAfterCall() }
    }

    func callKitDidFail(_ message: String) {
        outgoingAttemptID = UUID()
        errorMessage = message
        pendingOutgoingCall = nil
        guard callLifecycleSnapshot.state == .ending,
              let callID = callLifecycleSnapshot.callID,
              let callUUID = callLifecycleSnapshot.callUUID else { return }
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: callID, callUUID: callUUID,
            generation: callLifecycleSnapshot.generation,
            state: .failed, source: .callKit, timestamp: Date(),
            traceID: "callkit-failure-\(UUID().uuidString.lowercased())",
            failure: message
        ))
    }

    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall) {
        if deviceCallRouter.contains(uuid: call.uuid) { return }
        guard deviceCalls.active == nil, deviceCallContext.admissionReservation == nil,
              !ownsLocalCallPresentation else { return }
        guard !callLifecycleStore.suppressesPresentation(callID: call.callID) else { return }
        if ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected()).startsVoWLAN {
            vowlan.startBrowsing()
            Task { await vowlan.probeNow() }
        }
        guard applyCallLifecycle(CallLifecycleEvent(
            callID: call.callID, callUUID: call.uuid, generation: call.generation,
            state: .ringing, source: .relay, timestamp: Date(),
            traceID: "pushkit-\(call.uuid.uuidString.lowercased())", failure: nil
        )) else { return }
        pushedCallIdentity = call
        remoteCall = Self.remoteCallRecord(from: call, state: "incoming")
        // 后台 PushKit 来电由系统界面接管；只有 App 本来就在前台时才准备 App 内来电页。
        callPresentationSurface = appIsActive ? .app : .system
    }

    func callKitCallDidEnd() {
        // Watch has taken this exact call's PCM, not a different default phone.
        // Keep source ownership for B-call reminders and scoped Watch end actions.
        if WatchCallCoordinator.shared.ownsMedia(callID: callLifecycleSnapshot.callID),
           deviceCalls.active != nil {
            audio.deactivate()
            return
        }
        outgoingAttemptID = UUID()
        // 远端挂断、系统通话页挂断以及 Provider 主动结束都会走这里。
        // Agent 已拥有唯一的通话结束媒体清理权；App 不再重复关闭 Audio Host。
        beginCallTransitionProtection()
        if vobleCalls.currentIdentity != nil {
            vobleCalls.setCallKitAudioActive(false)
        }
        // CallKit 本地 UI 已结束不等于模块已挂机；最终 ended/failed 只能由 Agent/Relay 回执推进。
        applyCurrentCallIntent(.ending, source: .callKit)
        remoteCall = nil
        pendingOutgoingCall = nil
        callPresentationSurface = nil
        clearLockedTransport()
        cloudCallAudioState = .idle
        IPhoneCloudCallSession.shared.stop()
        VirtualCallTTSController.shared.stop()
        backgroundStandby.resumeAfterCall()
    }
}
