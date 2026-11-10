import AVFoundation
import CallKit
import CryptoKit
import Foundation
import UIKit
import UserNotifications
import WidgetKit

enum BackgroundStandbySuspensionPolicy {
    static func shouldStopAudio(isAlreadySuspended: Bool) -> Bool {
        !isAlreadySuspended
    }

    /// CallKit owns the shared AVAudioSession while a system call is active.
    /// Deactivating it from the standby engine tears down CallKit audio and can
    /// end the call immediately after answer.
    static func shouldDeactivateSession(callKitAudioActive: Bool) -> Bool {
        !callKitAudioActive
    }

    static func shouldRunStandby(callKitAudioActive: Bool) -> Bool {
        !callKitAudioActive
    }
}

extension Notification.Name {
    static let airsimRemoteSMSReceived = Notification.Name("AirSIMRemoteSMSReceived")
    static let airsimOpenSMSConversation = Notification.Name("AirSIMOpenSMSConversation")
    static let airsimOpenIncomingCall = Notification.Name("AirSIMOpenIncomingCall")
    static let airsimOpenOtherAndroidCall = Notification.Name("AirSIMOpenOtherAndroidCall")
}

enum OtherAndroidCallPresentationRequest {
    private static let key = "airsim.pending-other-android-call"
    static func mark(_ info: [AnyHashable: Any], defaults: UserDefaults = .standard) {
        guard let identity = OtherDeviceCallReminder.key(from: info) else { return }
        defaults.set(["event": "other_android_incoming", "agent_id": identity.agentID,
            "call_id": identity.callID, "generation": String(identity.generation)], forKey: key)
    }
    static func consume(defaults: UserDefaults = .standard) -> [AnyHashable: Any]? {
        defer { defaults.removeObject(forKey: key) }
        return defaults.dictionary(forKey: key)
    }
}

/// 锁屏来电通知使用的稳定标识；动作不要求设备解锁，也不会强制打开 App 界面。
enum IncomingCallNotification {
    static let categoryIdentifier = "AIRSIM_INCOMING_CALL"
    static let mirrorCategoryIdentifier = "AIRSIM_INCOMING_CALL_MIRROR"
    static let answerActionIdentifier = "AIRSIM_ANSWER_CALL"
    static let rejectActionIdentifier = "AIRSIM_REJECT_CALL"
    static let callIDKey = "call_id"

    static func registerCategory() {
        let answer = UNNotificationAction(
            identifier: answerActionIdentifier,
            title: "接听",
            options: []
        )
        let reject = UNNotificationAction(
            identifier: rejectActionIdentifier,
            title: "拒绝",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [answer, reject],
            intentIdentifiers: [],
            options: []
        )
        let mirrorCategory = UNNotificationCategory(
            identifier: mirrorCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, mirrorCategory])
    }
}

enum IncomingCallPresentationRequest {
    static let key = "airsim.pending-in-app-call-presentation"

    static func markPending(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func consume(defaults: UserDefaults = .standard) -> Bool {
        let pending = defaults.bool(forKey: key)
        if pending { defaults.removeObject(forKey: key) }
        return pending
    }


    static func isPending(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// 通知点开后 SwiftUI 首屏可能尚未订阅事件；只保存发件人，不持久化短信正文。
enum IncomingSMSPresentationRequest {
    static let key = "airsim.pending-sms-sender"

    static func markPending(sender: String, defaults: UserDefaults = .standard) {
        defaults.set(sender, forKey: key)
    }

    static func consume(defaults: UserDefaults = .standard) -> String? {
        let sender = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        return sender
    }
}

/// 接收锁屏通知动作，并在系统授予的后台执行时间内直接控制模块通话。
@MainActor
final class AirSIMNotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let coldLaunchCallHandler = ColdLaunchCallKitHandler()

    /// AppModel has taken over CallKit actions; release the cold-launch browser so
    /// two VoWLAN controllers do not run concurrent Bonjour/network recovery loops.
    func releaseColdLaunchHandler() {
        coldLaunchCallHandler.stop()
    }
    private let historyStore = LocalHistoryStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        IncomingCallNotification.registerCategory()
        CrashDiagnosticsStore.shared.start()
        let policy = ConnectionModeRuntimePolicy(mode: ConnectionModePreference.selected())
        CallKitController.shared.setEnabled(policy.usesCallKit)
        if policy.usesCallKit, CallKitController.shared.handler == nil {
            CallKitController.shared.handler = coldLaunchCallHandler
        }
		// Watch token 与跨设备接听所有权必须在冷启动阶段就可接收，不能等待
		// SwiftUI 首屏 onAppear（锁屏 PushKit 唤醒时首屏可能永远不出现）。
		WatchCallCoordinator.shared.start()
        if CloudSignalingPreference.isEnabled() {
            VoIPPushController.shared.start()
            application.registerForRemoteNotifications()
        }
#if DEBUG
        print(!CloudSignalingPreference.isEnabled()
            ? "[AirSIM Local] 已跳过 APNs 与 PushKit 注册"
            : "[AirSIM APNs] 已启动普通通知与 PushKit 注册")
#endif
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 首次授权弹窗可能晚于 didFinishLaunching 返回；回到前台时重新登记是幂等的。
        guard CloudSignalingPreference.isEnabled() else { return }
        VoIPPushController.shared.start()
        application.registerForRemoteNotifications()
        Task { await VoIPPushController.shared.syncRegistration() }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard CloudSignalingPreference.isEnabled() else { return }
        VoIPPushController.shared.storeAlertToken(deviceToken)
#if DEBUG
        print("[AirSIM APNs] 普通通知 token 已更新；字节数=\(deviceToken.count)")
#endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        guard CloudSignalingPreference.isEnabled() else { return }
        VoIPPushController.shared.clearAlertToken()
#if DEBUG
        print("[AirSIM APNs] 普通通知 token 注册失败：\(error.localizedDescription)")
#endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        AirSIMHealthStore.received()
        guard CloudSignalingPreference.isEnabled() else {
            completionHandler(.noData)
            return
        }
        if userInfo["event"] as? String == "call_owner" {
            IncomingCallNotifier.shared.reconcilePush(userInfo)
        }
        if userInfo["event"] as? String == "call_owner",
           let owner = userInfo["owner"] as? String,
           owner == "watch" || owner == "android" {
            let callID = userInfo["call_id"] as? String
            let uuid = (userInfo["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
            let generation = (userInfo["generation"] as? NSNumber)?.uint64Value
            let phase = userInfo["phase"] as? String
            if CallKitController.shared.matchesCurrentCall(
                callID: callID, uuid: uuid, generation: generation
            ) {
                // Cloud answer acknowledgment and the Android call_owner push can
                // arrive out of order. A prepared/answered cloud session already
                // proves this iPhone owns the call; do not end it as answeredElsewhere.
                let answered = CallKitController.shared.currentCallIsAnswered
                    || IPhoneCloudCallSession.shared.answered
                if owner == "android", phase == "active", answered {
                    completionHandler(.noData)
                    return
                }
                let reason: CXCallEndedReason
                if owner == "android" {
                    reason = phase == "active" ? .answeredElsewhere : .remoteEnded
                } else {
                    reason = phase == "active" ? .answeredElsewhere : .declinedElsewhere
                }
                CallKitController.shared.reportCurrentCallEnded(reason: reason)
                IPhoneCloudCallSession.shared.stop()
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
            return
        }
        do {
            let pushed = try IncomingRemoteSMS(userInfo: userInfo)
            SMSNotificationCoordinator.shared.markPush(agentID: pushed.agentID,
                                                        deliveryID: pushed.deliveryID)
            let saved = persistRemoteSMS(pushed)
            if saved {
                NotificationCenter.default.post(name: .airsimRemoteSMSReceived, object: nil)
            }
            completionHandler(saved ? .newData : .noData)
        } catch RemoteSMSPushError.unsupportedEvent {
            completionHandler(.noData)
        } catch {
#if DEBUG
            print("[AirSIM APNs] 短信推送解析失败：\(error.localizedDescription)")
#endif
            completionHandler(.failed)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        AirSIMHealthStore.received()
        let info = notification.request.content.userInfo
        if info["event"] as? String == "call_owner" {
            IncomingCallNotifier.shared.reconcilePush(info)
            completionHandler(CallNotificationTruth.isMissedPush(info) ? [.banner, .list, .sound] : [])
            return
        }
        if info["event"] as? String == "missed_call" {
            completionHandler([.banner, .list]); return
        }
        if notification.request.content.userInfo["event"] as? String == "other_android_incoming" {
            completionHandler([.banner, .list]); return
        }
        guard notification.request.content.userInfo["event"] as? String == "incoming_sms" else {
            completionHandler([])
            return
        }
        if let pushed = try? IncomingRemoteSMS(userInfo: notification.request.content.userInfo) {
            SMSNotificationCoordinator.shared.markPush(agentID: pushed.agentID,
                                                        deliveryID: pushed.deliveryID)
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        if response.notification.request.content.userInfo["event"] as? String == "other_android_incoming" {
            let info = response.notification.request.content.userInfo
            OtherAndroidCallPresentationRequest.mark(info)
            NotificationCenter.default.post(name: .airsimOpenOtherAndroidCall, object: nil, userInfo: info)
            completionHandler(); return
        }
        if response.notification.request.content.userInfo["event"] as? String == "incoming_sms" {
            let userInfo = response.notification.request.content.userInfo
            let pushed = try? IncomingRemoteSMS(userInfo: userInfo)
            if let pushed {
                SMSNotificationCoordinator.shared.markPush(agentID: pushed.agentID,
                                                            deliveryID: pushed.deliveryID)
                if persistRemoteSMS(pushed) {
                    NotificationCenter.default.post(name: .airsimRemoteSMSReceived, object: nil)
                }
            }
            // Encrypted pushes carry no plaintext sender; the decrypted one opens the conversation.
            let sender = pushed?.sender ?? userInfo["sender"] as? String
            if let sender { IncomingSMSPresentationRequest.markPending(sender: sender) }
            NotificationCenter.default.post(
                name: .airsimOpenSMSConversation,
                object: nil,
                userInfo: sender.map { ["sender": $0] }
            )
            completionHandler()
            return
        }
        if response.notification.request.content.userInfo["event"] as? String == "incoming_call",
           actionIdentifier == UNNotificationDefaultActionIdentifier {
            IncomingCallPresentationRequest.markPending()
            NotificationCenter.default.post(name: .airsimOpenIncomingCall, object: nil)
            completionHandler()
            return
        }
        guard actionIdentifier == IncomingCallNotification.answerActionIdentifier
                || actionIdentifier == IncomingCallNotification.rejectActionIdentifier,
              let callID = (response.notification.request.content.userInfo["action_call_id"]
                ?? response.notification.request.content.userInfo[IncomingCallNotification.callIDKey]) as? String else {
            completionHandler()
            return
        }

        Task { @MainActor in
            defer {
                center.removeDeliveredNotifications(
                    withIdentifiers: [response.notification.request.identifier]
                )
                completionHandler()
            }
            do {
                if callID.hasPrefix("local:") {
                    guard let model = CallKitController.shared.handler as? AppModel else { throw DeviceCallRoutingError.stale }
                    _ = try await model.performOwnedIncomingNotificationAction(actionIdentifier, callID: callID)
                    return
                }
                guard let api = await coldLaunchCallHandler.availableSamsungAPI() else {
                    throw CallKitBridgeError.noReachableTransport
                }
                let status = try await api.callStatus()
                // 必须匹配仍在振铃的同一通电话，防止用户点击过期通知误操作新通话。
                guard status.active?.id == callID,
                      status.active?.direction == "incoming",
                      let state = status.active?.state,
                      ["incoming", "waiting"].contains(state) else { return }

                if actionIdentifier == IncomingCallNotification.answerActionIdentifier {
                    try await api.answerCall(callID: callID)
                } else {
                    _ = try await api.rejectCall(callID: callID)
                }
            } catch {
                Self.reportActionFailure(error)
            }
        }
    }

    private static func reportActionFailure(_ error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "AirSIM 操作失败"
        content.body = error.localizedDescription
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "airsim.call-action-failed.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    private func persistRemoteSMS(_ pushed: IncomingRemoteSMS) -> Bool {
        // 超长内容在 APNs payload 中只带预览，等待下次与 Agent 同步完整正文，避免本地出现两条。
        guard !pushed.contentTruncated else { return false }
        guard !historyStore.visibleMessages([pushed.message]).isEmpty else { return false }
        var messages = historyStore.loadMessages()
        guard !messages.contains(where: { $0.id == pushed.message.id }) else { return false }
        messages.append(pushed.message)
        messages.sort { $0.timestamp > $1.timestamp }
        if messages.count > 2_000 {
            messages = Array(messages.prefix(2_000))
        }
        guard historyStore.saveMessages(messages) else { return false }
        // A background notification need not create a SwiftUI scene/AppModel.
        // Refresh counts from durable state without starting any connection.
        let store = AirSIMWidgetStore()
        var snapshot = store.load()
        let stored = historyStore.loadMessages()
        let unread = historyStore.unreadMessageIDs(in: stored)
        snapshot.devices = snapshot.devices.map { device in
            var updated = device
            updated.unreadMessages = Set(stored.filter {
                $0.sourceAgentID == device.id && unread.contains($0.id)
            }.map(\.id)).count
            return updated
        }
        let allowed = Set(snapshot.devices.map(\.id))
        snapshot.messages = stored.filter { $0.sourceAgentID.map { allowed.contains($0) } ?? false }
            .sorted { $0.timestamp > $1.timestamp }.prefix(6).map {
                .init(agentID: $0.sourceAgentID, date: $0.timestamp, incoming: !$0.isOutgoing,
                      contentPreview: AirSIMWidgetSnapshot.messagePreview($0.content))
            }
        if store.save(snapshot) { WidgetCenter.shared.reloadTimelines(ofKind: AirSIMWidgetSnapshot.kind) }
        return true
    }
}

/// SwiftUI 状态中心尚未建立时也能响应系统接听/拒接；AppModel 启动后会接管 handler。
@MainActor
private final class ColdLaunchCallKitHandler: CallKitActionHandling {
    private let vowlan = VoWLANController()

    init() { vowlan.startBrowsing() }
    func stop() { vowlan.stopBrowsing() }

    private func selectedAgent() -> VoWLANDiscoveredAgent? {
        let candidates = vowlan.discoveredAgents.filter {
            PairedAndroidDeviceStore.permits($0.id)
                && VoWLANCredentialStore.load(agentID: $0.id) != nil
        }
        if let bound = AndroidAgentBindingPreference.selected() {
            return candidates.first { $0.id == bound }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func availableSamsungAPI() async -> AirSIMAPI? {
        // PushKit can answer before the SwiftUI AppModel and Bonjour browser
        // have completed startup. Wait briefly for the bound device, never use
        // the legacy global credential or an arbitrary discovered Android.
        for attempt in 0..<10 {
            await vowlan.probeNow()
            if vowlan.availability.isOnlineForDisplay,
               let activeEndpoint = vowlan.availability.endpoint,
               let agent = selectedAgent(),
               agent.endpoint == activeEndpoint,
               let credential = VoWLANCredentialStore.load(agentID: agent.id) {
                return AirSIMAPI(route: .vowlan(endpoint: activeEndpoint, credential: credential))
            }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        return nil
    }

    func callKitStart(number: String) async throws {
        let intentID = CallKitController.shared.currentSystemCallUUID ?? UUID()
        guard let api = await availableSamsungAPI() else { throw CallKitBridgeError.noReachableTransport }
        guard !Task.isCancelled,
              CallKitController.shared.currentSystemCallUUID == intentID else { throw CancellationError() }
        try await api.dial(number: number, operationID: intentID)
    }
    func callKitPrepareAudioSession() throws {
        if CloudModePreference.isEnabled(),
           CallKitController.shared.currentIncomingPush?.authenticatedMediaURL != nil {
            try IPhoneCloudCallSession.shared.prepareAudioForCallKit()
        }
    }
    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        if let pushedCall = CallKitController.shared.currentIncomingPush,
           pushedCall.isVirtual {
            try VirtualCallTTSController.shared.prepare(pushedCall)
        } else if CloudModePreference.isEnabled(),
                  let pushedCall = CallKitController.shared.currentIncomingPush,
                  pushedCall.authenticatedMediaURL != nil {
            try await IPhoneCloudCallSession.shared.answer(pushedCall)
        } else if let api = await availableSamsungAPI() {
            try await api.answerCall()
        } else {
            throw CallKitBridgeError.noReachableTransport
        }
    }
    func callKitEnd() async throws {
        if VirtualCallTTSController.shared.isPrepared
            || CallKitController.shared.currentIncomingPush?.isVirtual == true {
            VirtualCallTTSController.shared.stop()
            return
        }
        if CloudModePreference.isEnabled(),
           let pushedCall = CallKitController.shared.currentIncomingPush,
            pushedCall.authenticatedMediaURL != nil {
            if IPhoneCloudCallSession.shared.isPrepared {
                await IPhoneCloudCallSession.shared.end()
            } else {
                try await IPhoneCloudCallSession.shared.reject(pushedCall)
            }
            return
        }
        guard let api = await availableSamsungAPI() else { throw CallKitBridgeError.noReachableTransport }
        let call = (try? await api.callStatus())?.active
        if let call,
           call.direction == "incoming",
           ["incoming", "waiting"].contains(call.state) {
            _ = try await api.rejectCall(callID: call.id)
        } else {
            try await api.hangupCall(callID: call?.id)
        }
    }
    func callKitSetMuted(_ muted: Bool) async {
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.setMuted(muted)
            return
        }
        IPhoneCloudCallSession.shared.setMuted(muted)
        if !IPhoneCloudCallSession.shared.isPrepared,
           let api = await availableSamsungAPI() { try? await api.setAudioMuted(muted) }
    }
    func callKitPlayDTMF(_ digits: String) async throws {
        if VirtualCallTTSController.shared.isPrepared { return }
        for digit in digits where "0123456789*#".contains(digit) {
            guard let api = await availableSamsungAPI() else { throw CallKitBridgeError.noReachableTransport }
            try await api.sendDTMF(String(digit))
        }
    }
    func callKitAudioSessionDidActivate() async {
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.start()
        } else if IPhoneCloudCallSession.shared.hasActiveCall {
            IPhoneCloudCallSession.shared.startAudioWithRetry()
        }
    }
    func callKitAudioSessionDidDeactivate() {
        if VirtualCallTTSController.shared.isPrepared { VirtualCallTTSController.shared.stop() }
        else { IPhoneCloudCallSession.shared.stopAudio() }
    }
    func callKitProviderDidReset() async {
        if VirtualCallTTSController.shared.isPrepared { VirtualCallTTSController.shared.stop() }
        else { IPhoneCloudCallSession.shared.stopAudio() }
    }
    func callKitDidFail(_ message: String) {}
}

enum BackgroundStandbyPreference {
    static let key = "airsim.background-standby-enabled"

    /// Off by default: silent audio keeps the process alive but is expensive.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }
}

/// 个人侧载模式下维持静音播放，让 iOS 在熄屏后继续执行模块来电轮询。
@MainActor
final class BackgroundStandbyController {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    var audioGraphPrepared: Bool { engine != nil }
    private let silentBuffer: AVAudioPCMBuffer
    private var enabled = false
    private var appIsBackground = false
    private var suspendedForCall = false
    private var retryTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = buffer.frameCapacity
        if let samples = buffer.floatChannelData?.pointee {
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        silentBuffer = buffer

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureRunning()
            }
        }
    }

    deinit {
        retryTask?.cancel()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            ensureRunning()
        } else {
            stop(deactivateSession: true)
        }
    }

    /// 在即将退到后台时预启动，回到前台后立即释放音频硬件。
    func setApplicationIsBackground(_ isBackground: Bool) {
        if isBackground {
            prepareForBackground()
        } else if !suspendedForCall {
            appIsBackground = false
            stop(deactivateSession: true)
        }
    }

    /// scene 进入 inactive 时仍有前台执行资格，必须在这一刻预启动音频。
    /// 真正收到 background 回调后再启动，系统可能已经决定挂起进程。
    func prepareForBackground() {
        appIsBackground = true
        ensureRunning()
    }

    /// 回到前台或后台音频被系统中断后重新确认静音播放仍在运行。
    func ensureRunning() {
        guard enabled, BackgroundStandbyPreference.isEnabled(),
              appIsBackground, !suspendedForCall,
              BackgroundStandbySuspensionPolicy.shouldRunStandby(
                  callKitAudioActive: CallKitController.shared.audioSessionIsActive) else { return }
        retryTask?.cancel()
        retryTask = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if engine == nil {
                let graph = AVAudioEngine(), node = AVAudioPlayerNode()
                graph.attach(node)
                graph.connect(node, to: graph.mainMixerNode, format: silentBuffer.format)
                engine = graph; player = node
            }
            guard let engine, let player else { return }
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying {
                player.scheduleBuffer(silentBuffer, at: nil, options: .loops)
                player.play()
            }
#if DEBUG
            print("[AirSIM Background] standby audio running")
#endif
        } catch {
#if DEBUG
            print("[AirSIM Background] standby audio failed: \(error.localizedDescription)")
#endif
            scheduleRetry()
        }
    }

    /// 通话 PCM 必须独占 voiceChat 会话，不能与后台静音播放同时争用输出节点。
    func suspendForCall() {
        guard BackgroundStandbySuspensionPolicy.shouldStopAudio(
            isAlreadySuspended: suspendedForCall
        ) else { return }
        suspendedForCall = true
        stop(deactivateSession: BackgroundStandbySuspensionPolicy.shouldDeactivateSession(
            callKitAudioActive: CallKitController.shared.audioSessionIsActive))
    }

    func resumeAfterCall() {
        suspendedForCall = false
        ensureRunning()
    }

    private func stop(deactivateSession: Bool) {
        retryTask?.cancel()
        retryTask = nil
        player?.stop()
        engine?.stop()
        if deactivateSession,
           BackgroundStandbySuspensionPolicy.shouldDeactivateSession(
               callKitAudioActive: CallKitController.shared.audioSessionIsActive) {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil, enabled, appIsBackground, !suspendedForCall else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.retryNow()
        }
    }

    private func retryNow() {
        retryTask = nil
        ensureRunning()
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              type == .ended else { return }
        ensureRunning()
    }
}

/// Only explicit terminal evidence may label a notification as missed.
enum CallNotificationTruth {
    static func isMissed(_ call: CallRecord) -> Bool {
        call.isTerminal && call.direction == "incoming" && call.missed && call.connectedAt == nil
    }
    static func isMissedPush(_ info: [AnyHashable: Any]) -> Bool {
        info["event"] as? String == "call_owner" && info["phase"] as? String == "ended"
            && info["direction"] as? String == "incoming" && info["missed"] as? Bool == true
            && info["notification_status"] as? String == "missed"
    }
    // An absent agent must never act as a wildcard across paired devices.
    static func matches(_ left: [AnyHashable: Any], _ right: [AnyHashable: Any]) -> Bool {
        guard let agent = left["agent_id"] as? String, !agent.isEmpty,
              agent == right["agent_id"] as? String,
              let call = left["call_id"] as? String, !call.isEmpty,
              call == right["call_id"] as? String else { return false }
        if let a = left["generation"] as? NSNumber, let b = right["generation"] as? NSNumber, a != b { return false }
        if let a = left["call_uuid"] as? String, let b = right["call_uuid"] as? String, a != b { return false }
        return true
    }
    static func key(_ info: [AnyHashable: Any]) -> String? {
        guard let agent = info["agent_id"] as? String, !agent.isEmpty,
              let call = info["call_id"] as? String, !call.isEmpty else { return nil }
        // Native Android IDs are UUIDs, never reused across calls. Legacy history
        // without a generation can therefore match its cloud notification safely.
        return Data(agent.utf8).base64EncodedString() + ":" + Data(call.utf8).base64EncodedString()
    }
    static func info(_ call: CallRecord) -> [AnyHashable: Any] {
        ["agent_id": call.sourceAgentID ?? "", "call_id": call.androidID ?? call.sourceCallID ?? call.id]
    }
    static func body(number: String?, callerName: String?, slotIndex: Int?) -> String {
        let number = number.flatMap { $0.isEmpty ? nil : $0 } ?? "未知号码"
        let name = callerName.flatMap { $0.isEmpty ? nil : $0 }
        var parts = [name == nil || name == number ? number : "\(name!) · \(number)"]
        if let slotIndex, slotIndex >= 0 { parts.append("SIM \(slotIndex + 1)") }
        return parts.joined(separator: " · ")
    }
}

/// App 在后台检测到模块来电后发送本地通知；不依赖 APNs 或远程服务器。
@MainActor
final class IncomingCallNotifier {
    static let shared = IncomingCallNotifier()
    private let launchedAt = Date()
    private var missedTasks: [String: Task<Void, Never>] = [:]
    private var missedIDs = Set(UserDefaults.standard.stringArray(forKey: "airsim.missed-notification.ids.v1") ?? [])
    private(set) var currentCallID: String?
    private var notifiedCallIDs: [String] = []

    func requestAuthorization() {
        IncomingCallNotification.registerCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
#if DEBUG
            if let error {
                print("[AirSIM APNs] 通知授权失败：\(error.localizedDescription)")
            } else {
                print("[AirSIM APNs] 通知授权状态：\(granted ? "已允许" : "未允许")")
            }
#endif
            Task { @MainActor in
                guard CloudSignalingPreference.isEnabled() else { return }
                VoIPPushController.shared.start()
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func reconcilePush(_ info: [AnyHashable: Any]) {
        guard ["active", "ended"].contains(info["phase"] as? String ?? "") else { return }
        removeStaleIncoming(info: info)
        if CallNotificationTruth.isMissedPush(info), let key = CallNotificationTruth.key(info) {
            missedTasks.removeValue(forKey: key)?.cancel()
            remember(key)
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [localMissedID(key)])
            center.removePendingNotificationRequests(withIdentifiers: [localMissedID(key)])
        }
    }

    private func localMissedID(_ key: String) -> String {
        "airsim.missed." + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func remember(_ key: String) {
        missedIDs.insert(key)
        if missedIDs.count > 512 { missedIDs = [key] }
        UserDefaults.standard.set(Array(missedIDs), forKey: "airsim.missed-notification.ids.v1")
    }
    private func removeStaleIncoming(info: [AnyHashable: Any]) {
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            let stale = delivered.filter {
                [IncomingCallNotification.categoryIdentifier, IncomingCallNotification.mirrorCategoryIdentifier]
                    .contains($0.request.content.categoryIdentifier)
                    && CallNotificationTruth.matches(info, $0.request.content.userInfo)
            }.map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    func reconcileHistory(_ records: [CallRecord], previous: [CallRecord], callerName: (String?) -> String) {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for call in records where call.isTerminal && old[call.id] != call {
            let info = CallNotificationTruth.info(call)
            removeStaleIncoming(info: info)
            if let key = CallNotificationTruth.key(info), !CallNotificationTruth.isMissed(call) {
                missedTasks.removeValue(forKey: key)?.cancel()
                if call.connectedAt != nil {
                    remember(key)
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [localMissedID(key)])
                }
            }
            // Never replay imported history on launch. An old Agent's explicit
            // missed fact remains eligible even when cloud signaling is enabled.
            guard (call.endedAt ?? call.updatedAt).timeIntervalSinceReferenceDate >= launchedAt.timeIntervalSinceReferenceDate,
                  CallNotificationTruth.isMissed(call), let key = CallNotificationTruth.key(info),
                  !missedIDs.contains(key), missedTasks[key] == nil else { continue }
            let body = CallNotificationTruth.body(number: call.number, callerName: callerName(call.number),
                slotIndex: call.slotIndex ?? call.slotID)
            missedTasks[key] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                defer { self.missedTasks[key] = nil }
                guard !Task.isCancelled, !self.missedIDs.contains(key) else { return }
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                guard !Task.isCancelled, !self.missedIDs.contains(key) else { return }
                if delivered.contains(where: { CallNotificationTruth.isMissedPush($0.request.content.userInfo)
                    && CallNotificationTruth.matches(info, $0.request.content.userInfo) }) {
                    self.remember(key)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "AirSIM 未接来电"
                content.body = body
                content.userInfo = info.merging(["event": "missed_call"]) { _, new in new }
                content.categoryIdentifier = "AIRSIM_MISSED_CALL"
                // No second ring. Cloud's later alert replaces this local record.
                do {
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                        identifier: self.localMissedID(key), content: content, trigger: nil))
                    // APNs or corrected history may arrive while add() yields.
                    if Task.isCancelled || self.missedIDs.contains(key) {
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [self.localMissedID(key)])
                        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [self.localMissedID(key)])
                    } else { self.remember(key) }
                } catch { /* A later history update may retry. */ }
            }
        }
    }

    func update(call: CallRecord?, callerName: String?, appIsActive: Bool, presentIncoming: Bool = true) {
        if let call, !["incoming", "waiting"].contains(call.state) {
            removeStaleIncoming(info: CallNotificationTruth.info(call))
        }
        let nextID = call.flatMap { ["incoming", "waiting"].contains($0.state) ? $0.id : nil }
        if let old = currentCallID, old != nextID {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: ["airsim.incoming.\(old)"])
            center.removePendingNotificationRequests(withIdentifiers: ["airsim.incoming.\(old)"])
        }
        currentCallID = nextID
        guard presentIncoming, !appIsActive,
              let call,
              call.direction == "incoming",
              ["incoming", "waiting"].contains(call.state),
              !notifiedCallIDs.contains(call.id) else { return }

        notifiedCallIDs.append(call.id)
        if notifiedCallIDs.count > 32 { notifiedCallIDs.removeFirst() }

        let content = UNMutableNotificationContent()
        content.title = "AirSIM 来电"
        content.body = CallNotificationTruth.body(number: call.number, callerName: callerName,
            slotIndex: call.slotIndex ?? call.slotID)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = IncomingCallNotification.categoryIdentifier
        content.userInfo = CallNotificationTruth.info(call)
        content.userInfo["action_call_id"] = call.id
        let request = UNNotificationRequest(
            identifier: "airsim.incoming.\(call.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// APNs alert and local SMS sync must agree on one notification identity.
/// The key is source agent + delivery ID; the contact name is display-only.
@MainActor
final class SMSNotificationCoordinator {
    static let shared = SMSNotificationCoordinator()
    private struct Entry: Codable {
        var key: String
        var deliveryID: String? = nil
        var agentID: String? = nil
        var pushAt: Date? = nil
        var localAt: Date? = nil
        var localIdentifier: String? = nil
        var touchedAt: Date
    }
    private let keyName = "airsim.sms.notification-ledger.v1"
    private let defaults: UserDefaults
    private var entries: [String: Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: keyName),
           let values = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = values
        } else {
            entries = [:]
        }
    }

    func key(agentID: String?, deliveryID: String?) -> String {
        let agent = agentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let delivery = deliveryID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = "\(agent)\u{0}\(delivery)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func identifier(for key: String) -> String {
        "airsim.sms.\(key.prefix(40))"
    }

    func markPush(agentID: String?, deliveryID: String?) {
        guard let deliveryID, !deliveryID.isEmpty else { return }
        let exact = key(agentID: agentID, deliveryID: deliveryID)
        let target = entries[exact]
            ?? entries.values.first(where: { entry in
                entry.deliveryID == deliveryID
                    && (agentID?.isEmpty != false || entry.agentID == nil || entry.agentID == agentID)
            })
        let key = target?.key ?? exact
        var entry = target ?? Entry(key: key, deliveryID: deliveryID, agentID: agentID,
                                    touchedAt: Date())
        entry.pushAt = Date()
        entry.touchedAt = Date()
        entries[key] = entry
        if let identifier = entry.localIdentifier {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        }
        persist()
    }

    func claimLocal(agentID: String?, deliveryID: String?) -> (key: String, identifier: String)? {
        guard let deliveryID, !deliveryID.isEmpty else { return nil }
        let exact = key(agentID: agentID, deliveryID: deliveryID)
        if entries[exact]?.pushAt != nil || entries[exact]?.localAt != nil { return nil }
        // Older Relay payloads omitted agent_id. Match a legacy entry by
        // delivery ID so a push-first arrival still suppresses local display.
        if entries.values.contains(where: { entry in
            entry.deliveryID == deliveryID
                && (agentID?.isEmpty != false || entry.agentID == nil || entry.agentID == agentID)
                && (entry.pushAt != nil || entry.localAt != nil)
        }) { return nil }
        let identifier = identifier(for: exact)
        var entry = entries[exact] ?? Entry(key: exact, deliveryID: deliveryID,
                                           agentID: agentID, touchedAt: Date())
        entry.localAt = Date()
        entry.localIdentifier = identifier
        entry.touchedAt = Date()
        entries[exact] = entry
        persist()
        return (exact, identifier)
    }

    /// Cloud/APNs is authoritative when a usable alert token exists. Local
    /// notifications are only the owner for local/BLE-only operation.
    func cloudOwnsNotifications() -> Bool {
        CloudSignalingPreference.isEnabled()
            && VoIPPushController.shared.registrationReadiness().alertTokenReady
    }

    func hasPush(agentID: String?, deliveryID: String?) -> Bool {
        guard let deliveryID, !deliveryID.isEmpty else { return false }
        let exact = key(agentID: agentID, deliveryID: deliveryID)
        if entries[exact]?.pushAt != nil { return true }
        return entries.values.contains { entry in
            entry.deliveryID == deliveryID
                && (agentID?.isEmpty != false || entry.agentID == nil || entry.agentID == agentID)
                && entry.pushAt != nil
        }
    }

    private func persist() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        entries = entries.filter { $0.value.touchedAt >= cutoff }
        if entries.count > 500 {
            let keep = entries.sorted { $0.value.touchedAt > $1.value.touchedAt }.prefix(500)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        defaults.set(try? JSONEncoder().encode(entries), forKey: keyName)
    }
}

/// 新短信已经由 Agent 的 +CMTI URC 单条读取；App 在后台时补发系统通知。
@MainActor
final class IncomingSMSNotifier {
    private var notifiedMessageIDs: [String] = []

    func notify(message: SMSMessage, displayName: String, appIsActive: Bool) {
        guard !appIsActive, !notifiedMessageIDs.contains(message.id) else { return }
        guard !SMSNotificationCoordinator.shared.hasPush(
            agentID: message.sourceAgentID, deliveryID: message.deliveryID) else { return }

        if SMSNotificationCoordinator.shared.cloudOwnsNotifications() {
            // A stale/misconfigured APNs token must not silently swallow the
            // alert. Give a healthy push a short head start, then fall back to
            // the same persistent notification ledger.
            notifiedMessageIDs.append(message.id)
            if notifiedMessageIDs.count > 64 { notifiedMessageIDs.removeFirst() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self,
                      UIApplication.shared.applicationState != .active,
                      !SMSNotificationCoordinator.shared.hasPush(
                          agentID: message.sourceAgentID, deliveryID: message.deliveryID) else { return }
                self.post(message: message, displayName: displayName)
            }
            return
        }
        post(message: message, displayName: displayName)
    }

    private func post(message: SMSMessage, displayName: String) {
        guard let claim = SMSNotificationCoordinator.shared.claimLocal(
            agentID: message.sourceAgentID, deliveryID: message.deliveryID) else { return }
        let content = UNMutableNotificationContent()
        content.title = displayName
        content.subtitle = message.simDeliveryLabel
        content.body = message.content
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: claim.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
