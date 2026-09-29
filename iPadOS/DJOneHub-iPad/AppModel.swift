import Foundation

enum AppRefreshPolicy {
    static func shouldRefreshSupplementalState(appIsActive: Bool) -> Bool { appIsActive }
}

enum CallPresentationSurface: Equatable, Sendable {
    case system
    case app
}

enum CallPresentationPolicy {
    static func inAppCall(
        surface: CallPresentationSurface?,
        local: CallRecord?,
        remote: CallRecord?,
        pending: CallRecord? = nil
    ) -> CallRecord? {
        guard surface == .app else { return nil }
        return local ?? remote ?? pending
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
        transport == .moduleLocal || transport == .vowlan
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

enum LocalControlReachability {
    static func moduleLocal(
        isOnline: Bool,
        isReconnecting: Bool,
        lastSuccessfulRoute: LocalAgentRoute?
    ) -> Bool {
        guard isOnline, !isReconnecting, let lastSuccessfulRoute else { return false }
        if case .moduleLocal = lastSuccessfulRoute { return true }
        return false
    }
}

enum AgentEventPollingPolicy {
    static func timeout(hasActiveCall: Bool) -> TimeInterval {
        hasActiveCall ? 3 : 15
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
    @Published private(set) var remoteCall: CallRecord?
    @Published private(set) var pendingOutgoingCall: CallRecord?
    @Published private(set) var callPresentationSurface: CallPresentationSurface?
    @Published private(set) var cloudCallAudioState: CloudCallAudioState = .idle
    @Published private(set) var callLifecycleSnapshot: CallLifecycleSnapshot = .idle

    let api: DJOneHubAPI
    let contacts = ContactStore()
    let audio = AudioSessionController()
    let callKit = CallKitController.shared
    let backgroundStandby = BackgroundStandbyController()
    let vowlan = VoWLANController()
    let incomingNotifier = IncomingCallNotifier()
    let incomingSMSNotifier = IncomingSMSNotifier()
    let liveActivity = LiveActivityController()

    private let historyStore = LocalHistoryStore()

    private var pollingTask: Task<Void, Never>?
    private var moduleMetadataTask: Task<Void, Never>?
    private var startingCallAudio = false
    private var currentCallTransport: CallTransport?
    private var lockedCallTransport: LockedCallTransport?
    private var currentLocalAPI: DJOneHubAPI?
    private var currentPCMRoute: PCMRoute?
    private var lastSuccessfulLocalAPI: DJOneHubAPI?
    private var callLifecycleStore = CallLifecycleStore()
    private var appIsActive = true
    private var eventRevision: UInt64 = AgentEventCursor.initial
    private var smsRevision: UInt64 = 0
    private var eventStreamSupported: Bool?
    private var pollingGeneration = 0
    private var hasStarted = false
    private var consecutivePollFailures = 0
    private var callTransitionProtectedUntil = Date.distantPast
    private var nextAudioDiagnosticRefresh = Date.distantPast
    private var nextModuleMetadataRefresh = Date.distantPast
    private var audioWarmupCallID: String?
    private var lowPowerModeEnabled = true
    private let backgroundStandbyKey = "djonehub.background-standby-enabled"
    private let lowPowerModeKey = "djonehub.low-power-mode-enabled"
    private let liveActivityKey = "djonehub.live-activity-enabled"
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
        audio.active || cloudCallAudioState.isConnected || VirtualCallTTSController.shared.isPrepared
    }

    var callUsesVoWLAN: Bool { currentCallTransport == .vowlan }

    var dialPadTransportPresentation: DialPadTransportPresentation? {
        DialPadTransportPresentation.make(
            vowlanOnline: vowlan.availability.isOnlineForDisplay,
            moduleLocalReachable: false,
            cloudOnline: CloudModePreference.isEnabled()
                && (cloudAgentStatus?.cloudOnline == true || connectionSummary == .cloudOnly)
        )
    }

    /// 拨号页不能只依赖 `isOnline`：该字段代表 USB 本地控制链路，模块仅通过
    /// Relay 保持心跳时会刻意为 false。云端模式开启且心跳新鲜时，同样允许
    /// 用户发起拨号，实际执行仍会在 CallKit action 中再次鉴权和确认状态。
    var canStartOutgoingCommand: Bool {
        OutgoingCommandAvailability.isAvailable(
            localControlReachable: vowlan.availability.allowsCallAttempt,
            cloudModeEnabled: CloudModePreference.isEnabled(),
            cloudHeartbeatFresh: cloudAgentStatus?.cloudOnline == true || connectionSummary == .cloudOnly
        )
    }

    var callAudioStatusText: String {
        switch cloudCallAudioState {
        case .idle:
            return audio.active ? "语音链路已连接" : "正在建立语音链路"
        case let .connecting(attempt, maximum):
            return "正在重试云端语音 \(attempt)/\(maximum)"
        case .connected:
            return "云端语音已连接"
        case let .failed(message):
            return message
        }
    }

    init(api: DJOneHubAPI = DJOneHubAPI()) {
        self.api = api
        callKit.handler = self
        WatchCallCoordinator.shared.configure(model: self)
        WatchCallCoordinator.shared.start()
        IPhoneCloudCallSession.shared.onAudioStateChange = { [weak self] state in
            self?.cloudCallAudioState = state
            if state.isConnected { self?.audio.retryRequestedSpeakerRoute() }
        }
        IPhoneCloudCallSession.shared.onLifecycleEvent = { [weak self] event in
            guard let self else { return }
            guard self.applyCallLifecycle(event) else { return }
            if event.state == .active {
                self.callKit.reportCurrentOutgoingConnected()
                self.updateRemoteCallState("active")
                Task { @MainActor [weak self] in await self?.startCallAudioIfReady() }
            } else if event.state.isTerminal {
                self.callPresentationSurface = nil
            }
        }
        vowlan.onAvailabilityChange = { [weak self] availability in
            guard let self else { return }
            if case let .verified(endpoint, _) = availability,
               let credential = VoWLANCredentialStore.load() {
                let vowlanAPI = DJOneHubAPI(route: .vowlan(
                    endpoint: endpoint,
                    credential: credential
                ))
                Task {
                    await VoIPPushController.shared.syncRegistration(with: vowlanAPI)
                }
            }
            guard self.currentCallTransport == .vowlan,
                  case .unavailable = availability,
                  self.callLifecycleSnapshot.state.representsCall else { return }
            Task { @MainActor [weak self] in await self?.endVoWLANCallAfterPathLoss() }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        vowlan.startBrowsing()
        incomingNotifier.requestAuthorization()
        let storedValue = UserDefaults.standard.object(forKey: backgroundStandbyKey) as? Bool
        let storedLowPowerValue = UserDefaults.standard.object(forKey: lowPowerModeKey) as? Bool
        let storedLiveActivityValue = UserDefaults.standard.object(forKey: liveActivityKey) as? Bool
        lowPowerModeEnabled = storedLowPowerValue ?? true
        liveActivity.setEnabled(storedLiveActivityValue ?? true)
        backgroundStandby.setEnabled(storedValue ?? true)
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
        vowlan.restartBrowsing()
        Task { await vowlan.probeNow() }
        eventStreamSupported = nil
        consecutivePollFailures = 0
        isReconnecting = false
        backgroundStandby.setApplicationIsBackground(false)
        guard hasStarted else {
            start()
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
        backgroundStandby.setApplicationIsBackground(true)
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        restartPolling()
    }

    func setBackgroundStandbyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: backgroundStandbyKey)
        backgroundStandby.setEnabled(enabled)
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: lowPowerModeKey)
        lowPowerModeEnabled = enabled
        // 立即重建轮询任务，让用户切换后无需等待旧睡眠周期结束。
        if hasStarted { restartPolling() }
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: liveActivityKey)
        liveActivity.setEnabled(enabled)
    }

    private func restartPolling() {
        pollingGeneration &+= 1
        let generation = pollingGeneration
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(generation: generation)
                guard let delay = self?.nextPollingDelay else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// 模块在线时与其 1 秒 AT 轮询对齐；离线后退避，避免断开模块时持续唤醒手机和 USB 栈。
    private var nextPollingDelay: TimeInterval {
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
    }

    private func poll(generation: Int) async {
        do {
            let result = try await nextAgentEvent()
            let status = result.call
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            let previousCall = activeCall
            let history = await mergeCallHistory(status.history ?? [])
            let confirmedEndedCall = previousCall.flatMap { previous in
                status.history?.first { $0.id == previous.id && $0.endedAt != nil }
            }
            let acceptedActiveLifecycle: Bool
            if let active = status.active {
                acceptedActiveLifecycle = applyAgentCallRecord(active)
            } else if let ended = confirmedEndedCall {
                acceptedActiveLifecycle = false
                _ = applyAgentCallRecord(ended, forcedState: .ended)
            } else {
                acceptedActiveLifecycle = false
            }
            if let active = status.active {
                // Agent 状态与统一生命周期真正汇合后才能撤掉临时呼出页。
                // 否则上一通 ending 的晚到事件会让用户在几秒后掉回拨号页。
                if acceptedActiveLifecycle || callLifecycleSnapshot.callID == active.id {
                    pendingOutgoingCall = nil
                }
                if activeCall != active { activeCall = active }
            } else if confirmedEndedCall != nil, activeCall != nil {
                activeCall = nil
            }
            if let active = status.active {
                if remoteCall?.id == active.id { remoteCall = nil }
                if callPresentationSurface == nil {
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
            // HTTP 已成功返回就说明 USB 模块代理在线。last_poll_error 只是模块内部 AT+CLCC
            // 的最近轮询结果，通话建立期间可能短暂非空，不能据此把整条 USB 链路判为离线。
            if !isOnline { isOnline = true }
            cloudAgentStatus = nil
            updateLocalConnectionSummary(cellularState: modemStatus?.cellularState)
            // PushKit token 必须写入当前真正可达的 Agent。热点场景不能再固定访问 USB 地址。
            await VoIPPushController.shared.syncRegistration(with: result.api)
            if AppRefreshPolicy.shouldRefreshSupplementalState(appIsActive: appIsActive) {
                scheduleModuleMetadataRefresh(generation: generation, api: result.api)
            }
            let lifecycleCall = lifecycleRecord(from: status.active ?? previousCall)
            let systemCall = status.active
            let callerName = (systemCall ?? lifecycleCall).map { contacts.displayName(for: $0.number) }
            // 必须先请求 CallKit，再决定是否发送本地通知。否则后台来电会同时出现
            // 系统通话界面和一条带接听按钮的通知；CallKit 上报失败时下一轮再自动降级。
            if !WatchCallCoordinator.shared.ownsMedia(callID: systemCall?.id) {
                callKit.synchronize(
                    // CallKit 要直接消费 Agent 的事实状态。即使 App 展示层正在处理
                    // 乱序生命周期，也不能把真实 active 误传成 nil 并提前结束系统通话。
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
            await liveActivity.update(
                call: lifecycleCall,
                callerName: callerName,
                moduleOnline: true,
                transport: liveActivityTransport,
                radio: modemStatus,
                appIsActive: appIsActive
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

            // 已完成首次向导的旧用户也要获得模块更新；仅在无通话时后台检查，避免中断基带媒体。
            // AirSIM 不内置、也不自动刷写 QDC507 Agent。

            // 接通期间持续确认本地音频仍在工作。CallKit 或系统音频服务重置后，
            // 即使模块状态没有发生变化，下一轮也必须能够重建网络 PCM。
            if status.active?.state == "active" {
                await startCallAudioIfReady()
            } else if status.active == nil, previousCall != nil {
                // 远端挂断不会经过 App 的挂断按钮；同样开启切换保护，避免媒体路由
                // 退出时的短暂 ECM/AT 抖动被误报为整台模块离线。
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
                await loadMessagesFromAgent(silently: true, notifyIfBackground: true)
            }
        } catch {
            guard !Task.isCancelled, generation == pollingGeneration else { return }
#if DEBUG
            print("[DJOneHub Poll] module status failed: \(error.localizedDescription)")
#endif
            consecutivePollFailures += 1
            isReconnecting = true
            let failedRouteName: String = {
                guard let route = lastSuccessfulLocalAPI?.route else { return "本地控制链路" }
                if case .vowlan = route { return "VoWLAN" }
                return "模块本地链路"
            }()
            connectionMessage = "正在重新连接\(failedRouteName)：\(error.localizedDescription)"

            // 一次长轮询中断不能代表 USB ECM 已离线。通话动作后的 8 秒保护期内
            // 保留最后一次在线状态；其后也必须连续失败三次并让独立 health 请求失败。
            guard ModuleConnectivityPolicy.shouldConfirmOffline(
                consecutiveFailures: consecutivePollFailures,
                now: Date(),
                protectedUntil: callTransitionProtectedUntil
            ) else { return }

            // 用最后实际成功的本地路线复核健康状态。VoWLAN 的长轮询偶发断开时，
            // 不能再转去探测 USB 默认地址并据此把三星 Agent 判为离线。
            let healthAPI = lastSuccessfulLocalAPI ?? verifiedVoWLANAPI()
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
                // 已建立的公网媒体会话本身就是独立的云端在线证据。接听时 USB/ECM
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
                    : "云端通话在线，USB ECM 正在重新连接"
                let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    appIsActive: appIsActive
                )
                return
            }
            if isOnline { isOnline = false }
            lastSuccessfulLocalAPI = nil
            audio.stopCallTone()
            let cloudStatus = CloudModePreference.isEnabled()
                ? (try? await VoIPPushController.shared.fetchCloudAgentStatus())
                : nil
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
                // USB 本地控制不可达不等于模块离线。Relay 心跳新鲜时保留灵动岛待机，
                // 来电仍可由 PushKit 唤醒并走公网 PCM。
                let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    appIsActive: appIsActive
                )
            } else {
                isReconnecting = false
                connectionMessage = "模块本地与云端均不可达：\(error.localizedDescription)"
                await liveActivity.markOffline(appIsActive: appIsActive)
            }
        }

    }

    private struct AgentPollResult {
        let call: CallStatus
        let smsChanged: Bool
        let api: DJOneHubAPI
    }

    private func nextAgentEvent() async throws -> AgentPollResult {
        guard let samsungAPI = verifiedVoWLANAPI() else {
            throw CallKitBridgeError.noReachableTransport
        }
        let pollingAPI = AgentPollingRouteSelector.select(
            primary: samsungAPI,
            lockedLocal: currentLocalAPI,
            transport: currentCallTransport
        )
        if eventStreamSupported != false {
            do {
                let event = try await pollingAPI.waitForAgentEvent(
                    after: eventRevision,
                    timeout: AgentEventPollingPolicy.timeout(hasActiveCall: callLifecycleSnapshot.state.representsCall)
                )
                eventStreamSupported = true
                let previousEventRevision = eventRevision
                eventRevision = AgentEventCursor.advanced(from: eventRevision, to: event.revision)
                let changed = event.smsRevision > smsRevision
                    || (event.revision < previousEventRevision && event.smsPending > 0)
                smsRevision = event.smsRevision
                return AgentPollResult(
                    call: event.call,
                    smsChanged: changed && event.smsPending > 0,
                    api: pollingAPI
                )
            } catch APIError.http(404, _) {
                // 0.3.18 等旧 Agent 没有统一事件接口；保留兼容轮询直到模块升级。
                eventStreamSupported = false
            }
        }
        return AgentPollResult(
            call: try await pollingAPI.callStatus(),
            smsChanged: false,
            api: pollingAPI
        )
    }

    private func verifiedVoWLANAPI() -> DJOneHubAPI? {
        guard vowlan.availability.isOnlineForDisplay,
              let endpoint = vowlan.availability.endpoint,
              let credential = VoWLANCredentialStore.load() else { return nil }
        return DJOneHubAPI(route: .vowlan(endpoint: endpoint, credential: credential))
    }

    private var moduleLocalIsReachable: Bool {
        false
    }

    private var reachableLocalAPI: DJOneHubAPI? {
        if let currentLocalAPI, AirSIMRoutePolicy.permits(currentLocalAPI.route) {
            return currentLocalAPI
        }
        guard isOnline, !isReconnecting else { return nil }
        guard let lastSuccessfulLocalAPI,
              AirSIMRoutePolicy.permits(lastSuccessfulLocalAPI.route) else { return nil }
        return lastSuccessfulLocalAPI
    }

    private var liveActivityTransport: DJOneHubCallActivityAttributes.ContentState.Transport? {
        switch currentCallTransport {
        case .vowlan: return .vowlan
        case .cloud: return .cloud
        case .moduleLocal: return .moduleLocal
        case nil: break
        }
        if let route = lastSuccessfulLocalAPI?.route {
            switch route {
            case .vowlan: return .vowlan
            case .moduleLocal: return .moduleLocal
            }
        }
        return connectionSummary == .cloudOnly ? .cloud : nil
    }

    private static func pcmRoute(for route: LocalAgentRoute) -> PCMRoute {
        switch route {
        case .moduleLocal:
            return .moduleLocal
        case let .vowlan(endpoint, credential):
            return .vowlan(endpoint: endpoint, credential: credential)
        }
    }

    /// 蜂窝状态和版本不必跟随每秒通话轮询；独立刷新避免慢 AT 状态接口拖住来电检测。
    private func scheduleModuleMetadataRefresh(generation: Int, api: DJOneHubAPI) {
        guard moduleMetadataTask == nil, Date() >= nextModuleMetadataRefresh else { return }
        nextModuleMetadataRefresh = Date().addingTimeInterval(10)
        moduleMetadataTask = Task { [weak self] in
            await self?.refreshModuleMetadata(generation: generation, api: api)
        }
    }

    private func refreshModuleMetadata(generation: Int, api: DJOneHubAPI) async {
        defer { moduleMetadataTask = nil }
        async let radioRequest = try? api.modemStatus()
        let radio = await radioRequest
        guard !Task.isCancelled, generation == pollingGeneration, isOnline, appIsActive else { return }
        if let radio, modemStatus != radio { modemStatus = radio }
        updateLocalConnectionSummary(cellularState: radio?.cellularState ?? modemStatus?.cellularState)
        let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
        await liveActivity.update(
            call: lifecycleCall,
            callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
            moduleOnline: true,
            transport: liveActivityTransport,
            radio: modemStatus,
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
                ? "USB ECM 已连接 · \(detail!)"
                : "USB ECM 已连接，蜂窝网络正在恢复"
        case .cloudOnly, .offline:
            break
        }
    }

    private func cloudConnectionMessage(for status: CloudAgentStatus) -> String {
        let local = "USB ECM 本地连接中断，模块云端在线"
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
        debugDialLog("开始提交 CallKit 系统呼出")
        await perform {
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
        beginCallTransitionProtection()
        audio.stopCallTone()
        callPresentationSurface = .app
        applyCurrentCallIntent(.connecting, source: .app)
        if callKit.managesCurrentCall {
            await perform {
                do {
                    try await self.callKit.answerCurrentCall(presentInApp: true)
                } catch CallKitBridgeError.staleSystemCall {
                    // 系统界面重建期间仍复用标准路线选择，不能回退到 USB 默认地址。
                    try await self.callKitAnswer(origin: .app)
                }
            }
        } else {
            await perform { try await self.callKitAnswer(origin: .app) }
        }
    }

    func presentCurrentCallInApp() {
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            remoteCall = Self.remoteCallRecord(from: incoming, state: "incoming")
        }
        guard callLifecycleSnapshot.state.representsCall else { return }
        _ = IncomingCallPresentationRequest.consume()
        callPresentationSurface = .app
    }

    /// 正常情况下系统接听会停留在 CallKit。若 iOS、普通 APNs 或用户手势实际把
    /// DJOneHub 拉到前台，则必须展示同一通电话，而不是让用户掉回拨号/设置页面。
    private func presentManagedCallAfterForegroundTransition() {
        guard appIsActive,
              CallPresentationPolicy.shouldPresentWhenAppBecomesActive(
                  managesSystemCall: callKit.managesCurrentCall,
                  hasLocalCall: lifecycleRecord(from: activeCall) != nil,
                  hasRemoteCall: lifecycleRecord(from: remoteCall) != nil
              ) else { return }
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            remoteCall = Self.remoteCallRecord(
                from: incoming,
                state: callKit.currentCallIsAnswered ? "active" : "incoming"
            )
        } else if callKit.currentCallIsAnswered {
            updateRemoteCallState("active")
        }
        callPresentationSurface = .app
    }

    func reject() async {
        beginCallTransitionProtection()
        audio.stopCallTone()
        applyCurrentCallIntent(.ending, source: .app)
        if callKit.managesCurrentCall {
            await perform {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.rejectUsingAvailableTransport()
                }
            }
        } else {
            await perform { try await self.rejectUsingAvailableTransport() }
        }
    }

    func hangup() async {
        beginCallTransitionProtection()
        audio.stopCallTone()
        applyCurrentCallIntent(.ending, source: .app)
        if callKit.managesCurrentCall {
            await perform {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.hangupUsingAvailableTransport()
                }
            }
        } else {
            await perform { try await self.hangupUsingAvailableTransport() }
        }
    }

    private func rejectUsingAvailableTransport() async throws {
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        if let localAPI = reachableLocalAPI {
            _ = try await localAPI.rejectCall()
            return
        }
        if let pushedCall = callKit.currentIncomingPush,
           pushedCall.authenticatedMediaURL != nil {
            try await IPhoneCloudCallSession.shared.reject(pushedCall)
            return
        }
        throw CallKitBridgeError.noReachableTransport
    }

    private func hangupUsingAvailableTransport() async throws {
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.hangupCall()
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
        if currentCallTransport == .cloud {
            try await VoIPPushController.shared.sendCloudDTMF(digit)
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.sendDTMF(digit)
    }

    func toggleMute() async {
        let target = !isMuted
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
        // QDC507 部分固件不实现 AT+CMUT；本地 PCM 已经是移动端的权威静音状态，
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
        print("[DJOneHub Dial] \(message)")
#endif
    }

    func sendSMS(to phone: String, content: String) async -> Bool {
        let target = Self.validatedNumber(phone)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !body.isEmpty, body.count <= 2_000 else { return false }
        do {
            let localAPI = verifiedVoWLANAPI()
            let localReachable = localAPI != nil && isOnline && !isReconnecting
            let result: SMSSendResult
            if localReachable {
                result = try await localAPI!.sendSMS(to: target, message: body)
            } else if CloudModePreference.isEnabled() {
                let status: CloudAgentStatus
                if let cloudAgentStatus {
                    status = cloudAgentStatus
                } else {
                    status = try await VoIPPushController.shared.fetchCloudAgentStatus()
                }
                guard status.cloudOnline else { throw CloudCommandError.unavailable }
                result = try await VoIPPushController.shared.sendCloudSMS(to: target, message: body)
            } else {
                throw CloudCommandError.cloudModeDisabled
            }
            if result.sent {
                saveSentMessage(recipient: target, content: body)
            }
            if localReachable { await refreshMessages(silently: true) }
            return result.sent
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshMessages(silently: Bool = false) async {
        do {
            guard let samsungAPI = verifiedVoWLANAPI() else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await samsungAPI.refreshSMS()
            await loadMessagesFromAgent(silently: silently)
            if !silently { errorMessage = nil }
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }

    /// URC 已经让 Agent 读取了单条短信；事件路径只取交付队列，不再触发全量 CMGL。
    func loadMessagesFromAgent(
        silently: Bool = false,
        notifyIfBackground: Bool = false
    ) async {
        do {
            guard let samsungAPI = verifiedVoWLANAPI() else {
                throw CallKitBridgeError.noReachableTransport
            }
            let remoteMessages = try await samsungAPI.messages()
            let existingIDs = Set(messages.map(\.id))
            let newlyReceived = remoteMessages
                .filter { !existingIDs.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
            let mergedMessages = await mergeMessages(remoteMessages)
            if messages != mergedMessages { messages = mergedMessages }
            if notifyIfBackground {
                for message in newlyReceived.suffix(3) {
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
        guard historyStore.saveMessages([]) else {
            errorMessage = "无法清空本机短信，请稍后重试"
            return
        }
        messages = []
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
            messages = normalizedMessages(Array(messagesByID.values))
        }
    }

    /// 远端列表可能因模块重启、自动清理或离线而变短，因此只做并集，不删除手机副本。
    private func mergeCallHistory(_ remote: [CallRecord]) async -> [CallRecord] {
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
            if let samsungAPI = verifiedVoWLANAPI() {
                try? await samsungAPI.acknowledgeCallHistory(ids: acknowledgedIDs)
            }
        }
        return merged
    }

    private func mergeMessages(_ remote: [SMSMessage]) async -> [SMSMessage] {
        var byID: [String: SMSMessage] = [:]
        for message in messages { byID[message.id] = message }
        for var message in remote {
            // 旧版模块没有 delivery_id 时保留手机已有标识，避免新旧版本来回覆盖。
            if message.deliveryID == nil { message.deliveryID = byID[message.id]?.deliveryID }
            byID[message.id] = message
        }
        let merged = normalizedMessages(Array(byID.values))
        if !remote.isEmpty, historyStore.saveMessages(merged) {
            let persistedIDs = Set(merged.map(\.id))
            let acknowledgedIDs = remote
                .filter { persistedIDs.contains($0.id) }
                .compactMap(\.deliveryID)
            if let samsungAPI = verifiedVoWLANAPI() {
                try? await samsungAPI.acknowledgeMessages(ids: acknowledgedIDs)
            }
        }
        return merged
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
        Array(records
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxMessageCount))
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startCallAudioIfReady() async {
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
        guard callLifecycleSnapshot.state == .active, !audio.active, !startingCallAudio else { return }
        startingCallAudio = true
        defer { startingCallAudio = false }
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
                activatePhoneAudio: { [audio] in
                    await audio.activateForCall(route: pcmRoute, sessionAlreadyActive: managedByCallKit)
                },
                registerAgentAudio: {
                    try await CallAudioRegistrationCoordinator.register(service: localAPI)
                },
                rollbackPhoneAudio: { [audio] in
                    audio.deactivate()
                    try? await localAPI.setAudioHostEnabled(false)
                }
            )
            guard outcome == .started else {
                backgroundStandby.resumeAfterCall()
                return
            }
            if currentCallTransport == nil {
                let transport: CallTransport
                switch localAPI.route {
                case .moduleLocal: transport = .moduleLocal
                case .vowlan: transport = .vowlan
                }
                lockLocalTransport(transport, api: localAPI, pcmRoute: pcmRoute)
            }
        } catch {
            audio.deactivate()
            if let localAPI = reachableLocalAPI {
                try? await localAPI.setAudioHostEnabled(false)
            }
            backgroundStandby.resumeAfterCall()
            errorMessage = "无法登记通话音频：\(error.localizedDescription)"
            return
        }
    }

    func readyVoWLANRoute() async -> (DJOneHubAPI, PCMRoute)? {
        vowlan.startBrowsing()
        await vowlan.probeNow()
        if vowlan.availability.isReady(),
           let endpoint = vowlan.availability.endpoint,
           let credential = VoWLANCredentialStore.load() {
            return (
                DJOneHubAPI(route: .vowlan(endpoint: endpoint, credential: credential)),
                .vowlan(endpoint: endpoint, credential: credential)
            )
        }
        // PushKit 可在后台先于 Bonjour 浏览器恢复。最近一次成功轮询若明确来自
        // VoWLAN，就复用同一已鉴权端点；绝不能把通用 isOnline 误当成 USB ECM。
        guard isOnline, !isReconnecting, let cached = lastSuccessfulLocalAPI,
              case let .vowlan(endpoint, credential) = cached.route else { return nil }
        return (cached, .vowlan(endpoint: endpoint, credential: credential))
    }

    private func lockLocalTransport(
        _ transport: CallTransport,
        api: DJOneHubAPI,
        pcmRoute: PCMRoute
    ) {
        currentCallTransport = transport
        currentLocalAPI = api
        currentPCMRoute = pcmRoute
        lockedCallTransport = LockedCallTransport(
            transport: transport,
            generation: callLifecycleSnapshot.generation
        )
        // 取消仍绑定旧 USB 路由的长轮询，让 active 状态立即从 VoWLAN 返回。
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
        try? await localAPI?.hangupCall()
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

    @discardableResult
    private func applyCallLifecycle(_ event: CallLifecycleEvent) -> Bool {
        guard callLifecycleStore.apply(event) else { return false }
        callLifecycleSnapshot = callLifecycleStore.snapshot
        return true
    }

    private func applyCurrentCallIntent(_ state: CallLifecycleState, source: CallLifecycleSource) {
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
    private func applyAgentCallRecord(
        _ call: CallRecord,
        forcedState: CallLifecycleState? = nil
    ) -> Bool {
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
        return applyCallLifecycle(CallLifecycleEvent(
            callID: call.id,
            callUUID: callUUID,
            generation: generation,
            state: state,
            source: .agent,
            timestamp: call.updatedAt,
            traceID: "agent-poll-\(call.id)-\(generation)",
            failure: state == .failed ? "Agent 报告通话失败" : nil
        ))
    }

    private func lifecycleRecord(from record: CallRecord?) -> CallRecord? {
        guard let record,
              callLifecycleSnapshot.callID == record.id,
              callLifecycleSnapshot.state.representsCall else { return nil }
        return CallRecord(
            id: record.id,
            index: record.index,
            direction: record.direction,
            state: callLifecycleSnapshot.state.callRecordState,
            number: record.number,
            startedAt: record.startedAt,
            updatedAt: callLifecycleSnapshot.timestamp ?? record.updatedAt,
            endedAt: nil,
            missed: record.missed
        )
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

extension DJOneHubAPI: OutgoingCallServicing {}

protocol CallAudioRegistrationServicing: Sendable {
    func setAudioHostEnabled(_ enabled: Bool) async throws
    func callStatus() async throws -> CallStatus
}

extension DJOneHubAPI: CallAudioRegistrationServicing {}

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
        }
    }
}

enum LocalCallAudioStartupOutcome: Equatable, Sendable {
    case started
    case phoneAudioUnavailable
    case callNoLongerActive
    case temporarilyUnavailable
}

@MainActor
enum LocalCallAudioStartupCoordinator {
    static func start(
        activatePhoneAudio: () async -> Bool,
        registerAgentAudio: () async throws -> CallAudioRegistrationOutcome,
        rollbackPhoneAudio: () async -> Void
    ) async rethrows -> LocalCallAudioStartupOutcome {
        guard await activatePhoneAudio() else { return .phoneAudioUnavailable }
        do {
            switch try await registerAgentAudio() {
            case .registered:
                return .started
            case .callNoLongerActive:
                await rollbackPhoneAudio()
                return .callNoLongerActive
            case .temporarilyUnavailable:
                await rollbackPhoneAudio()
                return .temporarilyUnavailable
            }
        } catch {
            await rollbackPhoneAudio()
            throw error
        }
    }
}

enum OutgoingCommandAvailability {
    static func isAvailable(
        localControlReachable: Bool,
        cloudModeEnabled: Bool,
        cloudHeartbeatFresh: Bool
    ) -> Bool {
        localControlReachable || (cloudModeEnabled && cloudHeartbeatFresh)
    }
}

enum OutgoingCallCoordinator {
    static func start(number: String, service: any OutgoingCallServicing) async throws {
        try? await service.warmAudioHost()
        try await service.dial(number: number)
    }
}

enum AgentPollingRouteSelector {
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
    func callKitPrepareAudioSession() throws {
        try CallKitAudioPreparationCoordinator.prepare(
            suspendStandby: { backgroundStandby.suspendForCall() },
            configureCallAudio: { try audio.prepareForCallKit() },
            resumeStandby: { backgroundStandby.resumeAfterCall() }
        )
    }

    func callKitStart(number: String) async throws {
        beginCallTransitionProtection()
        if callPresentationSurface == nil { callPresentationSurface = .system }
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        do {
            if let (vowlanAPI, pcmRoute) = await readyVoWLANRoute() {
                try await OutgoingCallCoordinator.start(number: number, service: vowlanAPI)
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            } else if CloudModePreference.isEnabled() {
                let status: CloudAgentStatus
                if let cloudAgentStatus {
                    status = cloudAgentStatus
                } else {
                    status = try await VoIPPushController.shared.fetchCloudAgentStatus()
                }
                guard status.cloudOnline else { throw CloudCommandError.unavailable }
                let outgoing = try await VoIPPushController.shared.startCloudOutgoingCall(number: number)
                _ = applyCallLifecycle(CallLifecycleEvent(
                    callID: outgoing.callID, callUUID: outgoing.uuid,
                    generation: outgoing.generation, state: .connecting, source: .callKit,
                    timestamp: Date(), traceID: "callkit-start-\(outgoing.uuid.uuidString.lowercased())",
                    failure: nil
                ))
                try await IPhoneCloudCallSession.shared.answer(outgoing)
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
            } else {
                throw CloudCommandError.cloudModeDisabled
            }
        } catch {
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        beginCallTransitionProtection()
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        audio.resetSpeakerPreferenceForNewCall()
        callPresentationSurface = origin == .app ? .app : .system
        applyCurrentCallIntent(.connecting, source: origin == .app ? .app : .callKit)
        if origin == .system { _ = IncomingCallPresentationRequest.consume() }
        do {
            let pushedCall = callKit.currentIncomingPush
            if let pushedCall, pushedCall.isVirtual {
                try VirtualCallTTSController.shared.prepare(pushedCall)
                clearLockedTransport()
                updateRemoteCallState("active")
                return
            }
            let cloudMediaEnabled = CloudModePreference.isEnabled()
            let vowlanRoute = await readyVoWLANRoute()
            let moduleLocalReachable = false
            let transport = CallTransportPolicy.preferred(
                vowlanReady: vowlanRoute != nil,
                moduleLocalReachable: moduleLocalReachable,
                cloudMediaAvailable: pushedCall?.authenticatedMediaURL != nil,
                cloudMediaEnabled: cloudMediaEnabled
            )
            switch transport {
            case .vowlan:
                guard let (vowlanAPI, pcmRoute) = vowlanRoute else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try audio.prepareForCallKit()
                try await vowlanAPI.answerCall()
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            case .moduleLocal:
                throw CallKitBridgeError.noReachableTransport
            case .cloud:
                guard let pushedCall else { throw CallKitBridgeError.noReachableTransport }
                try await IPhoneCloudCallSession.shared.answer(pushedCall)
                currentLocalAPI = nil
                currentPCMRoute = nil
                currentCallTransport = .cloud
                lockedCallTransport = LockedCallTransport(
                    transport: .cloud, generation: callLifecycleSnapshot.generation
                )
                await startCallAudioIfReady()
            case nil:
                if !moduleLocalReachable,
                   !cloudMediaEnabled,
                   pushedCall?.authenticatedMediaURL != nil {
                    throw CallKitBridgeError.cloudMediaDisabled
                }
                throw CallKitBridgeError.noReachableTransport
            }
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
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitEnd() async throws {
        beginCallTransitionProtection()
        audio.stopCallTone()
        applyCurrentCallIntent(.ending, source: .callKit)
        if VirtualCallTTSController.shared.isPrepared || callKit.currentIncomingPush?.isVirtual == true {
            VirtualCallTTSController.shared.stop()
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
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
        if activeCall?.direction == "incoming", callLifecycleSnapshot.state == .ringing {
            do {
                guard let localAPI = reachableLocalAPI else {
                    throw CallKitBridgeError.noReachableTransport
                }
                _ = try await localAPI.rejectCall()
            } catch {
                guard let pushedCall = callKit.currentIncomingPush,
                      pushedCall.authenticatedMediaURL != nil else { throw error }
                try await IPhoneCloudCallSession.shared.reject(pushedCall)
            }
        } else {
            guard let localAPI = reachableLocalAPI else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await localAPI.hangupCall()
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
        for digit in digits where "0123456789*#".contains(digit) {
            if currentCallTransport == .cloud {
                try await VoIPPushController.shared.sendCloudDTMF(String(digit))
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
        await startCallAudioIfReady()
    }

    func callKitAudioSessionDidDeactivate() {
        beginCallTransitionProtection()
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.stop()
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
        beginCallTransitionProtection()
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
        vowlan.startBrowsing()
        Task { await vowlan.probeNow() }
        remoteCall = Self.remoteCallRecord(from: call, state: "incoming")
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: call.callID, callUUID: call.uuid, generation: call.generation,
            state: .ringing, source: .relay, timestamp: Date(),
            traceID: "pushkit-\(call.uuid.uuidString.lowercased())", failure: nil
        ))
        // 后台 PushKit 来电由系统界面接管；只有 App 本来就在前台时才准备 App 内来电页。
        callPresentationSurface = appIsActive ? .app : .system
    }

    func callKitCallDidEnd() {
        // 远端挂断、系统通话页挂断以及 Provider 主动结束都会走这里。
        // Agent 已拥有唯一的通话结束媒体清理权；App 不再重复关闭 Audio Host。
        beginCallTransitionProtection()
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

private enum ModuleSetupError: LocalizedError {
    case notReady(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case let .notReady(message): return message
        case .timeout: return "模块重启后未重新上线，请重新插拔 USB 线"
        }
    }
}
