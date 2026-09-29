import Foundation
import WatchConnectivity

/// 镜像 iPhone 通话状态，并为 Watch 发起的公网呼叫代理设备认证与拨号命令。
/// Watch 的 CallKit 和 PCM 仍在手表执行；媒体密钥仅经实时 WC 回复交接，不持久化。
final class WatchCallCoordinator: NSObject, WCSessionDelegate {
    static let shared = WatchCallCoordinator()

    private var session: WCSession?
    private var lastPayload: WatchCallPayload?
    private var lastCloudMediaAllowed: Bool?
    private var pendingWatchDialID: UUID?
    private var cancelledWatchDialIDs = Set<UUID>()
    private var watchOutgoingCall: (requestID: UUID, call: IncomingVoIPCall)?
    private weak var model: AppModel?
    private struct LocalWatchCall {
        let requestID: UUID?
        let callID: String
        let uuid: UUID
        let api: DJOneHubAPI
    }
    private var localWatchCall: LocalWatchCall?
    private var localEndInFlight: String?

    @MainActor
    func configure(model: AppModel) { self.model = model }

    @MainActor
    func refreshMediaPolicy() {
        lastCloudMediaAllowed = nil
        if let lastPayload { publish(lastPayload) }
    }

    @MainActor
    func ownsMedia(callID: String?) -> Bool {
        pendingWatchDialID != nil || (callID != nil && localWatchCall?.callID == callID)
    }

    func start() {
        guard WCSession.isSupported() else { return }
        if session == nil {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
#if DEBUG
			print("[DJOneHub iPhone WC] 已请求激活；paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled)")
#endif
        }
    }

    @MainActor
    func publish(call: CallRecord?, previous: CallRecord?, callerName: String?) {
        start()
        let phase: WatchCallPhase
        if let call {
            switch call.state {
            case "incoming", "waiting": phase = .incoming
            case "active", "held": phase = .active
            default: phase = .connecting
            }
        } else {
            phase = previous == nil ? .idle : .ended
        }
        let identityCall = call ?? previous
        let payload = WatchCallPayload(
            callID: identityCall?.id ?? "",
            callUUID: CallKitController.shared.watchCallUUID(for: identityCall?.id),
            phase: phase,
            number: identityCall?.number,
            callerName: callerName,
            updatedAt: identityCall?.updatedAt ?? Date()
        )
        publish(payload)
    }

    @MainActor
    func publishIncoming(_ call: IncomingVoIPCall, callerName: String? = nil) {
        start()
        publish(WatchCallPayload(
            callID: call.callID,
            callUUID: call.uuid,
            phase: .incoming,
            number: call.number,
            callerName: callerName ?? call.callerName,
            updatedAt: Date()
        ))
    }

    @MainActor
    private func publish(_ payload: WatchCallPayload) {
        if payload.phase == .ended, localWatchCall?.callID == payload.callID {
            localWatchCall = nil
        }
        if let lastPayload,
           lastCloudMediaAllowed == CloudModePreference.isEnabled(),
           lastPayload.callID == payload.callID,
           lastPayload.callUUID == payload.callUUID,
           lastPayload.phase == payload.phase,
           lastPayload.number == payload.number,
           lastPayload.callerName == payload.callerName {
            return
        }
        lastPayload = payload
        lastCloudMediaAllowed = CloudModePreference.isEnabled()
        guard let session, session.activationState == .activated else { return }
        var dictionary = payload.dictionary
        dictionary["cloud_media_allowed"] = CloudModePreference.isEnabled()
        try? session.updateApplicationContext(dictionary)
        if session.isReachable {
            session.sendMessage(dictionary, replyHandler: nil, errorHandler: nil)
        }
        // 状态转移用后台队列保证手表 App 暂未运行时仍能在下次唤醒后收敛；
        // 实时接听/拒接不使用队列，避免延迟动作误操作下一通电话。
        session.transferUserInfo(dictionary)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
#if DEBUG
		print("[DJOneHub iPhone WC] 激活完成；state=\(activationState.rawValue) context=\(session.receivedApplicationContext["event"] as? String ?? "无") error=\(error?.localizedDescription ?? "无")")
#endif
		guard activationState == .activated,
			  !session.receivedApplicationContext.isEmpty else { return }
		let context = session.receivedApplicationContext
		Task { @MainActor in
			_ = self.consumeWatchRegistration(context) || self.consumeWatchOwnership(context)
		}
	}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            if self.consumeWatchRegistration(message) {
                replyHandler(["ok": true])
                return
            }
            if self.consumeWatchOwnership(message) {
                replyHandler(["ok": true])
                return
            }
            guard let action = message["action"] as? String else {
                replyHandler(["ok": false, "error": "missing_action"])
                return
            }
            if action == "status" {
                if let payload = self.lastPayload {
                    replyHandler(payload.dictionary.merging([
                        "ok": true, "cloud_media_allowed": CloudModePreference.isEnabled(),
                    ]) { _, new in new })
                } else {
                    replyHandler(["ok": true, "event": "watch_call_state", "call_id": "", "call_uuid": "", "phase": "idle", "updated_at": Date().timeIntervalSince1970,
                                  "cloud_media_allowed": CloudModePreference.isEnabled()])
                }
                return
            }
            if action == "dial" {
                await self.dialFromWatch(message, replyHandler: replyHandler)
                return
            }
            if action == "cancel_dial" {
                self.cancelWatchDial(message)
                replyHandler(["ok": true])
                return
            }
            if action == "watch_local_answer" {
                await self.answerLocallyFromWatch(message, replyHandler: replyHandler)
                return
            }
            if action == "watch_local_end" {
                await self.endLocalWatchCall(message, replyHandler: replyHandler)
                return
            }
            if action == "watch_local_reject" {
                await self.rejectLocalWatchCall(message, replyHandler: replyHandler)
                return
            }
            let callID = message["call_id"] as? String
            let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
            guard CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) else {
                replyHandler(["ok": false, "error": "stale_call"])
                return
            }
            do {
                switch action {
                case "answer": try await CallKitController.shared.answerCurrentCall()
                case "reject", "end": try await CallKitController.shared.endCurrentCall()
                default:
                    replyHandler(["ok": false, "error": "unsupported_action"])
                    return
                }
                replyHandler(["ok": true])
            } catch {
                replyHandler(["ok": false, "error": error.localizedDescription])
            }
        }
    }

    @MainActor
    private func dialFromWatch(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let requestID = (message["request_id"] as? String).flatMap(UUID.init(uuidString:)),
              let number = (message["number"] as? String).flatMap(WatchDialNumber.validated) else {
            replyHandler(["ok": false, "error": "请输入有效的电话号码"])
            return
        }
        guard pendingWatchDialID == nil, watchOutgoingCall == nil, localWatchCall == nil,
              CallKitController.shared.currentSystemCallUUID == nil else {
            replyHandler(["ok": false, "error": "已有通话或拨号任务正在进行"])
            return
        }
        if cancelledWatchDialIDs.remove(requestID) != nil {
            replyHandler(["ok": false, "error": "已取消拨号"])
            return
        }
        pendingWatchDialID = requestID
        defer { pendingWatchDialID = nil; cancelledWatchDialIDs.remove(requestID) }
        do {
            if let model, let (api, pcmRoute) = await model.readyVoWLANRoute(),
               case let .vowlan(endpoint, credential) = pcmRoute {
                guard !cancelledWatchDialIDs.contains(requestID) else {
                    replyHandler(["ok": false, "error": "已取消拨号"])
                    return
                }
                try await api.dial(number: number)
                guard let record = await waitForOutgoingCall(api: api, number: number) else {
                    try? await api.hangupCall()
                    replyHandler(["ok": false, "error": "VoWLAN 未确认拨号状态"])
                    return
                }
                if cancelledWatchDialIDs.contains(requestID) {
                    try? await api.hangupCall()
                    replyHandler(["ok": false, "error": "已取消拨号"])
                    return
                }
                let uuid = UUID()
                localWatchCall = LocalWatchCall(
                    requestID: requestID, callID: record.id, uuid: uuid, api: api
                )
                monitorLocalAudio(callID: record.id, api: api)
                replyHandler([
                    "ok": true, "request_id": requestID.uuidString,
                    "call_id": record.id, "call_uuid": uuid.uuidString,
                    "number": number, "media_route": "vowlan",
                    "pcm_host": endpoint.host, "pcm_port": Int(endpoint.pcmPort),
                    "pcm_secret": credential.encodedSecret,
                    "expires_at": Date().addingTimeInterval(300).timeIntervalSince1970,
                ])
                return
            }
            guard CloudModePreference.isEnabled() else {
                replyHandler(["ok": false, "error": "VoWLAN 不可达，且云端模式未开启"])
                return
            }
            let status = try await VoIPPushController.shared.fetchCloudAgentStatus()
            guard status.cloudOnline else { throw CloudCommandError.unavailable }
            guard !cancelledWatchDialIDs.contains(requestID) else {
                replyHandler(["ok": false, "error": "已取消拨号"])
                return
            }
            // 没有可验证的本地 VoWLAN 时才回退公网 PCM。
            let outgoing = try await VoIPPushController.shared.startCloudOutgoingCall(
                number: number, mediaTransport: .legacyPCM, timeout: 15
            )
            guard !cancelledWatchDialIDs.contains(requestID) else {
                await endAbandonedWatchCall(outgoing)
                replyHandler(["ok": false, "error": "已取消拨号"])
                return
            }
            guard outgoing.requestedMediaTransport == .legacyPCM,
                  let authenticatedURL = outgoing.authenticatedMediaURL,
                  var components = URLComponents(url: authenticatedURL, resolvingAgainstBaseURL: false),
                  let secret = components.queryItems?.first(where: { $0.name == "token" })?.value else {
                await endAbandonedWatchCall(outgoing)
                replyHandler(["ok": false, "error": "云端未提供 Watch 可用的 PCM 音频"])
                return
            }
            components.queryItems = nil
            guard let mediaURL = components.url else {
                await endAbandonedWatchCall(outgoing)
                replyHandler(["ok": false, "error": "云端音频地址无效"])
                return
            }
            watchOutgoingCall = (requestID, outgoing)
            replyHandler([
                "ok": true,
                "request_id": requestID.uuidString,
                "call_id": outgoing.callID,
                "call_uuid": outgoing.uuid.uuidString,
                "number": number,
                "call_secret": secret,
                "media_url": mediaURL.absoluteString,
                "expires_at": outgoing.expiresAt?.timeIntervalSince1970 ?? Date().addingTimeInterval(300).timeIntervalSince1970,
            ])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription])
        }
    }

    @MainActor
    private func cancelWatchDial(_ message: [String: Any]) {
        guard let requestID = (message["request_id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        if cancelledWatchDialIDs.count >= 20 { cancelledWatchDialIDs.removeAll() }
        cancelledWatchDialIDs.insert(requestID)
        if let active = localWatchCall, active.requestID == requestID {
            Task { @MainActor in
                do {
                    try await active.api.hangupCall()
                    if localWatchCall?.callID == active.callID { localWatchCall = nil }
                } catch {
                    NSLog("[DJOneHub Watch Dial] VoWLAN 取消失败：%@", error.localizedDescription)
                }
            }
        }
        if let active = watchOutgoingCall, active.requestID == requestID {
            watchOutgoingCall = nil
            cancelledWatchDialIDs.remove(requestID)
            Task { await endAbandonedWatchCall(active.call) }
        }
    }

    @MainActor
    private func waitForOutgoingCall(api: DJOneHubAPI, number: String) async -> CallRecord? {
        for _ in 0..<12 {
            if let call = try? await api.callStatus().active,
               call.direction == "outgoing", call.number == nil || call.number == number {
                return call
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    @MainActor
    private func answerLocallyFromWatch(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let callID = message["call_id"] as? String, !callID.isEmpty,
              let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)),
              localWatchCall == nil, let model,
              let (api, pcmRoute) = await model.readyVoWLANRoute(),
              case let .vowlan(endpoint, credential) = pcmRoute else {
            replyHandler(["ok": false, "error": "VoWLAN 未就绪",
                          "cloud_media_allowed": CloudModePreference.isEnabled()])
            return
        }
        do {
            guard let current = try await api.callStatus().active,
                  current.id == callID,
                  ["incoming", "waiting"].contains(current.state) else {
                replyHandler(["ok": false, "error": "来电已失效",
                              "cloud_media_allowed": CloudModePreference.isEnabled()])
                return
            }
            localWatchCall = LocalWatchCall(requestID: nil, callID: callID, uuid: uuid, api: api)
            do {
                try await api.answerCall()
            } catch {
                localWatchCall = nil
                throw error
            }
            if CallKitController.shared.matchesCurrentCall(callID: callID, uuid: nil) {
                CallKitController.shared.reportCurrentCallEnded(reason: .answeredElsewhere)
            }
            monitorLocalAudio(callID: callID, api: api)
            replyHandler([
                "ok": true, "call_id": callID, "call_uuid": uuid.uuidString,
                "media_route": "vowlan", "pcm_host": endpoint.host,
                "pcm_port": Int(endpoint.pcmPort), "pcm_secret": credential.encodedSecret,
                "cloud_media_allowed": CloudModePreference.isEnabled(),
            ])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription,
                          "cloud_media_allowed": CloudModePreference.isEnabled()])
        }
    }

    @MainActor
    private func endLocalWatchCall(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let call = localWatchCall,
              message["call_id"] as? String == call.callID,
              message["call_uuid"] as? String == call.uuid.uuidString else {
            replyHandler(["ok": false, "error": "stale_call"])
            return
        }
        guard localEndInFlight != call.callID else {
            replyHandler(["ok": true])
            return
        }
        localEndInFlight = call.callID
        defer { localEndInFlight = nil }
        do {
            try await call.api.hangupCall()
            if localWatchCall?.callID == call.callID { localWatchCall = nil }
            replyHandler(["ok": true])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription])
        }
    }

    @MainActor
    private func rejectLocalWatchCall(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let callID = message["call_id"] as? String, !callID.isEmpty,
              let model, let (api, _) = await model.readyVoWLANRoute() else {
            replyHandler(["ok": false, "error": "VoWLAN 未就绪"])
            return
        }
        do {
            guard let current = try await api.callStatus().active,
                  current.id == callID,
                  ["incoming", "waiting"].contains(current.state) else {
                replyHandler(["ok": false, "error": "来电已失效"])
                return
            }
            _ = try await api.rejectCall()
            replyHandler(["ok": true])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription])
        }
    }

    @MainActor
    private func monitorLocalAudio(callID: String, api: DJOneHubAPI) {
        Task { @MainActor in
            for _ in 0..<120 {
                guard localWatchCall?.callID == callID else { return }
                if let current = try? await api.callStatus().active {
                    guard current.id == callID else { return }
                    if current.state == "active" {
                        let outcome = try? await CallAudioRegistrationCoordinator.register(service: api)
                        if outcome == .registered { return }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            NSLog("[DJOneHub Watch] VoWLAN 音频主机注册超时；call=%@", callID)
        }
    }

    @MainActor
    private func endAbandonedWatchCall(_ call: IncomingVoIPCall) async {
        guard let credentials = VoIPPushController.shared.cloudCallControlCredentials() else { return }
        let envelope = CloudCallControlEnvelope(
            action: "end", callID: call.callID, callUUID: call.uuid.uuidString.lowercased(),
            generation: call.generation, commandID: UUID().uuidString.lowercased(),
            traceID: "watch-dial-abort-\(UUID().uuidString.lowercased())"
        )
        do {
            let receipt = try await CloudCallControlClient.submit(envelope: envelope, credentials: credentials)
            Task {
                do {
                    let final = receipt.isFinal ? receipt : try await CloudCallControlClient.awaitFinalReceipt(
                        envelope: envelope, credentials: credentials
                    )
                    if final.status != "completed" || final.result?.ended != true {
                        NSLog("[DJOneHub Watch Dial] 模块未确认挂断：%@", final.error ?? final.status)
                    }
                } catch {
                    NSLog("[DJOneHub Watch Dial] 等待模块挂断确认失败：%@", error.localizedDescription)
                }
            }
        } catch {
            // 已拨号但交接失败必须可诊断，不能悄悄遗留蜂窝通话。
            NSLog("[DJOneHub Watch Dial] 取消呼出失败：%@", error.localizedDescription)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if message["action"] as? String == "cancel_dial" {
                self.cancelWatchDial(message)
                return
            }
            if message["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(message, replyHandler: { _ in })
                return
            }
            if message["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(message, replyHandler: { _ in })
                return
            }
            _ = self.consumeWatchRegistration(message) || self.consumeWatchOwnership(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            if userInfo["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(userInfo, replyHandler: { _ in })
                return
            }
            if userInfo["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(userInfo, replyHandler: { _ in })
                return
            }
            _ = self.consumeWatchRegistration(userInfo) || self.consumeWatchOwnership(userInfo)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            if applicationContext["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(applicationContext, replyHandler: { _ in })
                return
            }
            if applicationContext["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(applicationContext, replyHandler: { _ in })
                return
            }
            _ = self.consumeWatchRegistration(applicationContext) || self.consumeWatchOwnership(applicationContext)
        }
    }

    @MainActor
    private func consumeWatchRegistration(_ message: [String: Any]) -> Bool {
        guard message["event"] as? String == "watch_voip_registration",
              let token = message["watch_voip_token"] as? String,
              let bundleID = message["watch_bundle_id"] as? String,
              !token.isEmpty, !bundleID.isEmpty else { return false }
        VoIPPushController.shared.storeWatchVoIPRegistration(token: token, bundleID: bundleID)
#if DEBUG
		print("[DJOneHub iPhone WC] 已接收 Watch VoIP token；字符数=\(token.count)")
#endif
        return true
    }

    @MainActor
    private func consumeWatchOwnership(_ message: [String: Any]) -> Bool {
        guard message["event"] as? String == "watch_call_owner",
              let phase = message["phase"] as? String else { return false }
        let callID = message["call_id"] as? String
        let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
        if let active = watchOutgoingCall, active.call.callID == callID,
           phase == WatchCallPhase.ended.rawValue {
            watchOutgoingCall = nil
        }
        guard CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) else { return true }
        if phase == WatchCallPhase.active.rawValue {
            CallKitController.shared.reportCurrentCallEnded(reason: .answeredElsewhere)
        } else if phase == WatchCallPhase.ended.rawValue {
            CallKitController.shared.reportCurrentCallEnded(reason: .declinedElsewhere)
        }
        return true
    }
}
