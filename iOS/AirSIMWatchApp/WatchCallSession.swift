import AVFoundation
import CallKit
import CryptoKit
import Foundation
import Network
import PushKit
import Security
import WatchConnectivity

/// Apple Watch 自己注册 VoIP Push、上报 CallKit 并承载网络 PCM。
/// VoWLAN 专用版由 iPhone 协调控制，Watch 直连安卓 PCM；Relay 仅用于推送。
@MainActor
final class WatchCallSession: NSObject, ObservableObject {
    @Published private(set) var call = WatchCallPayload(
        callID: "", callUUID: nil, phase: .idle, number: nil,
        callerName: nil, updatedAt: Date()
    )
    @Published private(set) var isSendingAction = false
    @Published private(set) var isDialing = false
    @Published var errorMessage: String?
	@Published private(set) var pushStatus = "正在注册 Watch VoIP…"
	@Published private(set) var microphoneStatus = "正在检查麦克风权限…"

    @Published private(set) var hangupFeedback: WatchEndDelivery?
    @Published private(set) var companionReachable = false
    @Published private(set) var audioStatus = "音频尚未连接"
    private var endCheckTask: Task<Void, Never>?
    private var pendingEndCall: (call: WatchVoIPCall, action: String)?
    @Published private(set) var smsPage: WatchSMSPage?
    @Published private(set) var smsBusy = false
    @Published private(set) var confirmedReadSMSKeys = Set<String>()
    private func smsReadKey(_ row: WatchSMSRow) -> String { Data(row.agentID.utf8).base64EncodedString() + "." + row.id }
    func isSMSUnread(_ row: WatchSMSRow) -> Bool { !row.outgoing && row.unread && !confirmedReadSMSKeys.contains(smsReadKey(row)) }
    @Published private(set) var smsError: String?
    @Published private(set) var connectionTiming = "尚无连接测量"
    private var smsRequestID = UUID()
    private var connectionStartedAt: UInt64?
    private var companionMilliseconds: Int?
    private var handshakeMilliseconds: Int?
    private var firstFrameMilliseconds: Int?
    private let provider: CXProvider
    private let callController = CXCallController()
    private let media = WatchCallMediaBridge()
    private var pushRegistry: PKPushRegistry!
    private var connectivity: WCSession?
    private var directIncoming: (uuid: UUID, route: WatchDirectCallRoute)?
    private var directMonitor: Task<Void, Never>?
    private var voIPCall: WatchVoIPCall? {
        didSet {
            if oldValue?.uuid != voIPCall?.uuid {
                directMonitor?.cancel()
                directMonitor = nil
                directIncoming = nil
                answerReadiness.begin(uuid: voIPCall?.uuid)
                audioStatus = "音频尚未连接"
                if let next = voIPCall, pendingEndCall?.call.uuid != next.uuid {
                    pendingEndCall = nil
                    endCheckTask?.cancel()
                    hangupFeedback = nil
                }
            }
        }
    }
    private var pendingDialMirrors = WatchPendingDialMirrors()
    private var answerReadiness = WatchAnswerReadiness()
    private var answered = false
    private var answering = false
    private var dialRequestID: UUID?
    private var activeDialRequestID: UUID?
	private var pendingWatchToken: Data?
    private var endedCallIDs = Set<String>()
    private var endedCallUUIDs = Set<UUID>()
    private var latestMirrorUpdatedAt = [String: Date]()
    private let cloudMediaPreferenceKey = "airsim.watch.cloud-media-allowed"

    private var cloudMediaAllowed: Bool {
        WatchReliabilityPolicy.permitsCloud(
            vowlanOnly: (Bundle.main.object(forInfoDictionaryKey: "AirSIMVoWLANCallsOnly") as? String) == "YES",
            cachedPermission: UserDefaults.standard.bool(forKey: cloudMediaPreferenceKey))
    }

    var isUIFixture: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--watch-ui-fixture")
#else
        false
#endif
    }
    private func installUIFixture() {
        pushStatus = "模拟数据 · 不连接设备"
        microphoneStatus = "模拟界面"
        companionReachable = true
        let rows = [
            WatchSMSRow(id: "fixture-1", agentID: "fixture-agent", sender: "测试联系人", preview: "这是一条模拟短信，用于检查手表阅读体验。", timestamp: Date(), sim: "SIM 2", outgoing: false, unread: true),
            WatchSMSRow(id: "fixture-out", agentID: "fixture-agent", sender: "测试联系人", preview: "好的，这是我发送的模拟回复。", timestamp: Date().addingTimeInterval(-20), sim: "SIM 1", outgoing: true, unread: false),
            WatchSMSRow(id: "fixture-2", agentID: "fixture-agent", sender: "运营商服务", preview: "模拟长短信：中文、换行和数字 123456。", timestamp: Date().addingTimeInterval(-3600), sim: "SIM 1", outgoing: false, unread: false)]
        smsPage = WatchSMSPage(devices: [.init(id: "fixture-agent", name: "模拟安卓")], selectedAgentID: "fixture-agent", rows: rows, total: rows.count, generatedAt: Date())
        if ProcessInfo.processInfo.arguments.contains("--watch-ui-interrupt-sms") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.call = WatchCallPayload(callID: "fixture-call", callUUID: UUID(), phase: .incoming,
                    number: "模拟来电", callerName: "测试联系人", updatedAt: Date())
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--watch-ui-active") {
            call = WatchCallPayload(callID: "fixture-call", callUUID: UUID(), phase: .active, number: "模拟通话", callerName: "测试联系人", updatedAt: Date())
        }
        if ProcessInfo.processInfo.arguments.contains("--watch-ui-incoming") {
            call = WatchCallPayload(callID: "fixture-call", callUUID: UUID(), phase: .incoming, number: "模拟来电", callerName: "测试联系人", updatedAt: Date())
        }
    }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        if isUIFixture { installUIFixture(); return }

		requestMicrophonePermissionIfNeeded()

        provider.setDelegate(self, queue: .main)
        media.onRemoteEnded = { [weak self] uuid in
            DispatchQueue.main.async {
                guard WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: self?.voIPCall?.uuid, callbackUUID: uuid) else { return }
                self?.finishRemoteCall()
            }
        }
        media.onStatus = { [weak self] uuid, status in
            DispatchQueue.main.async {
                guard WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: self?.voIPCall?.uuid, callbackUUID: uuid) else { return }
                self?.handleMediaStatus(status)
            }
        }

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        pushRegistry = registry
		registry.desiredPushTypes = [.voIP]

        if WCSession.isSupported() {
            let session = WCSession.default
            connectivity = session
            session.delegate = self
            session.activate()
        }
    }

    var displayName: String {
        if let name = call.callerName, !name.isEmpty { return name }
        if let number = call.number, !number.isEmpty { return number }
        return "AirSIM"
    }

    var secondaryText: String {
        guard let number = call.number, number != displayName else {
            return call.phase == .idle ? "等待模块来电" : "Apple Watch 网络语音"
        }
        return number
    }

    func requestLatestState() {
        if isUIFixture { return }
        companionReachable = connectivity?.isReachable == true
        guard let connectivity, connectivity.isReachable else { return }
        connectivity.sendMessage(["action": "status", "watch_direct_version": 1], replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                if let routes = reply["watch_direct_routes"] as? [[String: Any]], !routes.isEmpty {
                    WatchDirectCallRoute.save(routes)
                }
                self?.receiveMirror(reply)
            }
        }, errorHandler: nil)
    }

    func answer() { request(answer: true) }
    func reject() { request(answer: false) }
    func end() { request(answer: false) }

    func dial(_ input: String) {
        if isUIFixture { errorMessage = "模拟界面不发起真实电话"; return }
        guard let number = WatchDialNumber.validated(input) else {
            errorMessage = "请输入有效的电话号码"
            return
        }
        guard voIPCall == nil, call.phase == .idle || call.phase == .ended,
              !isDialing else {
            errorMessage = "请先结束当前通话"
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            errorMessage = "请先允许手表使用麦克风"
            return
        }
        guard let connectivity, connectivity.isReachable else {
            errorMessage = "请先在附近打开已配对 iPhone 上的 AirSIM"
            return
        }
        endCheckTask?.cancel(); hangupFeedback = nil
        pendingDialMirrors.reset()
        beginConnectionTiming()
        let requestID = UUID()
        dialRequestID = requestID
        isDialing = true
        errorMessage = nil
        connectivity.sendMessage([
            "action": "dial", "request_id": requestID.uuidString, "number": number,
        ], replyHandler: { [weak self] reply in
            DispatchQueue.main.async { self?.receiveDialReply(reply, requestID: requestID) }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.dialRequestID == requestID else { return }
                self.dialRequestID = nil
                self.isDialing = false
                self.errorMessage = "iPhone 未响应拨号请求：\(error.localizedDescription)"
                self.abortCompanionDial(requestID)
            }
        })
    }

    func cancelDial() {
        guard let requestID = dialRequestID else { return }
        dialRequestID = nil
        isDialing = false
        abortCompanionDial(requestID)
    }

    private func receiveDialReply(_ reply: [String: Any], requestID: UUID) {
        guard dialRequestID == requestID else {
            if reply["ok"] as? Bool == true { abortCompanionDial(requestID) }
            return
        }
        dialRequestID = nil
        isDialing = false
        recordConnectionTiming("companion")
        guard reply["ok"] as? Bool == true else {
            errorMessage = reply["error"] as? String ?? "无法发起手表通话"
            return
        }
        guard reply["request_id"] as? String == requestID.uuidString else {
            errorMessage = "拨号回应与请求不匹配"
            abortCompanionDial(requestID)
            return
        }
        do {
            let outgoing = try WatchVoIPCall(outgoingReply: reply)
            if case .cloud = outgoing.media, !cloudMediaAllowed { throw WatchMediaError.localRouteUnavailable }
            guard !endedCallIDs.contains(outgoing.callID), !endedCallUUIDs.contains(outgoing.uuid) else {
                abortCompanionDial(requestID)
                errorMessage = "此通话已结束，未启动手表音频"
                return
            }
            voIPCall = outgoing
            if let buffered = pendingDialMirrors.consume(uuid: outgoing.uuid) { receiveMirror(buffered.dictionary) }
            else { requestLatestState() }
            activeDialRequestID = requestID
            answered = false
            publishLocalPhase(.connecting)
            let handle = CallKitNumberPresentation.handle(number: outgoing.number, fallback: "AirSIM")
            let action = CXStartCallAction(call: outgoing.uuid, handle: handle)
            isSendingAction = true
            callController.request(CXTransaction(action: action)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSendingAction = false
                    if let error {
                        self.errorMessage = "CallKit 无法发起呼叫：\(error.localizedDescription)"
                        self.abortCompanionDial(requestID)
                        self.publishLocalPhase(.ended)
                        self.voIPCall = nil
                        self.activeDialRequestID = nil
                        self.call = WatchCallPayload(
                            callID: "", callUUID: nil, phase: .idle, number: nil,
                            callerName: nil, updatedAt: Date()
                        )
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            abortCompanionDial(requestID)
        }
    }

    private func abortCompanionDial(_ requestID: UUID) {
        connectivity?.sendMessage(
            ["action": "cancel_dial", "request_id": requestID.uuidString],
            replyHandler: { _ in }, errorHandler: nil
        )
    }

    private func request(answer: Bool) {
        guard !isSendingAction else { return }
        if isUIFixture { errorMessage = "模拟界面不操作真实通话"; return }
        if voIPCall == nil, let uuid = call.callUUID, call.phase == .active || call.phase == .connecting {
            guard !answer else { errorMessage = "此电话由 iPhone 接听"; return }
            let target = call
            isSendingAction = true
            Task {
                defer { self.isSendingAction = false }
                do {
                    let reply = try await self.companionRequest(["action": "watch_phone_end", "call_id": target.callID,
                        "call_uuid": uuid.uuidString])
                    guard self.voIPCall == nil, self.call.matches(callID: target.callID, callUUID: uuid) else { return }
                    guard reply["ok"] as? Bool == true else { throw WatchCompanionError.remote(reply["error"] as? String ?? "iPhone 未确认结束") }
                    self.recordEnded(target.callID, uuid: uuid)
                    self.call = WatchCallPayload(callID: target.callID, callUUID: uuid, phase: .ended,
                        number: target.number, callerName: target.callerName, updatedAt: Date())
                    self.errorMessage = nil
                } catch { self.errorMessage = error.localizedDescription }
            }
            return
        }
        if answer, AVAudioApplication.shared.recordPermission != .granted {
            errorMessage = "请先允许手表麦克风，再接听此来电"
            requestMicrophonePermissionIfNeeded()
            return
        }
        guard let uuid = voIPCall?.uuid ?? call.callUUID else {
            errorMessage = "当前没有可操作的系统通话"
            return
        }
        errorMessage = nil
        if answer { beginConnectionTiming() }
        let action: CXCallAction = answer
            ? CXAnswerCallAction(call: uuid)
            : CXEndCallAction(call: uuid)
        isSendingAction = true
        callController.request(CXTransaction(action: action)) { [weak self] error in
            DispatchQueue.main.async {
                self?.isSendingAction = false
                if let error { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    private func publishLocalPhase(_ phase: WatchCallPhase, notifyPhone: Bool = true) {
        guard let voIPCall else { return }
        call = WatchCallPayload(
            callID: voIPCall.callID,
            callUUID: voIPCall.uuid,
            phase: phase,
            number: voIPCall.number,
            callerName: voIPCall.callerName,
            updatedAt: Date()
        )
        guard notifyPhone else { return }
        notifyCompanion(event: "watch_call_owner", extra: [
            "call_id": voIPCall.callID,
            "call_uuid": voIPCall.uuid.uuidString,
            "phase": phase.rawValue,
        ])
    }

    private func applyConfirmedAnswer() {
        guard let current = voIPCall, answered, answerReadiness.isActive(uuid: current.uuid) else { return }
        if current.isOutgoing, call.phase != .active {
            provider.reportOutgoingCall(with: current.uuid, connectedAt: Date())
        }
        publishLocalPhase(.active)
    }

    private func handleMediaStatus(_ status: String) {
        switch status {
        case "audio_ready", "pcm_first_frame":
            recordConnectionTiming(status == "audio_ready" ? "handshake" : "first_frame")
            audioStatus = status == "pcm_first_frame" ? "已收到安卓音频" : "VoWLAN 音频链路已连接"
            // True ringback may arrive before Android confirms answer.
            publishLocalPhase(WatchReliabilityPolicy.phaseAfterMediaReady(call.phase))
        case "active", "answer_ok":
            if cloudMediaAllowed { publishLocalPhase(.active) }
        case "local_failed":
            audioStatus = "手表无法连接安卓音频"
            errorMessage = "VoWLAN 音频连接失败，请检查手表与安卓的网络"
            if let current = voIPCall {
                if !current.isOutgoing, call.phase != .active {
                    provider.reportCall(with: current.uuid, endedAt: Date(), reason: .failed)
                    abandonIncomingHandoff(current)
                } else { requestLocalEnd(current) }
            }
        case "ownership_lost": finishRemoteCall()
        case "rejected", "ended", "remote_ended": finishRemoteCall()
        default: break
        }
    }

    private func finishRemoteCall() {
        guard let current = voIPCall else { return }
        recordEnded(current.callID, uuid: current.uuid)
        provider.reportCall(with: current.uuid, endedAt: Date(), reason: .remoteEnded)
        media.stop()
        publishLocalPhase(.ended, notifyPhone: false)
        voIPCall = nil
        resetAnswerState()
    }

    private func resetAnswerState() {
        answerReadiness.begin(uuid: voIPCall?.uuid)
        audioStatus = "音频尚未连接"
        answered = false
        answering = false
        activeDialRequestID = nil
    }

    private func receiveMirror(_ dictionary: [String: Any]) {
        if let allowed = dictionary["cloud_media_allowed"] as? Bool {
            UserDefaults.standard.set(allowed, forKey: cloudMediaPreferenceKey)
        }
        guard let payload = WatchCallPayload(dictionary: dictionary) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // An answer can arrive before the real-time dial reply. Preserve it
            // without tombstoning the new call as answered elsewhere.
            if self.voIPCall == nil, self.isDialing, payload.phase == .active {
                self.pendingDialMirrors.store(payload)
                return
            }
            let identityKeys = WatchCallMirrorPolicy.identityKeys(for: payload)
            let stale = identityKeys.contains {
                !WatchCallMirrorPolicy.isNewer(payload, than: self.latestMirrorUpdatedAt[$0])
            }
            let terminalForDisplay = WatchCallMirrorPolicy.acceptsTerminalForDisplay(payload, current: self.call)
            let strongTerminal = terminalForDisplay && payload.callUUID != nil && payload.callUUID == self.call.callUUID
            guard !stale || strongTerminal else { return }
            for key in identityKeys {
                self.latestMirrorUpdatedAt[key] = payload.updatedAt
            }
            if self.latestMirrorUpdatedAt.count > 128 {
                self.latestMirrorUpdatedAt.removeAll(keepingCapacity: true)
            }

            let ended = WatchCallMirrorPolicy.isTombstoned(
                payload, endedCallIDs: self.endedCallIDs, endedCallUUIDs: self.endedCallUUIDs
            )
            if ended && !WatchCallMirrorPolicy.acceptsTerminalForDisplay(payload, current: self.call) { return }
            let age = Date().timeIntervalSince(payload.updatedAt)

            if payload.phase == .incoming, self.voIPCall == nil,
               (-5...45).contains(age),
               let uuid = payload.callUUID,
               let incoming = try? WatchVoIPCall(userInfo: [
                    "event": "incoming_call", "call_id": payload.callID,
                    "call_uuid": uuid.uuidString, "number": payload.number ?? "",
                    "caller_name": payload.callerName ?? "",
                    "expires_at": Date().addingTimeInterval(45).timeIntervalSince1970,
               ]) {
                self.voIPCall = incoming
                self.resetAnswerState()
                self.call = payload
                let update = CallKitNumberPresentation.update(
                    number: incoming.number, callerName: incoming.callerName, fallback: "AirSIM")
                update.supportsHolding = false
                update.supportsGrouping = false
                update.supportsUngrouping = false
                update.supportsDTMF = false
                self.provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                    if let error {
                        Task { @MainActor [weak self] in
                            guard self?.voIPCall?.uuid == uuid else { return }
                            self?.errorMessage = error.localizedDescription
                            self?.voIPCall = nil
                        }
                    }
                }
            }

            guard let ownCall = self.voIPCall else {
                if payload.phase == .active || payload.phase == .ended {
                    self.recordEnded(payload.callID, uuid: payload.callUUID, aliases: payload.aliases)
                }
                self.call = payload
                return
            }
            guard payload.matches(callID: ownCall.callID, callUUID: ownCall.uuid) else { return }
            if payload.phase == .active { self.answerReadiness.noteAndroidActive(uuid: ownCall.uuid) }
            if payload.phase == .active, self.answered {
                if ownCall.isOutgoing, self.call.phase != .active {
                    self.provider.reportOutgoingCall(with: ownCall.uuid, connectedAt: Date())
                }
                self.call = payload
                return
            }
            if payload.phase == .active, !ownCall.isOutgoing, !self.answered, !self.answering {
                self.recordEnded(ownCall.callID, uuid: ownCall.uuid, aliases: payload.aliases)
                self.provider.reportCall(with: ownCall.uuid, endedAt: Date(), reason: .answeredElsewhere)
                self.media.stop()
                self.voIPCall = nil
                self.resetAnswerState()
            } else if payload.phase == .ended {
                self.recordEnded(ownCall.callID, uuid: ownCall.uuid, aliases: payload.aliases)
                self.provider.reportCall(with: ownCall.uuid, endedAt: Date(), reason: .remoteEnded)
                self.media.stop()
                self.voIPCall = nil
                self.resetAnswerState()
            }
            if self.voIPCall == nil { self.call = payload }
        }
    }


    private func sendWatchToken(_ token: Data) {
		pendingWatchToken = token
		pushStatus = "Watch VoIP 已注册，正在同步 iPhone…"
#if DEBUG
		print("[AirSIM Watch PushKit] token 已生成；字节数=\(token.count)，WC=\(connectivity?.activationState.rawValue ?? -1)")
#endif
        notifyCompanion(event: "watch_voip_registration", extra: [
            "watch_voip_token": token.map { String(format: "%02x", $0) }.joined(),
            "watch_bundle_id": Bundle.main.bundleIdentifier ?? "com.example.airsim.watchkitapp",
        ])
    }

    private func notifyCompanion(event: String, extra: [String: Any]) {
		guard let connectivity, connectivity.activationState == .activated else {
#if DEBUG
			print("[AirSIM Watch WC] 等待激活；event=\(event)")
#endif
			return
		}
        var payload = extra
        payload["event"] = event
		do {
			try connectivity.updateApplicationContext(payload)
		} catch {
#if DEBUG
			print("[AirSIM Watch WC] updateApplicationContext 失败：\(error.localizedDescription)")
#endif
		}
		connectivity.transferUserInfo(payload)
        if connectivity.isReachable {
            connectivity.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
		if event == "watch_voip_registration" {
			pushStatus = "Watch VoIP 已同步"
		}
#if DEBUG
		print("[AirSIM Watch WC] 已发送；event=\(event)，reachable=\(connectivity.isReachable)，queued=\(connectivity.outstandingUserInfoTransfers.count)")
#endif
    }

    private func recordEnded(_ callID: String, uuid: UUID? = nil, aliases: [String] = []) {
        if endedCallUUIDs.count + endedCallIDs.count >= 64 {
            endedCallIDs.removeAll(); endedCallUUIDs.removeAll()
        }
        if let uuid {
            endedCallUUIDs.insert(uuid)
        } else {
            endedCallIDs.insert(callID)
            aliases.forEach { endedCallIDs.insert($0) }
        }
    }

    private func requestLocalEnd(_ call: WatchVoIPCall) {
        if let directIncoming, directIncoming.uuid == call.uuid {
            endDirectIncoming(call, route: directIncoming.route)
        } else {
            sendLocalEnd(call, action: "watch_local_end")
        }
    }

    /// Legacy replies acknowledge delivery only. New companions advertise a
    /// separate, scoped Android terminal-state check.
    private func sendLocalEnd(_ call: WatchVoIPCall, action: String) {
        endCheckTask?.cancel()
        pendingEndCall = (call, action)
        if hangupFeedback?.uuid != call.uuid || hangupFeedback?.callID != call.callID {
            hangupFeedback = WatchEndDelivery(callID: call.callID, uuid: call.uuid)
        }
        guard let connectivity, connectivity.activationState == .activated else {
            hangupFeedback?.record(callID: call.callID, uuid: call.uuid, accepted: false, now: Date())
            return
        }
        let payload: [String: Any] = ["event": action, "action": action,
            "call_id": call.callID, "call_uuid": call.uuid.uuidString]
        // Persist the scoped end before watchOS dismisses/suspends the call UI.
        // The companion deduplicates this backup against the live RPC.
        connectivity.transferUserInfo(payload)
        // Confirmation must not wait forever for the live RPC reply: watchOS
        // may close its call screen before that callback arrives.
        startAndroidEndCheck(call)
        guard connectivity.isReachable else {
            hangupFeedback?.record(callID: call.callID, uuid: call.uuid, accepted: false, now: Date())
            startAndroidEndCheck(call)
            return
        }
        connectivity.sendMessage(payload, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard let self, self.hangupFeedback?.callID == call.callID,
                      self.hangupFeedback?.uuid == call.uuid else { return }
                let accepted = reply["ok"] as? Bool == true
                self.hangupFeedback?.record(callID: call.callID, uuid: call.uuid, accepted: accepted, now: Date())
                if reply["end_confirmation_supported"] as? Bool == true {
                    self.pendingEndCall = nil
                    self.startAndroidEndCheck(call)
                    return
                }
                if accepted {
                    self.pendingEndCall = nil
                    self.hangupFeedback?.useLegacyAcknowledgement()
                    self.endCheckTask?.cancel()
                    self.endCheckTask = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                        guard let self, self.hangupFeedback?.callID == call.callID,
                              self.hangupFeedback?.uuid == call.uuid,
                              self.hangupFeedback?.shouldDismiss(at: Date()) == true else { return }
                        self.hangupFeedback = nil
                    }
                }
            }
        }, errorHandler: { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.hangupFeedback?.callID == call.callID,
                      self.hangupFeedback?.uuid == call.uuid else { return }
                guard self.hangupFeedback?.acknowledgedAt == nil else { return }
                self.hangupFeedback?.record(callID: call.callID, uuid: call.uuid, accepted: false, now: Date())
                self.connectivity?.transferUserInfo(payload)
                self.startAndroidEndCheck(call)
            }
        })
    }

    private func beginConnectionTiming() {
        connectionStartedAt = DispatchTime.now().uptimeNanoseconds
        companionMilliseconds = nil; handshakeMilliseconds = nil; firstFrameMilliseconds = nil
        connectionTiming = "正在测量连接耗时"
    }
    private func recordConnectionTiming(_ event: String) {
        guard let start = connectionStartedAt else { return }
        let milliseconds = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        if event == "companion" { companionMilliseconds = milliseconds }
        if event == "handshake", handshakeMilliseconds == nil { handshakeMilliseconds = milliseconds }
        if event == "first_frame", firstFrameMilliseconds == nil { firstFrameMilliseconds = milliseconds }
        connectionTiming = [companionMilliseconds.map { "iPhone 回应 \($0) ms" },
                            handshakeMilliseconds.map { "握手完成 \($0) ms" },
                            firstFrameMilliseconds.map { "收到音频 \($0) ms" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func startAndroidEndCheck(_ call: WatchVoIPCall) {
        hangupFeedback?.beginVerification()
        endCheckTask?.cancel()
        endCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let current = self?.hangupFeedback
                let delay = current?.confirmedAt.map { max(0.05, 5 - Date().timeIntervalSince($0)) }
                    ?? ((current?.checks ?? 0) < 10 ? 2.0 : 15.0)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard let self, self.hangupFeedback?.callID == call.callID,
                      self.hangupFeedback?.uuid == call.uuid else { return }
                if self.hangupFeedback?.shouldDismiss(at: Date()) == true { self.hangupFeedback = nil; return }
                if self.hangupFeedback?.confirmedAt != nil { continue }
                do {
                    let reply = try await self.companionRequest(["action": "watch_local_end_status",
                        "call_id": call.callID, "call_uuid": call.uuid.uuidString])
                    guard !Task.isCancelled, self.hangupFeedback?.uuid == call.uuid else { return }
                    let matches = reply["call_id"] as? String == call.callID
                        && (reply["call_uuid"] as? String).flatMap(UUID.init(uuidString:)) == call.uuid
                    self.hangupFeedback?.verify(callID: call.callID, uuid: call.uuid,
                        confirmed: matches && reply["confirmed"] as? Bool == true,
                        reachable: matches && reply["ok"] as? Bool == true, now: Date(),
                        issue: reply["error"] as? String == "unknown_call" ? "暂无此通话的安卓结束回执" : nil)
                    if matches && reply["confirmed"] as? Bool == true { self.pendingEndCall = nil }
                } catch {
                    guard !Task.isCancelled, self.hangupFeedback?.uuid == call.uuid else { return }
                    self.hangupFeedback?.verify(callID: call.callID, uuid: call.uuid, confirmed: false, reachable: false, now: Date())
                }
            }
        }
    }

    @MainActor private func companionRequest(_ payload: [String: Any], timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard let connectivity, connectivity.isReachable else { throw WatchCompanionError.unreachable }
        return try await sendCompanionMessage(payload, on: connectivity, timeout: timeout)
    }

    private func sendCompanionMessage(_ payload: [String: Any], on connectivity: WCSession,
                                      timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let gate = WatchReplyGate { continuation.resume(with: $0) }
            connectivity.sendMessage(payload, replyHandler: { gate.finish(.success($0)) },
                                     errorHandler: { gate.finish(.failure($0)) })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.finish(.failure(WatchCompanionError.timeout)) }
        }
    }

    @MainActor func refreshSMS(agentID: String? = nil) async {
        if isUIFixture { return }
        let requestID = UUID(); smsRequestID = requestID
        confirmedReadSMSKeys.removeAll()
        smsBusy = true; smsError = nil
        defer { if smsRequestID == requestID { smsBusy = false } }
        var payload: [String: Any] = ["action": "watch_sms_list"]
        if let agentID { payload["agent_id"] = agentID }
        do {
            let reply = try await companionRequest(payload)
            guard smsRequestID == requestID, !Task.isCancelled else { return }
            guard reply["ok"] as? Bool == true, let data = reply["sms_data"] as? Data else {
                throw WatchCompanionError.remote(reply["error"] as? String ?? "请更新 iPhone 配套版本")
            }
            let page = try JSONDecoder().decode(WatchSMSPage.self, from: data)
            guard agentID == nil || page.selectedAgentID == agentID else { throw WatchCompanionError.remote("短信设备不匹配") }
            guard page.rows.allSatisfy({ $0.agentID == page.selectedAgentID }) else { throw WatchCompanionError.remote("短信来源不匹配") }
            smsPage = page
        } catch { if smsRequestID == requestID { smsError = error.localizedDescription } }
    }
    func replyOptions(for conversation: WatchSMSConversation) async throws -> WatchSMSReplyOptions {
        if isUIFixture {
            return .init(recipient: "13800138000", slots: [
                .init(id: "sim1", label: "SIM 1", carrier: "中国移动"),
                .init(id: "sim2", label: "SIM 2", carrier: "中国联通")
            ], selectedID: "sim1")
        }
        let reply = try await companionRequest(["action": "watch_sms_reply_options",
            "agent_id": conversation.agentID, "peer": conversation.peer])
        guard reply["ok"] as? Bool == true, let data = reply["options"] as? Data else {
            throw WatchCompanionError.remote(reply["error"] as? String ?? "无法读取发送卡")
        }
        let options = try JSONDecoder().decode(WatchSMSReplyOptions.self, from: data)
        guard WatchSMSConversationPolicy.peer(options.recipient) == conversation.peer else {
            throw WatchCompanionError.remote("短信收件人与当前会话不匹配")
        }
        return options
    }

    func sendReply(to conversation: WatchSMSConversation, text: String, slotID: String) async -> WatchSMSReplyOutcome {
        if isUIFixture { return .sent }
        do {
            let reply = try await companionRequest(["action": "watch_sms_reply_send", "agent_id": conversation.agentID,
                "peer": conversation.peer, "body": text, "slot_id": slotID,
                "expires_at": Date().addingTimeInterval(15).timeIntervalSince1970], timeout: 82)
            if reply["ok"] as? Bool == true { return .sent }
            if reply["uncertain"] as? Bool == true { return .uncertain }
            return .failed(reply["error"] as? String ?? "短信未发送")
        } catch WatchCompanionError.unreachable {
            return .failed("iPhone 当前不可通信，尚未发送")
        } catch { return .uncertain }
    }

    @MainActor func loadConversation(_ conversation: WatchSMSConversation) async throws -> WatchSMSPage {
        let prefix = Data(conversation.agentID.utf8).base64EncodedString() + "."
        confirmedReadSMSKeys = confirmedReadSMSKeys.filter { !$0.hasPrefix(prefix) }
        if isUIFixture {
            return WatchSMSPage(devices: smsPage?.devices ?? [], selectedAgentID: conversation.agentID,
                rows: conversation.rows, total: conversation.rows.count, generatedAt: Date())
        }
        let reply = try await companionRequest(["action": "watch_sms_thread", "agent_id": conversation.agentID, "peer": conversation.peer])
        try Task.checkCancellation()
        guard reply["ok"] as? Bool == true, let data = reply["sms_data"] as? Data else {
            throw WatchCompanionError.remote(reply["error"] as? String ?? "会话读取失败")
        }
        let page = try JSONDecoder().decode(WatchSMSPage.self, from: data)
        guard page.selectedAgentID == conversation.agentID,
              page.rows.allSatisfy({ $0.agentID == conversation.agentID && WatchSMSConversationPolicy.peer($0.sender) == conversation.peer }) else {
            throw WatchCompanionError.remote("短信会话来源不匹配")
        }
        return page
    }

    @MainActor func loadSMS(_ row: WatchSMSRow) async throws -> WatchSMSDetail {
        if isUIFixture {
            return WatchSMSDetail(row: row, body: String(repeating: "这是一条用于模拟阅读的短信正文。\n中文、数字 123456 和表情🙂。\n", count: 5), truncated: false)
        }
        let reply = try await companionRequest(["action": "watch_sms_detail", "agent_id": row.agentID, "message_id": row.id])
        guard reply["ok"] as? Bool == true, let data = reply["sms_data"] as? Data else {
            throw WatchCompanionError.remote(reply["error"] as? String ?? "短信暂不可用")
        }
        let detail = try JSONDecoder().decode(WatchSMSDetail.self, from: data)
        guard WatchSMSPolicy.matches(detail.row, agentID: row.agentID, id: row.id) else { throw WatchCompanionError.remote("短信来源不匹配") }
        return detail
    }
    @MainActor func markSMSRead(_ row: WatchSMSRow) async -> Bool {
        if isUIFixture { confirmedReadSMSKeys.insert(smsReadKey(row)); return true }
        guard let reply = try? await companionRequest(["action": "watch_sms_read", "agent_id": row.agentID, "message_id": row.id]),
              reply["ok"] as? Bool == true else { return false }
        confirmedReadSMSKeys.insert(smsReadKey(row))
        if let page = smsPage {
            smsPage = WatchSMSPage(devices: page.devices, selectedAgentID: page.selectedAgentID,
                rows: page.rows.map { value in
                    guard value.id == row.id, value.agentID == row.agentID else { return value }
                    return WatchSMSRow(id: value.id, agentID: value.agentID, sender: value.sender,
                        preview: value.preview, timestamp: value.timestamp, sim: value.sim, outgoing: value.outgoing, unread: false)
                }, total: page.total, generatedAt: page.generatedAt)
        }
        return true
    }

    private func retryPendingEndDelivery() {
        guard let pending = pendingEndCall, connectivity?.isReachable == true,
              hangupFeedback?.confirmedAt == nil else { return }
        sendLocalEnd(pending.call, action: pending.action)
    }

	private func requestMicrophonePermissionIfNeeded() {
		switch AVAudioApplication.shared.recordPermission {
		case .granted:
			microphoneStatus = "麦克风已授权"
		case .denied:
			microphoneStatus = "请在手表设置中允许麦克风"
		case .undetermined:
			AVAudioApplication.requestRecordPermission { [weak self] granted in
				DispatchQueue.main.async {
					self?.microphoneStatus = granted ? "麦克风已授权" : "请在手表设置中允许麦克风"
				}
			}
		@unknown default:
			microphoneStatus = "麦克风权限状态未知"
		}
	}
}

extension WatchCallSession: @preconcurrency PKPushRegistryDelegate {
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        sendWatchToken(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        notifyCompanion(event: "watch_voip_registration", extra: [
            "watch_voip_token": "",
            "watch_bundle_id": Bundle.main.bundleIdentifier ?? "com.example.airsim.watchkitapp",
        ])
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        do {
            let incoming = try WatchVoIPCall(userInfo: payload.dictionaryPayload)
            if voIPCall?.callID == incoming.callID || voIPCall?.uuid == incoming.uuid
                || endedCallIDs.contains(incoming.callID) || endedCallUUIDs.contains(incoming.uuid) {
                completion()
                return
            }
            voIPCall = incoming
            resetAnswerState()
            errorMessage = nil

            let update = CallKitNumberPresentation.update(
                number: incoming.number, callerName: incoming.callerName, fallback: incoming.displayName)
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportNewIncomingCall(with: incoming.uuid, update: update) { [weak self] error in
                if let error {
                    Task { @MainActor [weak self] in
                        guard self?.voIPCall?.uuid == incoming.uuid else { return }
                        self?.voIPCall = nil
                        self?.errorMessage = error.localizedDescription
                    }
                }
                completion()
            }
        } catch {
            errorMessage = error.localizedDescription
            completion()
        }
    }
}

extension WatchCallSession: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        cancelDial()
        isSendingAction = false
        if let current = voIPCall, !current.isOutgoing, call.phase != .active {
            abandonIncomingHandoff(current); return
        }
        if let voIPCall { recordEnded(voIPCall.callID, uuid: voIPCall.uuid) }
        if let voIPCall, case .local = voIPCall.media { requestLocalEnd(voIPCall) }
        if voIPCall != nil { publishLocalPhase(.ended) }
        if let activeDialRequestID { abortCompanionDial(activeDialRequestID) }
        media.stop(); voIPCall = nil; answered = false; answering = false
        activeDialRequestID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let voIPCall, voIPCall.isOutgoing, voIPCall.uuid == action.callUUID else {
            action.fail(); return
        }
        do {
            try media.prepareForCallKit()
            provider.reportOutgoingCall(with: voIPCall.uuid, startedConnectingAt: Date())
            let update = CallKitNumberPresentation.update(number: voIPCall.number, callerName: voIPCall.callerName, fallback: "AirSIM")
            update.supportsDTMF = false
            provider.reportCall(with: voIPCall.uuid, updated: update)
            media.connect(to: voIPCall.media, callUUID: voIPCall.uuid) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.voIPCall?.uuid == voIPCall.uuid else { action.fail(); return }
                    if let error {
                        self.errorMessage = "手表语音连接失败：\(error.localizedDescription)"
                        action.fail()
                        self.provider.reportCall(with: voIPCall.uuid, endedAt: Date(), reason: .failed)
                        if let requestID = self.activeDialRequestID { self.abortCompanionDial(requestID) }
                        self.publishLocalPhase(.ended)
                        self.media.stop()
                        self.voIPCall = nil
                        self.activeDialRequestID = nil
                    } else {
                        self.answered = true
                        self.answerReadiness.noteMediaReady(uuid: voIPCall.uuid)
                        self.applyConfirmedAnswer()
                        if case .cloud = voIPCall.media {
                            self.media.sendControl("answer", call: voIPCall)
                        }
                        action.fulfill()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            action.fail()
            if let activeDialRequestID { abortCompanionDial(activeDialRequestID) }
            publishLocalPhase(.ended)
            media.stop()
            self.voIPCall = nil
            activeDialRequestID = nil
        }
    }

    /// A failed handoff is local to Watch. Only an explicit end/reject action
    /// may terminate the Android call or withdraw the iPhone ringing surface.
    private func abandonIncomingHandoff(_ current: WatchVoIPCall) {
        guard !current.isOutgoing, voIPCall?.uuid == current.uuid else { return }
        notifyCompanion(event: "watch_call_owner", extra: [
            "phase": "handoff_failed", "call_id": current.callID,
            "call_uuid": current.uuid.uuidString,
        ])
        recordEnded(current.callID, uuid: current.uuid)
        publishLocalPhase(.ended, notifyPhone: false)
        media.stop()
        voIPCall = nil
        resetAnswerState()
    }

    private func directRouteForIncoming(_ incoming: WatchVoIPCall) async -> WatchDirectCallRoute? {
        guard let agentID = incoming.agentID, let route = WatchDirectCallRoute.load(agentID: agentID),
              let state = try? await route.status(callID: incoming.callID),
              state == "incoming" || state == "waiting" else { return nil }
        return route
    }

    private func monitorDirectIncoming(_ incoming: WatchVoIPCall, route: WatchDirectCallRoute) {
        directMonitor?.cancel()
        directMonitor = Task { [weak self] in
            while !Task.isCancelled, let self, self.voIPCall?.uuid == incoming.uuid {
                if let state = try? await route.status(callID: incoming.callID),
                   !Task.isCancelled, self.voIPCall?.uuid == incoming.uuid {
                    if state == "active" {
                        self.answerReadiness.noteAndroidActive(uuid: incoming.uuid)
                        if self.call.phase != .active { self.applyConfirmedAnswer() }
                    } else if state == "ended" || state == "failed" || state == "disconnected" {
                        self.finishRemoteCall()
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func endDirectIncoming(_ incoming: WatchVoIPCall, route: WatchDirectCallRoute) {
        endCheckTask?.cancel()
        hangupFeedback = WatchEndDelivery(callID: incoming.callID, uuid: incoming.uuid)
        hangupFeedback?.beginVerification()
        endCheckTask = Task { [weak self] in
            _ = try? await route.command("hangup", callID: incoming.callID)
            for _ in 0..<8 {
                guard let self, !Task.isCancelled, self.hangupFeedback?.uuid == incoming.uuid else { return }
                let state = try? await route.status(callID: incoming.callID)
                guard !Task.isCancelled, self.hangupFeedback?.uuid == incoming.uuid else { return }
                let ended = state == "ended" || state == "failed" || state == "disconnected"
                self.hangupFeedback?.verify(callID: incoming.callID, uuid: incoming.uuid, confirmed: ended,
                                            reachable: state != nil, now: Date())
                if ended {
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled, self.hangupFeedback?.uuid == incoming.uuid { self.hangupFeedback = nil }
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            if self?.hangupFeedback?.uuid == incoming.uuid {
                self?.hangupFeedback?.verify(callID: incoming.callID, uuid: incoming.uuid, confirmed: false,
                                             reachable: false, now: Date(), issue: "未收到安卓挂断确认")
            }
        }
    }

    private func requestIncomingAnswer(_ incoming: WatchVoIPCall) async throws -> [String: Any] {
        guard let connectivity else { throw WatchCompanionError.unreachable }
        let clock = ContinuousClock()
        let retryUntil = clock.now.advanced(by: .seconds(4))
        let payload: [String: Any] = [
            "action": "watch_local_answer",
            "call_id": incoming.callID,
            "call_uuid": incoming.uuid.uuidString,
            "agent_id": incoming.agentID ?? "",
        ]
        var attempts = 0
        while clock.now < retryUntil {
            guard answering, voIPCall?.uuid == incoming.uuid else { throw CancellationError() }
            if connectivity.activationState == .activated {
                // A reachability snapshot in the system call UI can lag the
                // live route. Sending gives the framework a chance to wake iPhone.
                attempts += 1
                do {
                    return try await sendCompanionMessage(payload, on: connectivity, timeout: 6)
                } catch {
                    let failure = error as NSError
                    NSLog("[AirSIM Watch] answer delivery attempt %d failed: %@/%ld", attempts, failure.domain, failure.code)
                    // Retry only when WatchConnectivity explicitly could not deliver.
                    // A reply timeout might mean Android has already accepted the call.
                    guard failure.domain == WCErrorDomain,
                          failure.code == WCError.Code.notReachable.rawValue
                            || failure.code == WCError.Code.sessionNotActivated.rawValue else { throw error }
                }
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        throw WatchCompanionError.unreachable
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let voIPCall, voIPCall.uuid == action.callUUID, !answering, !answered else { action.fail(); return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            errorMessage = "手表麦克风未授权，请授权后重试接听"
            abandonIncomingHandoff(voIPCall)
            action.fail()
            return
        }
        errorMessage = nil
        let started = DispatchTime.now().uptimeNanoseconds
        NSLog("[AirSIM Watch] answer started, companion=%d", connectivity?.isReachable == true ? 1 : 0)
        beginConnectionTiming()
        do {
            try media.prepareForCallKit()
            answering = true
            publishLocalPhase(.connecting)
            let connect: (WatchCallMedia) -> Void = { [weak self] selectedMedia in
                guard let self else { action.fail(); return }
                NSLog("[AirSIM Watch] answer media stage after %llu ms", (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                self.media.connect(to: selectedMedia, callUUID: voIPCall.uuid) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.voIPCall?.uuid == voIPCall.uuid else { action.fail(); return }
                    if let error {
                        self.errorMessage = error.localizedDescription
                        self.answering = false
                        self.abandonIncomingHandoff(voIPCall)
                        action.fail()
                        self.provider.reportCall(with: voIPCall.uuid, endedAt: Date(), reason: .failed)
                    } else {
                        self.answered = true
                        self.answerReadiness.noteMediaReady(uuid: voIPCall.uuid)
                        self.applyConfirmedAnswer()
                        self.answering = false
                        if case .cloud = selectedMedia {
                            self.media.sendControl("answer", call: voIPCall)
                        }
                        action.fulfill()
                    }
                }
                }
            }
            Task {
                do {
                    if let route = await directRouteForIncoming(voIPCall) {
                        guard self.voIPCall?.uuid == voIPCall.uuid, answering else { return }
                        directIncoming = (voIPCall.uuid, route)
                        try await route.command("answer", callID: voIPCall.callID)
                        guard self.voIPCall?.uuid == voIPCall.uuid, answering else { return }
                        self.voIPCall = voIPCall.usingLocalMedia(route.pcm)
                        monitorDirectIncoming(voIPCall, route: route)
                        connect(.local(route.pcm))
                        return
                    }
                    guard self.voIPCall?.uuid == voIPCall.uuid, answering else { return }
                    let reply = try await requestIncomingAnswer(voIPCall)
                    guard self.voIPCall?.uuid == voIPCall.uuid, answering else { return }
                    recordConnectionTiming("companion")
                    if let allowed = reply["cloud_media_allowed"] as? Bool {
                        UserDefaults.standard.set(allowed, forKey: cloudMediaPreferenceKey)
                    }
                    guard reply["ok"] as? Bool == true,
                          reply["call_id"] as? String == voIPCall.callID,
                          (reply["call_uuid"] as? String).flatMap(UUID.init(uuidString:)) == voIPCall.uuid,
                          let endpoint = WatchLocalPCMEndpoint(dictionary: reply) else {
                        throw WatchCompanionError.remote(reply["error"] as? String ?? "iPhone 未返回此来电的 VoWLAN 路由")
                    }
                    self.voIPCall = voIPCall.usingLocalMedia(endpoint)
                    connect(.local(endpoint))
                } catch {
                    guard self.voIPCall?.uuid == voIPCall.uuid, answering else { return }
                    if directIncoming == nil, case .cloud = voIPCall.media, cloudMediaAllowed {
                        connect(voIPCall.media)
                    } else {
                        if case WatchCompanionError.unreachable = error {
                            errorMessage = "接听时未能联系 AirSIM，请在 iPhone 上接听"
                        } else if case WatchCompanionError.timeout = error {
                            errorMessage = "iPhone 接听请求回应超时，请在 iPhone 查看通话"
                        } else {
                            errorMessage = error.localizedDescription
                        }
                        abandonIncomingHandoff(voIPCall)
                        action.fail()
                    }
                }
            }
        } catch {
            answering = false
            errorMessage = error.localizedDescription
            abandonIncomingHandoff(voIPCall)
            action.fail()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let voIPCall, voIPCall.uuid == action.callUUID else { action.fulfill(); return }
        recordEnded(voIPCall.callID, uuid: voIPCall.uuid)
        if case .local = voIPCall.media {
            requestLocalEnd(voIPCall)
        } else if case .pendingLocal = voIPCall.media, !answered {
            sendLocalEnd(voIPCall, action: "watch_local_reject")
        } else if voIPCall.isOutgoing && !answered, let activeDialRequestID {
            abortCompanionDial(activeDialRequestID)
        } else {
            media.sendControl(answered || voIPCall.isOutgoing ? "end" : "reject", call: voIPCall)
        }
        publishLocalPhase(.ended)
        media.stop(); self.voIPCall = nil; answered = false; answering = false
        activeDialRequestID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let callAction = action as? CXCallAction, let current = voIPCall,
              WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: current.uuid, callbackUUID: callAction.callUUID) else { return }
        if action is CXAnswerCallAction {
            isSendingAction = false
            errorMessage = "手表接听超时，请在 iPhone 查看来电"
            abandonIncomingHandoff(current)
            provider.reportCall(with: current.uuid, endedAt: Date(), reason: .failed)
            return
        }
        if case .local = current.media { requestLocalEnd(current) }
        if let requestID = activeDialRequestID { abortCompanionDial(requestID) }
        isSendingAction = false
        errorMessage = "手表通话操作超时，已停止本机音频"
        recordEnded(current.callID, uuid: current.uuid)
        provider.reportCall(with: current.uuid, endedAt: Date(), reason: .failed)
        publishLocalPhase(.ended)
        media.stop()
        voIPCall = nil
        resetAnswerState()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        media.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        do {
            // The Watch owns both ends of the audio session; watchOS selects its output route.
            try media.startAudio()
            if voIPCall?.isOutgoing != true,
               voIPCall?.media != .pendingLocal,
               !isLocalMedia {
                publishLocalPhase(.active)
            }
        } catch {
            errorMessage = "手表语音启动失败：\(error.localizedDescription)"
            if let current = voIPCall, !current.isOutgoing, call.phase != .active {
                provider.reportCall(with: current.uuid, endedAt: Date(), reason: .failed)
                abandonIncomingHandoff(current); return
            }
            if let voIPCall, case .local = voIPCall.media { requestLocalEnd(voIPCall) }
            if let voIPCall { provider.reportCall(with: voIPCall.uuid, endedAt: Date(), reason: .failed) }
            if let activeDialRequestID { abortCompanionDial(activeDialRequestID) }
            if voIPCall != nil { publishLocalPhase(.ended) }
            media.stop()
            voIPCall = nil
            activeDialRequestID = nil
        }
    }

    private var isLocalMedia: Bool {
        guard let voIPCall else { return false }
        if case .local = voIPCall.media { return true }
        return false
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        media.stopAudio()
    }
}

extension WatchCallSession: WCSessionDelegate {
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.companionReachable = session.isReachable
            if session.isReachable {
                self.retryPendingEndDelivery()
                if let token = self.pendingWatchToken ?? self.pushRegistry.pushToken(for: .voIP) {
                    self.sendWatchToken(token)
                }
                self.requestLatestState()
            }
        }
    }

    nonisolated func session(_ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activationState == .activated else {
                self.pushStatus = "iPhone 连接尚未激活"; return
            }
            if let token = self.pendingWatchToken ?? self.pushRegistry.pushToken(for: .voIP) {
                self.sendWatchToken(token)
            }
            if !session.receivedApplicationContext.isEmpty { self.receiveMirror(session.receivedApplicationContext) }
            self.retryPendingEndDelivery()
            self.requestLatestState()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in self?.receiveMirror(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in self?.receiveMirror(userInfo) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in self?.receiveMirror(message) }
    }
}

private final class WatchCallMediaBridge: @unchecked Sendable {
    var onRemoteEnded: ((UUID) -> Void)?
    var onStatus: ((UUID, String) -> Void)?

    private let queue = DispatchQueue(label: "com.example.airsim.watch-media")
    private var webSocket: URLSessionWebSocketTask?
    private var localTransport: WatchLocalPCMTransport?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var encoder: WatchVoicePCMEncoder?
    private var uplinkBuffer = Data()
    private var scheduledFrames = 0
    private var initialPCM = WatchInitialPCMBuffer()
    private var playbackUUID: UUID? // Main-thread ownership, including queued playback work.
    private var muted = false
    private var stopped = true
    private var mediaGeneration = UUID()
    private var callUUID: UUID?

    func prepareForCallKit() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
    }

    func connect(to media: WatchCallMedia, callUUID: UUID, completion: @escaping (Error?) -> Void) {
        if Thread.isMainThread { playbackUUID = callUUID; initialPCM.begin() }
        else {
            DispatchQueue.main.async { [weak self] in
                self?.playbackUUID = callUUID; self?.initialPCM.begin()
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            stopped = false
            self.callUUID = callUUID
            mediaGeneration = UUID()
            let generation = mediaGeneration
            switch media {
            case let .cloud(url):
                guard (Bundle.main.object(forInfoDictionaryKey: "AirSIMVoWLANCallsOnly") as? String) != "YES" else {
                    completion(WatchMediaError.localRouteUnavailable); return
                }
                let socket = URLSession(configuration: .ephemeral).webSocketTask(with: url)
                webSocket = socket
                socket.resume()
                receiveNext(socket)
                socket.sendPing { error in completion(error) }
            case let .local(endpoint):
                var completed = false // Accessed only on the media queue.
                var receivedFrame = false
                let transport = WatchLocalPCMTransport(
                    endpoint: endpoint,
                    onPCM: { [weak self] data in
                        self?.queue.async { [weak self] in
                            guard let self, !self.stopped, self.mediaGeneration == generation else { return }
                            if !receivedFrame { receivedFrame = true; self.onStatus?(callUUID, "pcm_first_frame") }
                            DispatchQueue.main.async {
                                guard WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: self.playbackUUID, callbackUUID: callUUID) else { return }
                                self.schedulePlayback(data)
                            }
                        }
                    },
                    onReady: { [weak self] in
                        self?.queue.async { [weak self] in
                            guard let self, !self.stopped, self.mediaGeneration == generation else { return }
                            self.onStatus?(callUUID, "audio_ready")
                            if !completed { completed = true; completion(nil) }
                        }
                    },
                    onFailure: { [weak self] message in
                        self?.queue.async { [weak self] in
                            guard let self, !self.stopped, self.mediaGeneration == generation else { return }
                            if !completed { completed = true; completion(WatchMediaError.localRouteUnavailable) }
                            self.onStatus?(callUUID, "local_failed")
                            self.onRemoteEnded?(callUUID)
                            NSLog("[AirSIM Watch PCM] %@", message)
                        }
                    }
                )
                localTransport = transport
                transport.start()
            case .pendingLocal:
                completion(WatchMediaError.localRouteUnavailable)
            }
        }
    }

    func sendControl(_ action: String, call: WatchVoIPCall) {
        guard let data = try? JSONSerialization.data(withJSONObject: call.controlMessage(action: action)),
              let text = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in self?.webSocket?.send(.string(text)) { _ in } }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in self?.muted = muted; self?.encoder?.setMuted(muted) }
    }

    func startAudio() throws {
        if engine?.isRunning == true { return }
		guard AVAudioApplication.shared.recordPermission == .granted else {
			throw WatchMediaError.microphonePermissionDenied
		}
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let encoder = WatchVoicePCMEncoder()
        encoder.setMuted(muted)
        engine.attach(player)
        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
            channels: 1, interleaved: false
        ) else { throw WatchMediaError.invalidAudioFormat }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate >= 8_000 else {
            throw WatchMediaError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm = encoder.encode(buffer)
            if !pcm.isEmpty { enqueueUplink(pcm) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine; self.player = player; self.encoder = encoder
        let earlyPCM = initialPCM.drain()
        if !earlyPCM.isEmpty { schedulePlayback(earlyPCM) }
    }

    func stopAudio() {
        initialPCM.discard()
        if engine != nil { engine?.inputNode.removeTap(onBus: 0) }
        player?.stop(); engine?.stop()
        engine = nil; player = nil; encoder = nil; scheduledFrames = 0
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = true
            mediaGeneration = UUID()
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
            localTransport?.stop()
            localTransport = nil
            uplinkBuffer.removeAll(keepingCapacity: false)
        }
        if Thread.isMainThread { playbackUUID = nil; stopAudio() }
        else { DispatchQueue.main.async { [weak self] in self?.playbackUUID = nil; self?.stopAudio() } }
    }

    private func receiveNext(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            queue.async {
                guard !self.stopped, self.webSocket === socket else { return }
                switch result {
                case let .success(.data(data)):
                    let owner = self.callUUID
                    DispatchQueue.main.async {
                        guard let owner, WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: self.playbackUUID, callbackUUID: owner) else { return }
                        self.schedulePlayback(data)
                    }
                    self.receiveNext(socket)
                case let .success(.string(text)):
                    self.consumeControl(text); self.receiveNext(socket)
                case .success:
                    self.receiveNext(socket)
                case .failure:
                    if let uuid = self.callUUID { self.onRemoteEnded?(uuid) }
                }
            }
        }
    }

    private func consumeControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let status = object["status"] as? String ?? object["event"] as? String { if let uuid = callUUID { onStatus?(uuid, status) } }
    }

    private func enqueueUplink(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            uplinkBuffer.append(data)
            while uplinkBuffer.count >= 320 {
                let frame = Data(uplinkBuffer.prefix(320))
                uplinkBuffer.removeFirst(320)
                if let localTransport { localTransport.send(frame) }
                else { webSocket?.send(.data(frame)) { _ in } }
            }
            if uplinkBuffer.count > 2_560 { uplinkBuffer = Data(uplinkBuffer.suffix(320)) }
        }
    }

    private func schedulePlayback(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        guard let player, engine?.isRunning == true else { initialPCM.append(pcm); return }
        let frames = pcm.count / 2
        guard frames > 0, scheduledFrames + frames <= 3_200,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
                channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
              ), let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0 ..< frames {
                let bits = UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8
                output[frame] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        scheduledFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduledFrames = max(0, (self?.scheduledFrames ?? 0) - frames) }
        }
        if !player.isPlaying { player.play() }
    }
}

private final class WatchVoicePCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var position = 0.0
    private var sampleRate = 0.0
    private var muted = false

    func setMuted(_ muted: Bool) { lock.lock(); self.muted = muted; lock.unlock() }

    func encode(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let input = buffer.floatChannelData?[0] else { return Data() }
        let frameCount = Int(buffer.frameLength)
        let copied = Array(UnsafeBufferPointer(start: input, count: frameCount))
        let rate = buffer.format.sampleRate
        lock.lock(); defer { lock.unlock() }
        if sampleRate != rate { sampleRate = rate; samples.removeAll(keepingCapacity: true); position = 0 }
        samples.append(contentsOf: copied)
        let step = rate / 8_000
        var pcm = Data()
        while position + 1 < Double(samples.count) {
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let value = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
            let scaled = muted ? Int16(0) : Int16(max(-1, min(1, value)) * 32_767)
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            position += step
        }
        let consumed = max(0, min(Int(position), samples.count - 1))
        if consumed > 0 { samples.removeFirst(consumed); position -= Double(consumed) }
        return pcm
    }
}

private enum WatchMediaError: LocalizedError {
    case invalidAudioFormat
    case microphoneUnavailable
	case microphonePermissionDenied
    case localRouteUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat: return "手表不支持 8 kHz 语音格式"
        case .microphoneUnavailable: return "手表麦克风当前不可用"
		case .microphonePermissionDenied: return "请先允许 AirSIM 使用手表麦克风"
        case .localRouteUnavailable: return "VoWLAN 本地语音路由不可用"
        }
    }
}

/// Watch directly authenticates to the paired VoWLAN PCM gateway. WCSession is never used for
/// audio frames; it is only the control channel to the iPhone.
private final class WatchLocalPCMTransport: @unchecked Sendable {
    private let endpoint: WatchLocalPCMEndpoint
    private let onPCM: (Data) -> Void
    private let onReady: () -> Void
    private let onFailure: (String) -> Void
    private let queue = DispatchQueue(label: "com.example.airsim.watch-local-pcm")
    private var connection: NWConnection?
    private var generation = 0
    private var stopped = false
    private var ready = false
    private var consecutiveFailures = 0
    private var deadline = DispatchTime.now()
    private var pending = Data()

    init(
        endpoint: WatchLocalPCMEndpoint,
        onPCM: @escaping (Data) -> Void,
        onReady: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.endpoint = endpoint
        self.onPCM = onPCM
        self.onReady = onReady
        self.onFailure = onFailure
    }

    func start() {
        queue.async { [self] in
            stopped = false
            deadline = .now() + 45
            attempt()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            generation += 1
            ready = false
            connection?.cancel()
            connection = nil
            pending.removeAll(keepingCapacity: false)
        }
    }

    func send(_ frame: Data) {
        queue.async { [self] in
            guard ready, let connection else { return }
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func attempt() {
        guard !stopped else { return }
        generation += 1
        let attemptID = generation
        ready = false
        pending.removeAll(keepingCapacity: true)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!,
            using: NWParameters(tls: endpoint.usesTLS ? NWProtocolTLS.Options() : nil, tcp: tcp)
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.queue.async {
                guard !self.stopped, self.generation == attemptID else { return }
                switch state {
                case .ready: self.handshake(connection, attemptID: attemptID)
                case let .failed(error): self.retry(error.localizedDescription, attemptID: attemptID)
                default: break
                }
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == attemptID, !self.ready else { return }
            self.retry("VoWLAN PCM 握手超时", attemptID: attemptID)
        }
    }

    private func handshake(_ connection: NWConnection, attemptID: Int) {
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.lowercased()
        let digest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let canonical = "PCM\n/v1/pcm\n\(digest)\n\(timestamp)\n\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8), using: SymmetricKey(data: endpoint.secret)
        )
        let signature = Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let preface = Data("AIRSIMVWL1 \(timestamp) \(nonce) \(signature)\n".utf8)
        connection.send(content: preface, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == attemptID, !self.stopped else { return }
                if let error { self.retry(error.localizedDescription, attemptID: attemptID) }
                else { self.receiveAcknowledgement(connection, attemptID: attemptID) }
            }
        })
    }

    private func receiveAcknowledgement(_ connection: NWConnection, attemptID: Int) {
        let acknowledgement = Data("AIRSIMREADY".utf8)
        connection.receive(minimumIncompleteLength: acknowledgement.count, maximumLength: 4_096) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == attemptID, !self.stopped else { return }
                guard error == nil, !complete, let data,
                      data.count >= acknowledgement.count,
                      data.prefix(acknowledgement.count) == acknowledgement else {
                    self.retry("VoWLAN PCM 鉴权或音频主机未就绪", attemptID: attemptID)
                    return
                }
                self.ready = true
                self.consecutiveFailures = 0
                self.deadline = .now() + 45
                self.onReady()
                self.consume(Data(data.dropFirst(acknowledgement.count)))
                self.receiveLoop(connection, attemptID: attemptID)
            }
        }
    }

    private func receiveLoop(_ connection: NWConnection, attemptID: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == attemptID, !self.stopped else { return }
                if let data { self.consume(data) }
                if let error { self.retry(error.localizedDescription, attemptID: attemptID) }
                else if complete { self.retry("VoWLAN PCM 已断开", attemptID: attemptID) }
                else { self.receiveLoop(connection, attemptID: attemptID) }
            }
        }
    }

    private func consume(_ data: Data) {
        pending.append(data)
        let complete = pending.count / 320 * 320
        if complete > 0 {
            onPCM(Data(pending.prefix(complete)))
            pending.removeFirst(complete)
        }
    }

    private func retry(_ reason: String, attemptID: Int) {
        guard !stopped, generation == attemptID else { return }
        // Retire this attempt immediately: an ACK already queued from the old
        // socket must not make the next attempt look authenticated.
        generation += 1
        let retryGeneration = generation
        connection?.cancel()
        connection = nil
        ready = false
        if DispatchTime.now() >= deadline {
            stopped = true
            generation += 1
            onFailure(reason)
            return
        }
        let delays: [Double] = [0.15, 0.35, 0.7, 1.0]
        let delay = delays[min(consecutiveFailures, delays.count - 1)]
        consecutiveFailures += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.generation == retryGeneration else { return }
            self.attempt()
        }
    }
}

private struct WatchDirectCallRoute {
    let pcm: WatchLocalPCMEndpoint
    let controlPort: UInt16
    let clockOffset: Double

    private static let service = "AirSIM.watch.direct-call.v1"
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private init?(_ value: [String: Any]) {
        guard let pcm = WatchLocalPCMEndpoint(dictionary: value), !pcm.usesTLS,
              let port = value["control_port"] as? Int, (1024...65535).contains(port) else { return nil }
        self.pcm = pcm
        controlPort = UInt16(port)
        let offset = value["clock_offset"] as? Double ?? 0
        clockOffset = offset.isFinite && abs(offset) < 86_400 ? offset : 0
    }

    static func save(_ routes: [[String: Any]]) {
        let valid = routes.prefix(8).filter { WatchDirectCallRoute($0) != nil }
        guard !valid.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: Array(valid)) else { return }
        let values: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(keychainQuery as CFDictionary, values as CFDictionary) == errSecItemNotFound {
            var item = keychainQuery
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func load(agentID: String) -> WatchDirectCallRoute? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var raw: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess,
              let data = raw as? Data,
              let routes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let value = routes.first(where: { $0["agent_id"] as? String == agentID }) else { return nil }
        return WatchDirectCallRoute(value)
    }

    func status(callID: String) async throws -> String {
        try await request(method: "GET", path: "/api/calls/status", callID: callID)
    }

    func command(_ command: String, callID: String) async throws {
        _ = try await request(method: "POST", path: "/api/calls/\(command)", callID: callID)
    }

    private func request(method: String, path: String, callID: String) async throws -> String {
        var url = URLComponents()
        url.scheme = "http"
        url.host = pcm.host
        url.port = Int(controlPort)
        url.path = path
        if method == "GET" { url.queryItems = [.init(name: "call_id", value: callID)] }
        guard let endpoint = url.url else { throw WatchCompanionError.unreachable }
        let target = url.percentEncodedPath + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        let body = method == "GET" ? Data() : try JSONEncoder().encode(["call_id": callID])
        let timestamp = Int64(Date().timeIntervalSince1970 + clockOffset)
        let nonce = UUID().uuidString.lowercased()
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method)\n\(target)\n\(digest)\n\(timestamp)\n\(nonce)"
        var request = URLRequest(url: endpoint, timeoutInterval: method == "GET" ? 1.8 : 3.5)
        request.httpMethod = method
        if method != "GET" {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("1", forHTTPHeaderField: "X-AirSIM-VoWLAN-Version")
        request.setValue("1", forHTTPHeaderField: "X-AirSIM-Watch-Control")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-AirSIM-VoWLAN-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-AirSIM-VoWLAN-Nonce")
        request.setValue(signature(canonical), forHTTPHeaderField: "X-AirSIM-VoWLAN-Signature")
        let (data, raw) = try await Self.session.data(for: request)
        guard let response = raw as? HTTPURLResponse, response.url == endpoint,
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let state = reply["state"], let proof = reply["proof"],
              proof == signature("watch-response\n\(nonce)\n\(callID)\n\(response.statusCode)\n\(state)"),
              (200...299).contains(response.statusCode) else {
            throw WatchCompanionError.remote("安卓未确认这次通话操作")
        }
        return state
    }

    private func signature(_ value: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: pcm.secret)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: WatchDirectNoRedirect(), delegateQueue: nil)
}

private final class WatchDirectNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: Watch-only reliability policies
// Watch runtime policies; the SMS wire models live in the shared payload file.
enum WatchReliabilityPolicy {
    static func acceptsMediaCallback(currentUUID: UUID?, callbackUUID: UUID) -> Bool {
        currentUUID == callbackUUID
    }
    static func permitsCloud(vowlanOnly: Bool, cachedPermission: Bool) -> Bool {
        !vowlanOnly && cachedPermission
    }
    static func phaseAfterMediaReady(_ phase: WatchCallPhase) -> WatchCallPhase { phase }
}

struct WatchEndDelivery: Equatable {
    let callID: String
    let uuid: UUID
    private(set) var acknowledgedAt: Date?
    private(set) var confirmedAt: Date?
    private(set) var verifying = false
    private(set) var checks = 0
    private(set) var checkReachable = false
    private(set) var verificationIssue: String?
    private(set) var failed = false
    var text: String {
        if confirmedAt != nil { return "安卓已确认通话结束" }
        if verifying {
            if let verificationIssue { return verificationIssue }
            if checks < 10 { return "正在自动确认安卓挂断结果" }
            return checkReachable ? "安卓尚未返回结束记录，继续检查中" : "连接异常，恢复后自动检查挂断"
        }
        if acknowledgedAt != nil { return "iPhone 已接收挂断请求" }
        return failed ? "挂断请求未获 iPhone 确认，请检查连接" : "正在向 iPhone 发送挂断请求"
    }
    mutating func record(callID: String, uuid: UUID, accepted: Bool, now: Date) {
        guard self.callID == callID, self.uuid == uuid, acknowledgedAt == nil else { return }
        if accepted { acknowledgedAt = now; failed = false }
        else { failed = true }
    }
    mutating func beginVerification() { verifying = true }
    mutating func useLegacyAcknowledgement() { verifying = false }
    mutating func verify(callID: String, uuid: UUID, confirmed: Bool, reachable: Bool, now: Date, issue: String? = nil) {
        guard self.callID == callID, self.uuid == uuid, verifying, confirmedAt == nil else { return }
        checks += 1; checkReachable = reachable; verificationIssue = issue
        if confirmed { confirmedAt = now; failed = false; verificationIssue = nil }
    }
    func shouldDismiss(at now: Date) -> Bool {
        if verifying { return confirmedAt.map { now.timeIntervalSince($0) >= 5 } ?? false }
        return acknowledgedAt.map { now.timeIntervalSince($0) >= 5 } ?? false
    }
}

struct WatchAnswerReadiness {
    private(set) var uuid: UUID?
    private var androidActive = false
    private var mediaReady = false
    mutating func begin(uuid: UUID?) { self.uuid = uuid; androidActive = false; mediaReady = false }
    mutating func noteAndroidActive(uuid: UUID) {
        guard self.uuid == uuid else { return }; androidActive = true
    }
    mutating func noteMediaReady(uuid: UUID) {
        guard self.uuid == uuid else { return }; mediaReady = true
    }
    func isActive(uuid: UUID) -> Bool { self.uuid == uuid && androidActive && mediaReady }
}

private enum WatchCompanionError: LocalizedError {
    case unreachable, timeout, remote(String)
    var errorDescription: String? {
        switch self {
        case .unreachable: return "iPhone 当前不可通信，请靠近 iPhone 并打开 AirSIM 后重试"
        case .timeout: return "iPhone 回应超时，请重试"
        case let .remote(message):
            if ["unsupported_action", "missing_action", "stale_call"].contains(message) {
                return "此 iPhone 版本不支持当前手表请求，请使用配套版本"
            }
            return message
        }
    }
}
final class WatchReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Result<[String: Any], Error>) -> Void)?
    init(_ callback: @escaping (Result<[String: Any], Error>) -> Void) { self.callback = callback }
    func finish(_ result: Result<[String: Any], Error>) {
        lock.lock(); let action = callback; callback = nil; lock.unlock()
        action?(result)
    }
}

struct WatchPendingDialMirrors {
    private var values: [UUID: WatchCallPayload] = [:]
    var count: Int { values.count }
    mutating func reset() { values.removeAll() }
    mutating func store(_ payload: WatchCallPayload) {
        guard payload.phase == .active, let uuid = payload.callUUID else { return }
        if let previous = values[uuid], previous.updatedAt.timeIntervalSince1970 >= payload.updatedAt.timeIntervalSince1970 { return }
        values[uuid] = payload
        if values.count > 8, let oldest = values.min(by: { $0.value.updatedAt.timeIntervalSince1970 < $1.value.updatedAt.timeIntervalSince1970 })?.key {
            values.removeValue(forKey: oldest)
        }
    }
    mutating func consume(uuid: UUID) -> WatchCallPayload? {
        let payload = values[uuid]
        reset()
        return payload
    }
}

/// Retain at most 160 ms that arrives before CallKit starts the playback engine.
/// No steady-state delay or uplink buffering is introduced.
struct WatchInitialPCMBuffer {
    private var bytes = Data()
    private var accepting = false
    static let capacity = 2_560 // 8 kHz × Int16 × 160 ms
    var count: Int { bytes.count }
    mutating func begin() { bytes.removeAll(keepingCapacity: true); accepting = true }
    mutating func append(_ pcm: Data) {
        guard accepting, pcm.count.isMultiple(of: 2) else { return }
        bytes.append(pcm)
        if bytes.count > Self.capacity { bytes.removeFirst(bytes.count - Self.capacity) }
    }
    mutating func drain() -> Data { let result = bytes; discard(); return result }
    mutating func discard() { bytes.removeAll(keepingCapacity: false); accepting = false }
}
