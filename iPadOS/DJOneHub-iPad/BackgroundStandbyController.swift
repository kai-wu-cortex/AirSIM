import AVFoundation
import CallKit
import Foundation
import UIKit
import UserNotifications

enum BackgroundStandbySuspensionPolicy {
    static func shouldStopAudio(isAlreadySuspended: Bool) -> Bool {
        !isAlreadySuspended
    }
}

extension Notification.Name {
    static let djonehubRemoteSMSReceived = Notification.Name("DJOneHubRemoteSMSReceived")
    static let djonehubOpenSMSConversation = Notification.Name("DJOneHubOpenSMSConversation")
    static let djonehubOpenIncomingCall = Notification.Name("DJOneHubOpenIncomingCall")
}

/// 锁屏来电通知使用的稳定标识；动作不要求设备解锁，也不会强制打开 App 界面。
enum IncomingCallNotification {
    static let categoryIdentifier = "DJONEHUB_INCOMING_CALL"
    static let mirrorCategoryIdentifier = "DJONEHUB_INCOMING_CALL_MIRROR"
    static let answerActionIdentifier = "DJONEHUB_ANSWER_CALL"
    static let rejectActionIdentifier = "DJONEHUB_REJECT_CALL"
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

/// 接收锁屏通知动作，并在系统授予的后台执行时间内直接控制模块通话。
@MainActor
final class DJOneHubNotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let coldLaunchCallHandler = ColdLaunchCallKitHandler()
    private let historyStore = LocalHistoryStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        IncomingCallNotification.registerCategory()
        if CallKitController.shared.handler == nil {
            CallKitController.shared.handler = coldLaunchCallHandler
        }
		// Watch token 与跨设备接听所有权必须在冷启动阶段就可接收，不能等待
		// SwiftUI 首屏 onAppear（锁屏 PushKit 唤醒时首屏可能永远不出现）。
		WatchCallCoordinator.shared.start()
        VoIPPushController.shared.start()
        application.registerForRemoteNotifications()
#if DEBUG
        print("[DJOneHub APNs] 已启动普通通知与 PushKit 注册")
#endif
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 首次授权弹窗可能晚于 didFinishLaunching 返回；回到前台时重新登记是幂等的。
        VoIPPushController.shared.start()
        application.registerForRemoteNotifications()
        Task { await VoIPPushController.shared.syncRegistration() }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        VoIPPushController.shared.storeAlertToken(deviceToken)
#if DEBUG
        print("[DJOneHub APNs] 普通通知 token 已更新；字节数=\(deviceToken.count)")
#endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        VoIPPushController.shared.clearAlertToken()
#if DEBUG
        print("[DJOneHub APNs] 普通通知 token 注册失败：\(error.localizedDescription)")
#endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if userInfo["event"] as? String == "call_owner",
           userInfo["owner"] as? String == "watch" {
            let callID = userInfo["call_id"] as? String
            let uuid = (userInfo["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
            if CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) {
                let reason: CXCallEndedReason = userInfo["phase"] as? String == "active"
                    ? .answeredElsewhere : .declinedElsewhere
                CallKitController.shared.reportCurrentCallEnded(reason: reason)
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
            return
        }
        do {
            let pushed = try IncomingRemoteSMS(userInfo: userInfo)
            let saved = persistRemoteSMS(pushed)
            if saved {
                NotificationCenter.default.post(name: .djonehubRemoteSMSReceived, object: nil)
            }
            completionHandler(saved ? .newData : .noData)
        } catch RemoteSMSPushError.unsupportedEvent {
            completionHandler(.noData)
        } catch {
#if DEBUG
            print("[DJOneHub APNs] 短信推送解析失败：\(error.localizedDescription)")
#endif
            completionHandler(.failed)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.content.userInfo["event"] as? String == "incoming_sms" else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        if response.notification.request.content.userInfo["event"] as? String == "incoming_sms" {
            let sender = response.notification.request.content.userInfo["sender"] as? String
            NotificationCenter.default.post(
                name: .djonehubOpenSMSConversation,
                object: nil,
                userInfo: sender.map { ["sender": $0] }
            )
            completionHandler()
            return
        }
        if response.notification.request.content.userInfo["event"] as? String == "incoming_call",
           actionIdentifier == UNNotificationDefaultActionIdentifier {
            IncomingCallPresentationRequest.markPending()
            NotificationCenter.default.post(name: .djonehubOpenIncomingCall, object: nil)
            completionHandler()
            return
        }
        guard actionIdentifier == IncomingCallNotification.answerActionIdentifier
                || actionIdentifier == IncomingCallNotification.rejectActionIdentifier,
              let callID = response.notification.request.content.userInfo[
                  IncomingCallNotification.callIDKey
              ] as? String else {
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
                    try await api.answerCall()
                } else {
                    _ = try await api.rejectCall()
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
                identifier: "djonehub.call-action-failed.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    private func persistRemoteSMS(_ pushed: IncomingRemoteSMS) -> Bool {
        // 超长内容在 APNs payload 中只带预览，等待下次与 Agent 同步完整正文，避免本地出现两条。
        guard !pushed.contentTruncated else { return false }
        var messages = historyStore.loadMessages()
        guard !messages.contains(where: { $0.deliveryID == pushed.deliveryID }) else { return false }
        messages.append(pushed.message)
        messages.sort { $0.timestamp > $1.timestamp }
        if messages.count > 2_000 {
            messages = Array(messages.prefix(2_000))
        }
        return historyStore.saveMessages(messages)
    }
}

/// SwiftUI 状态中心尚未建立时也能响应系统接听/拒接；AppModel 启动后会接管 handler。
@MainActor
private final class ColdLaunchCallKitHandler: CallKitActionHandling {
    private let vowlan = VoWLANController()

    init() { vowlan.startBrowsing() }

    func availableSamsungAPI() async -> DJOneHubAPI? {
        await vowlan.probeNow()
        guard vowlan.availability.isOnlineForDisplay,
              let endpoint = vowlan.availability.endpoint,
              let credential = VoWLANCredentialStore.load() else { return nil }
        return DJOneHubAPI(route: .vowlan(endpoint: endpoint, credential: credential))
    }

    func callKitStart(number: String) async throws {
        guard let api = await availableSamsungAPI() else { throw CallKitBridgeError.noReachableTransport }
        try await api.dial(number: number)
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
        if let call = (try? await api.callStatus())?.active,
           call.direction == "incoming",
           ["incoming", "waiting"].contains(call.state) {
            _ = try await api.rejectCall()
        } else {
            try await api.hangupCall()
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

/// 个人侧载模式下维持静音播放，让 iOS 在熄屏后继续执行模块来电轮询。
@MainActor
final class BackgroundStandbyController {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
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
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

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
        guard enabled, appIsBackground, !suspendedForCall else { return }
        retryTask?.cancel()
        retryTask = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying {
                player.scheduleBuffer(silentBuffer, at: nil, options: .loops)
                player.play()
            }
#if DEBUG
            print("[DJOneHub Background] standby audio running")
#endif
        } catch {
#if DEBUG
            print("[DJOneHub Background] standby audio failed: \(error.localizedDescription)")
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
        stop(deactivateSession: true)
    }

    func resumeAfterCall() {
        suspendedForCall = false
        ensureRunning()
    }

    private func stop(deactivateSession: Bool) {
        retryTask?.cancel()
        retryTask = nil
        player.stop()
        engine.stop()
        if deactivateSession {
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

/// App 在后台检测到模块来电后发送本地通知；不依赖 APNs 或远程服务器。
@MainActor
final class IncomingCallNotifier {
    private var notifiedCallIDs: [String] = []

    func requestAuthorization() {
        IncomingCallNotification.registerCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
#if DEBUG
            if let error {
                print("[DJOneHub APNs] 通知授权失败：\(error.localizedDescription)")
            } else {
                print("[DJOneHub APNs] 通知授权状态：\(granted ? "已允许" : "未允许")")
            }
#endif
            Task { @MainActor in
                VoIPPushController.shared.start()
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func update(call: CallRecord?, callerName: String?, appIsActive: Bool) {
        guard !appIsActive,
              let call,
              call.direction == "incoming",
              ["incoming", "waiting"].contains(call.state),
              !notifiedCallIDs.contains(call.id) else { return }

        notifiedCallIDs.append(call.id)
        if notifiedCallIDs.count > 32 { notifiedCallIDs.removeFirst() }

        let content = UNMutableNotificationContent()
        let number = call.number?.isEmpty == false ? call.number! : "未知号码"
        let displayName = callerName?.isEmpty == false ? callerName! : number
        content.title = "AirSIM 来电"
        // 同时保留姓名和号码，用户可以在锁屏直接确认来电者。
        content.body = displayName == number ? number : "\(displayName) · \(number)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = IncomingCallNotification.categoryIdentifier
        content.userInfo = [IncomingCallNotification.callIDKey: call.id]
        let request = UNNotificationRequest(
            identifier: "djonehub.incoming.\(call.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// 新短信已经由 Agent 的 +CMTI URC 单条读取；App 在后台时补发系统通知。
@MainActor
final class IncomingSMSNotifier {
    private var notifiedMessageIDs: [String] = []

    func notify(message: SMSMessage, displayName: String, appIsActive: Bool) {
        guard !appIsActive, !notifiedMessageIDs.contains(message.id) else { return }
        notifiedMessageIDs.append(message.id)
        if notifiedMessageIDs.count > 64 { notifiedMessageIDs.removeFirst() }

        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = message.content
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: "djonehub.sms.\(message.id.hashValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
