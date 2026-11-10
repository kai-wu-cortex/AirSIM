import UIKit
import Foundation
import CryptoKit
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
        let api: AirSIMAPI
        let backendID: String
        let agentID: String?
        init(requestID: UUID?, callID: String, uuid: UUID, api: AirSIMAPI, backendID: String? = nil, agentID: String? = nil) {
            self.requestID = requestID; self.callID = callID; self.uuid = uuid; self.api = api
            self.backendID = backendID ?? callID
            self.agentID = agentID
        }
    }
    private struct EndReference: Codable {
        let uuid: UUID
        let callID: String
        let agentID: String
        let backendID: String
        let canonicalID: String?
        var confirmed = false
    }
    private let endReferenceKey = "airsim.watch.end-references.v1"
    private lazy var endReferences: [EndReference] = {
        guard let data = UserDefaults.standard.data(forKey: endReferenceKey) else { return [] }
        return (try? JSONDecoder().decode([EndReference].self, from: data)) ?? []
    }()
    private func saveEndReferences() {
        UserDefaults.standard.set(try? JSONEncoder().encode(endReferences), forKey: endReferenceKey)
    }

    @MainActor
    func recordAndroidEnd(uuid: UUID, agentID: String, callIDs: [String]) {
        guard let index = endReferences.firstIndex(where: {
            $0.uuid == uuid && $0.agentID == agentID
                && (callIDs.contains($0.backendID) || $0.canonicalID.map(callIDs.contains) == true)
        }), !endReferences[index].confirmed else { return }
        endReferences[index].confirmed = true
        saveEndReferences()
    }

    private var endCheckTargets: [UUID: LocalWatchCall] = [:]
    private var endCheckOrder: [UUID] = []
    @MainActor private var localWatchCall: LocalWatchCall? {
        didSet { if let call = localWatchCall { rememberEndCheck(call) } }
    }
    @MainActor private func rememberEndCheck(_ call: LocalWatchCall) {
        endCheckTargets[call.uuid] = call
        if let agentID = call.agentID, !endReferences.contains(where: { $0.uuid == call.uuid }) {
            endReferences.append(.init(uuid: call.uuid, callID: call.callID, agentID: agentID, backendID: call.backendID,
                canonicalID: model?.watchCanonicalCallID(uuid: call.uuid, agentID: agentID)))
            if endReferences.count > 32 { endReferences.removeFirst(endReferences.count - 32) }
            saveEndReferences()
        }
        endCheckOrder.removeAll { $0 == call.uuid }
        endCheckOrder.append(call.uuid)
        while endCheckOrder.count > 32 { endCheckTargets.removeValue(forKey: endCheckOrder.removeFirst()) }
    }
    private var localEndInFlight: String?
    private var abandonedAnswers: [UUID] = []
    private var watchReplyInFlight = false

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
			print("[AirSIM iPhone WC] 已请求激活；paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled)")
#endif
        }
    }

    @MainActor
    func publish(
        call: CallRecord?, previous: CallRecord?, callerName: String?,
        transport: String? = nil
    ) {
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
        publish(WatchCallPayload(
            callID: identityCall?.id ?? "",
            callUUID: CallKitController.shared.watchCallUUID(for: identityCall?.id)
                ?? model?.ownedCallUUID(for: identityCall?.id),
            phase: phase,
            number: identityCall?.number,
            callerName: callerName,
            transport: transport,
            updatedAt: identityCall?.updatedAt ?? Date()
        ))
    }

    @MainActor
    func publish(
        callID: String, callUUID: UUID?, aliases: [String] = [], phase: WatchCallPhase,
        number: String?, callerName: String?, transport: String? = nil,
        updatedAt: Date = Date()
    ) {
        start()
        publish(WatchCallPayload(
            callID: callID, callUUID: callUUID, aliases: aliases, phase: phase,
            number: number, callerName: callerName, transport: transport, updatedAt: updatedAt
        ))
    }

    @MainActor
    func publishIncoming(
        _ call: IncomingVoIPCall, callerName: String? = nil,
        transport: String? = nil
    ) {
        publish(
            callID: call.callID, callUUID: call.uuid, phase: .incoming,
            number: call.number, callerName: callerName ?? call.callerName, transport: transport
        )
    }

    @MainActor
    private func publish(_ payload: WatchCallPayload) {
        if payload.phase == .ended,
           let localWatchCall,
           payload.matches(callID: localWatchCall.callID, callUUID: localWatchCall.uuid) {
            if let reservation = localWatchCall.requestID { model?.deviceCallContext.releaseAdmission(reservation) }
            self.localWatchCall = nil
        }
        if let lastPayload,
           lastCloudMediaAllowed == CloudModePreference.isEnabled(),
           lastPayload.isSamePresentation(as: payload) {
            return
        }
        lastPayload = payload
        lastCloudMediaAllowed = CloudModePreference.isEnabled()
        send(payload)
    }

    @MainActor
    private func send(_ payload: WatchCallPayload) {
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

    @MainActor
    private func resendLastPayload() {
        guard let lastPayload else { return }
        send(lastPayload)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
#if DEBUG
		print("[AirSIM iPhone WC] 激活完成；state=\(activationState.rawValue) context=\(session.receivedApplicationContext["event"] as? String ?? "无") error=\(error?.localizedDescription ?? "无")")
#endif
		guard activationState == .activated else { return }
		let context = session.receivedApplicationContext
		Task { @MainActor in
			self.resendLastPayload()
			guard !context.isEmpty else { return }
			if !self.consumeWatchRegistration(context) { _ = await self.consumeWatchOwnership(context) }
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
        NSLog("[AirSIM WatchRPC] received %@", message["action"] as? String ?? message["event"] as? String ?? "unknown")
        Task { @MainActor in
            let lease = WatchRequestExecutionLease()
            defer { lease.end() }
            let started = DispatchTime.now().uptimeNanoseconds
            let action = message["action"] as? String ?? message["event"] as? String ?? "unknown"
            PushDiagnostics.record("收到 Watch 请求", fields: ["action": action, "app_state": String(UIApplication.shared.applicationState.rawValue)])
            let upstreamReply = replyHandler
            let replyHandler: ([String: Any]) -> Void = { reply in
                let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                NSLog("[AirSIM WatchRPC] replied %@ in %llu ms", action, ms)
                PushDiagnostics.record("已回应 Watch 请求", fields: ["action": action, "duration_ms": String(ms), "ok": String(reply["ok"] as? Bool ?? false)])
                upstreamReply(reply)
            }
            if self.consumeWatchRegistration(message) {
                replyHandler(["ok": true])
                return
            }
            if await self.consumeWatchOwnership(message) {
                replyHandler(["ok": true])
                return
            }
            guard let action = message["action"] as? String else {
                replyHandler(["ok": false, "error": "missing_action"])
                return
            }
            if action == "watch_sms_reply_options" || action == "watch_sms_reply_send" {
                await self.handleWatchReply(message, replyHandler: replyHandler)
                return
            }
            if action.hasPrefix("watch_sms_") {
                self.handleWatchSMS(message, replyHandler: replyHandler)
                return
            }
            if action == "status" {
                if message["watch_direct_version"] as? Int == 1 {
                    var reply = self.lastPayload?.dictionary ?? [:]
                    reply["ok"] = true
                    reply["cloud_media_allowed"] = CloudModePreference.isEnabled()
                    if let model = self.model {
                        reply["watch_direct_routes"] = model.localDevices.agentIDs.prefix(8).compactMap { id -> [String: Any]? in
                            guard PairedAndroidDeviceStore.records().contains(where: { $0.id == id }),
                                  let api = model.localDevices.api(for: id),
                                  case let .vowlan(endpoint, credential) = api.route, !endpoint.usesTLS else { return nil }
                            let key = HMAC<SHA256>.authenticationCode(
                                for: Data("AirSIM/watch-call-only/v1".utf8), using: SymmetricKey(data: credential.secret))
                            return ["agent_id": id, "pcm_host": endpoint.host, "pcm_port": Int(endpoint.pcmPort),
                                    "control_port": Int(endpoint.controlPort), "pcm_secret": Data(key).base64EncodedString(),
                                    "clock_offset": credential.clockOffset]
                        }
                    }
                    replyHandler(reply)
                    return
                }
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
            if action == "watch_phone_end" {
                await self.endPhoneMirror(message, replyHandler: replyHandler); return
            }
            if action == "watch_local_answer" {
                await self.answerLocallyFromWatch(message, replyHandler: replyHandler)
                return
            }
            if action == "watch_local_dtmf" {
                await self.sendWatchDTMF(message, replyHandler: replyHandler); return
            }
            if action == "watch_local_end_status" {
                await self.checkWatchEnd(message, replyHandler: replyHandler); return
            }
            if action == "watch_local_end" {
                await self.endLocalWatchCall(message, acknowledgeEarly: true, replyHandler: replyHandler)
                return
            }
            if action == "watch_local_reject" {
                await self.rejectLocalWatchCall(message, replyHandler: replyHandler)
                return
            }
            let callID = message["call_id"] as? String
            let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
            guard CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid,
                agentID: message["agent_id"] as? String) else {
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
    func handleWatchReply(_ message: [String: Any], replyHandler: ([String: Any]) -> Void) async {
        func fail(_ error: String) { replyHandler(["ok": false, "error": error]) }
        guard let model, !model.callLifecycleSnapshot.state.representsCall,
              localWatchCall == nil, pendingWatchDialID == nil else {
            fail("请在通话结束后回复短信"); return
        }
        guard let agentID = message["agent_id"] as? String, let peer = message["peer"] as? String,
              !peer.isEmpty, PairedAndroidDeviceStore.records().contains(where: { $0.id == agentID }) else {
            fail("此短信设备未配对"); return
        }
        model.reloadMessagesFromLocalStore()
        guard let sender = model.messages.first(where: {
            $0.sourceAgentID == agentID && WatchSMSConversationPolicy.peer($0.sender) == peer
        })?.sender, let recipient = WatchSMSConversationPolicy.replyNumber(sender) else {
            fail("当前会话没有可回复的电话号码"); return
        }
        if message["action"] as? String == "watch_sms_reply_options" {
            let slots = model.localDevices.metadata(for: agentID)?.simSlots ?? []
            let options = WatchSMSReplyOptions(recipient: recipient, slots: slots.map {
                .init(id: $0.id, label: $0.slotIndex.map { "SIM \($0 + 1)" } ?? $0.label, carrier: $0.carrierName)
            }, selectedID: model.selectedSMSSlotID(for: agentID, recipient: recipient))
            guard let data = try? JSONEncoder().encode(options) else { fail("无法读取发送卡"); return }
            replyHandler(["ok": true, "options": data])
            return
        }
        guard message["action"] as? String == "watch_sms_reply_send",
              let deadline = message["expires_at"] as? TimeInterval,
              (0...30).contains(deadline - Date().timeIntervalSince1970),
              let body = (message["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty, body.count <= 2_000, body.utf8.count <= 8_000,
              let slotID = message["slot_id"] as? String, !slotID.isEmpty else {
            fail("发送请求已过期或内容无效"); return
        }
        guard !watchReplyInFlight else { fail("上一条短信仍在发送"); return }
        watchReplyInFlight = true
        defer { watchReplyInFlight = false }
        switch await model.sendWatchSMSReply(recipient: recipient, body: body, agentID: agentID, slotID: slotID) {
        case .sent: replyHandler(["ok": true])
        case let .failed(message): fail(message)
        case .uncertain: replyHandler(["ok": false, "uncertain": true])
        }
    }

    @MainActor
    func handleWatchSMS(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let model else { replyHandler(["ok": false, "error": "iPhone 尚未就绪"]); return }
        guard !model.callLifecycleSnapshot.state.representsCall,
              localWatchCall == nil, pendingWatchDialID == nil else {
            replyHandler(["ok": false, "error": "通话优先，请在通话结束后查看短信"]); return
        }
        model.reloadMessagesFromLocalStore()
        let pairedIDs = Set(PairedAndroidDeviceStore.records().map(\.id))
        let devices = model.pairedDeviceHistory.filter { pairedIDs.contains($0.id) }.map { WatchSMSDevice(id: $0.id, name: WatchSMSPolicy.prefix($0.deviceName, utf8Limit: 256)) }
        let requested = message["agent_id"] as? String
        let selected = WatchSMSPolicy.selected(requested: requested, current: AndroidAgentBindingPreference.selected(), paired: devices.map(\.id))
        guard requested == nil || selected != nil else {
            replyHandler(["ok": false, "error": "此设备未配对，请重新选择"]); return
        }
        let records = model.messages.filter { WatchSMSPolicy.permits(sourceAgentID: $0.sourceAgentID,
            selectedAgentID: selected, pairedIDs: devices.map(\.id)) }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
        func opaqueID(_ record: SMSMessage) -> String {
            SHA256.hash(data: Data(record.id.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func row(_ record: SMSMessage) -> WatchSMSRow {
            WatchSMSRow(id: opaqueID(record), agentID: record.sourceAgentID ?? "",
                sender: WatchSMSPolicy.prefix(record.sender, utf8Limit: 256),
                preview: WatchSMSPolicy.prefix(record.content, utf8Limit: 180), timestamp: record.timestamp,
                sim: record.simSlot.map { WatchSMSPolicy.prefix($0, utf8Limit: 64) },
                outgoing: record.isOutgoing, unread: model.unreadMessageIDs.contains(record.id))
        }
        do {
            let action = message["action"] as? String
            if action == "watch_sms_list" {
                var page = WatchSMSPage(devices: devices, selectedAgentID: selected,
                    rows: Array(records.prefix(30)).map(row), total: records.count, generatedAt: Date())
                var data = try JSONEncoder().encode(page)
                while data.count > WatchSMSPolicy.payloadBudget, !page.rows.isEmpty {
                    page.rows.removeLast(); data = try JSONEncoder().encode(page)
                }
                guard data.count <= WatchSMSPolicy.payloadBudget else { throw WatchCompanionPayloadError.tooLarge }
                replyHandler(["ok": true, "sms_data": data]); return
            }
            if action == "watch_sms_thread" {
                guard let selected, let peer = message["peer"] as? String, !peer.isEmpty else {
                    replyHandler(["ok": false, "error": "短信联系人信息缺失"]); return
                }
                let matching = records.filter { WatchSMSConversationPolicy.peer($0.sender) == peer }
                var page = WatchSMSPage(devices: devices, selectedAgentID: selected,
                    rows: Array(matching.prefix(60)).map(row), total: matching.count, generatedAt: Date())
                var data = try JSONEncoder().encode(page)
                while data.count > WatchSMSPolicy.payloadBudget, !page.rows.isEmpty {
                    page.rows.removeLast(); data = try JSONEncoder().encode(page)
                }
                guard data.count <= WatchSMSPolicy.payloadBudget else { throw WatchCompanionPayloadError.tooLarge }
                replyHandler(["ok": true, "sms_data": data]); return
            }
            guard let selected, let id = message["message_id"] as? String,
                  let record = records.first(where: { opaqueID($0) == id }) else {
                replyHandler(["ok": false, "error": "短信已不存在或设备不匹配，请刷新"]); return
            }
            if action == "watch_sms_read" {
                model.markMessagesRead([record])
                replyHandler(["ok": !model.unreadMessageIDs.contains(record.id)]); return
            }
            guard action == "watch_sms_detail" else {
                replyHandler(["ok": false, "error": "不支持的短信操作"]); return
            }
            let detail = try WatchSMSPolicy.boundedDetail(row: row(record), body: record.content)
            let data = try JSONEncoder().encode(detail)
            guard detail.row.agentID == selected, data.count <= WatchSMSPolicy.payloadBudget else {
                throw WatchCompanionPayloadError.tooLarge
            }
            replyHandler(["ok": true, "sms_data": data])
        } catch { replyHandler(["ok": false, "error": "短信内容过大，暂无法传到手表"] ) }
    }

    @MainActor
    private func dialFromWatch(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        let boundAtStart = AndroidAgentBindingPreference.selected()
        guard let requestID = (message["request_id"] as? String).flatMap(UUID.init(uuidString:)),
              let number = (message["number"] as? String).flatMap(WatchDialNumber.validated) else {
            replyHandler(["ok": false, "error": "请输入有效的电话号码"])
            return
        }
        guard pendingWatchDialID == nil, watchOutgoingCall == nil, localWatchCall == nil,
              CallKitController.shared.currentSystemCallUUID == nil,
              let model, !model.callLifecycleSnapshot.state.representsCall,
              model.deviceCallContext.reserveAdmission(requestID) else {
            replyHandler(["ok": false, "error": "已有通话或拨号任务正在进行"])
            return
        }
        if cancelledWatchDialIDs.remove(requestID) != nil {
            model.deviceCallContext.releaseAdmission(requestID)
            replyHandler(["ok": false, "error": "已取消拨号"])
            return
        }
        pendingWatchDialID = requestID
        defer {
            pendingWatchDialID = nil; cancelledWatchDialIDs.remove(requestID)
            // Legacy Watch/cloud media keep the admission reservation for
            // their whole call; owned local calls now hold the registry lease.
            if model.deviceCalls.active != nil || (localWatchCall?.requestID != requestID && watchOutgoingCall?.requestID != requestID) {
                model.deviceCallContext.releaseAdmission(requestID)
            }
        }
        do {
            if let owned = try await model.beginOwnedWatchDial(number: number, requestID: requestID, bound: boundAtStart),
               case let .vowlan(endpoint, credential) = owned.api.route {
                if cancelledWatchDialIDs.contains(requestID) {
                    try? await model.callKitEnd(uuid: owned.route.systemUUID)
                    replyHandler(["ok": false, "error": "已取消拨号"]); return
                }
                localWatchCall = LocalWatchCall(requestID: requestID, callID: owned.presentationID,
                    uuid: owned.route.systemUUID, api: owned.api, backendID: owned.backendID, agentID: owned.route.key.agentID)
                monitorLocalAudio(callID: owned.presentationID, backendID: owned.backendID, api: owned.api)
                replyHandler(["ok": true, "request_id": requestID.uuidString,
                    "call_id": owned.presentationID, "call_uuid": owned.route.systemUUID.uuidString,
                    "agent_id": owned.route.key.agentID, "number": number, "media_route": "vowlan",
                    "pcm_host": endpoint.host, "pcm_port": Int(endpoint.pcmPort), "pcm_secret": credential.encodedSecret,
                    "pcm_tls": endpoint.usesTLS,
                    "expires_at": Date().addingTimeInterval(300).timeIntervalSince1970])
                return
            }
            if let (api, pcmRoute) = await model.readyVoWLANRoute(),
               case let .vowlan(endpoint, credential) = pcmRoute {
                guard !cancelledWatchDialIDs.contains(requestID) else {
                    replyHandler(["ok": false, "error": "已取消拨号"])
                    return
                }
                try await api.dial(number: number, operationID: requestID)
                guard let record = await waitForOutgoingCall(api: api, number: number) else {
                    try? await api.hangupCall()
                    replyHandler(["ok": false, "error": "VoWLAN 未确认拨号状态"])
                    return
                }
                if cancelledWatchDialIDs.contains(requestID) {
                    try? await api.hangupCall(callID: record.id)
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
                    "pcm_tls": endpoint.usesTLS,
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
            let target = try CloudAgentRouting.select(boundAgentID: boundAtStart,
                agents: status.agents.filter { PairedAndroidDeviceStore.permits($0.agentID) },
                relayRoutingVersion: status.commandRoutingVersion)
            guard !cancelledWatchDialIDs.contains(requestID) else {
                replyHandler(["ok": false, "error": "已取消拨号"])
                return
            }
            // 没有可验证的本地 VoWLAN 时才回退公网 PCM。
            let outgoing = try await VoIPPushController.shared.startCloudOutgoingCall(
                number: number, target: target, operationID: requestID, mediaTransport: .legacyPCM, timeout: 15
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
                "agent_id": outgoing.agentID ?? "",
                "generation": outgoing.generation,
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
                    if active.callID.hasPrefix("local:"), let model { try await model.callKitEnd(uuid: active.uuid) }
                    else { try await active.api.hangupCall(callID: active.backendID) }
                    if localWatchCall?.callID == active.callID { localWatchCall = nil }
                    model?.deviceCallContext.releaseAdmission(requestID)
                } catch {
                    NSLog("[AirSIM Watch Dial] VoWLAN 取消失败：%@", error.localizedDescription)
                }
            }
        }
        if let active = watchOutgoingCall, active.requestID == requestID {
            watchOutgoingCall = nil
            model?.deviceCallContext.releaseAdmission(requestID)
            cancelledWatchDialIDs.remove(requestID)
            Task { await endAbandonedWatchCall(active.call) }
        }
    }

    @MainActor
    private func waitForOutgoingCall(api: AirSIMAPI, number: String) async -> CallRecord? {
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
    func answerLocallyFromWatch(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let callID = message["call_id"] as? String, !callID.isEmpty,
              let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)),
              !abandonedAnswers.contains(uuid), localWatchCall == nil, let model else {
            replyHandler(["ok": false, "error": "stale_call"]); return
        }
        let agentID = (message["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let owned = model.ownedWatchTarget(uuid: uuid, agentID: agentID, presentationID: callID)
        // A scoped local call must never fall back to the current default's API.
        if callID.hasPrefix("local:"), owned == nil {
            replyHandler(["ok": false, "error": "stale_call"]); return
        }
        let scopedAPI = agentID.flatMap { PairedAndroidDeviceStore.permits($0) ? model.localDevices.api(for: $0) : nil }
        let legacy = owned == nil && agentID == nil ? await model.readyVoWLANRoute() : nil
        guard let api = owned?.api ?? scopedAPI ?? legacy?.0,
              case let .vowlan(endpoint, credential) = AppModel.pcmRouteForWatch(api.route) else {
            replyHandler(["ok": false, "error": "VoWLAN 未就绪",
                          "cloud_media_allowed": CloudModePreference.isEnabled()])
            return
        }
        do {
            guard let current = try await api.callStatus().active,
                  [current.id, current.androidID, current.sourceCallID].compactMap({ $0 }).contains(owned?.backendID ?? callID),
                  ["incoming", "waiting"].contains(current.state),
                  !abandonedAnswers.contains(uuid), localWatchCall == nil else {
                replyHandler(["ok": false, "error": "来电已失效",
                              "cloud_media_allowed": CloudModePreference.isEnabled()])
                return
            }
            localWatchCall = LocalWatchCall(requestID: nil, callID: callID, uuid: uuid, api: api,
                backendID: owned?.backendID ?? current.id, agentID: owned?.route.key.agentID ?? agentID)
            do {
                if let owned { try await model.answerOwnedCallFromWatch(owned.route.key) }
                else { try await api.answerCall(callID: current.id) }
            } catch {
                if localWatchCall?.uuid == uuid { localWatchCall = nil }
                throw error
            }
            guard localWatchCall?.uuid == uuid, localWatchCall?.callID == callID else {
                if abandonedAnswers.contains(uuid) { await model.resumeAfterWatchHandoffFailure(uuid: uuid) }
                throw CancellationError()
            }
            monitorLocalAudio(callID: callID, backendID: owned?.backendID ?? current.id, api: api)
            replyHandler([
                "ok": true, "call_id": callID, "call_uuid": uuid.uuidString,
                "media_route": "vowlan", "pcm_host": endpoint.host,
                "pcm_port": Int(endpoint.pcmPort), "pcm_secret": credential.encodedSecret,
                "pcm_tls": endpoint.usesTLS,
                "cloud_media_allowed": CloudModePreference.isEnabled(),
            ])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription,
                          "cloud_media_allowed": CloudModePreference.isEnabled()])
        }
    }

    @MainActor
    func checkWatchEnd(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) async {
        let id = message["call_id"] as? String ?? ""
        let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
        var reply: [String: Any] = ["call_id": id, "call_uuid": uuid?.uuidString ?? ""]
        guard let uuid else { replyHandler(reply); return }
        let live = endCheckTargets[uuid].flatMap { $0.callID == id ? $0 : nil }
        let saved = endReferences.first { $0.uuid == uuid && $0.callID == id }
        let agentID = live?.agentID ?? saved?.agentID
        guard let backendID = live?.backendID ?? saved?.backendID,
              agentID.map({ PairedAndroidDeviceStore.permits($0) }) ?? true else {
            reply["ok"] = false; reply["error"] = "unknown_call"; replyHandler(reply); return
        }
        if saved?.confirmed == true {
            reply["ok"] = true; reply["confirmed"] = true; replyHandler(reply); return
        }
        guard let api = agentID.flatMap({ model?.localDevices.api(for: $0) }) ?? live?.api else {
            reply["ok"] = false; replyHandler(reply); return
        }
        do {
            let status = try await api.callStatus()
            let canonicalID = model?.watchCanonicalCallID(uuid: uuid, agentID: agentID) ?? saved?.canonicalID
            let confirmed = CallEndEvidence.confirms(status, id: backendID)
                || canonicalID.map { CallEndEvidence.confirms(status, id: $0) } == true
            if confirmed, let agentID { recordAndroidEnd(uuid: uuid, agentID: agentID, callIDs: [backendID]) }
            reply["ok"] = true
            reply["confirmed"] = confirmed
        } catch { reply["ok"] = false; reply["confirmed"] = false }
        replyHandler(reply)
    }

    @MainActor
    func endPhoneMirror(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) async {
        guard let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)),
              let model, let id = message["call_id"] as? String,
              model.matchesOwnedCallReference(uuid: uuid, presentationID: id) else {
            replyHandler(["ok": false, "error": "通话已失效，请刷新状态"]); return
        }
        // Router UUIDs retain bounded tombstones. Ending an old mirror is an
        // idempotent no-op, never an end command to the new/default call.
        do { try await model.callKitEnd(uuid: uuid); replyHandler(["ok": true]) }
        catch { replyHandler(["ok": false, "error": "结束请求未确认，请检查 iPhone"] ) }
    }

    @MainActor
    func sendWatchDTMF(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) async {
        guard let digit = message["digit"] as? String, WatchDTMFPolicy.validDigit(digit),
              let call = localWatchCall,
              message["call_id"] as? String == call.callID,
              (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)) == call.uuid,
              localEndInFlight != call.callID else {
            replyHandler(["ok": false, "error": "通话已失效或按键无效"]); return
        }
        do {
            let current = try await call.api.callStatus().active
            guard WatchDTMFPolicy.canSend(phase: current?.state, backendID: current?.id, expectedID: call.backendID),
                  localWatchCall?.uuid == call.uuid, localWatchCall?.callID == call.callID,
                  localEndInFlight != call.callID else {
                replyHandler(["ok": false, "error": "请在通话接通后使用小键盘"]); return
            }
            try await call.api.sendDTMF(digit, callID: call.backendID)
            replyHandler(["ok": true, "call_id": call.callID, "call_uuid": call.uuid.uuidString])
        } catch { replyHandler(["ok": false, "error": "按键未发送，请检查连接后重试"]) }
    }

    @MainActor
    func endLocalWatchCall(
        _ message: [String: Any], acknowledgeEarly: Bool = false, replyHandler upstreamReply: @escaping ([String: Any]) -> Void
    ) async {
        let once = WatchCompanionReplyOnce(upstreamReply)
        let replyHandler: ([String: Any]) -> Void = { once.send($0) }
        guard let call = localWatchCall,
              message["call_id"] as? String == call.callID,
              (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)) == call.uuid else {
            // A duplicate may arrive after successful end cleared the live
            // claim. Acknowledge only authenticated evidence for that exact call.
            if let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)),
               let previous = endCheckTargets[uuid], previous.callID == message["call_id"] as? String,
               previous.agentID.map({ PairedAndroidDeviceStore.permits($0) }) ?? true,
               let status = try? await previous.api.callStatus(),
               CallEndEvidence.confirms(status, id: previous.backendID) {
                replyHandler(["ok": true, "end_confirmation_supported": true]); return
            }
            replyHandler(["ok": false, "error": "stale_call"])
            return
        }
        guard localEndInFlight != call.callID else {
            replyHandler(["ok": true, "end_confirmation_supported": true])
            return
        }
        localEndInFlight = call.callID
        defer { localEndInFlight = nil }
        if acknowledgeEarly { replyHandler(["ok": true, "end_confirmation_supported": true]) }
        do {
            if call.callID.hasPrefix("local:"), let model {
                try await model.callKitEnd(uuid: call.uuid)
            } else { try await call.api.hangupCall(callID: call.backendID) }
            if localWatchCall?.callID == call.callID { localWatchCall = nil }
            if let reservation = call.requestID { model?.deviceCallContext.releaseAdmission(reservation) }
            replyHandler(["ok": true, "end_confirmation_supported": true])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription, "end_confirmation_supported": true])
        }
    }

    @MainActor
    func rejectLocalWatchCall(
        _ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        if let claimed = localWatchCall,
           message["call_id"] as? String == claimed.callID,
           message["call_uuid"] as? String == claimed.uuid.uuidString {
            // Watch can hang up while its answer is still awaiting Android.
            // End that captured call rather than rejecting a no-longer-ringing call.
            await endLocalWatchCall(message, replyHandler: replyHandler)
            return
        }
        if let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)),
           (message["call_id"] as? String)?.hasPrefix("local:") == true {
            guard let model, let target = model.ownedWatchTarget(uuid: uuid, agentID: message["agent_id"] as? String,
                presentationID: message["call_id"] as? String),
                  model.deviceCalls.latestEvent(for: target.route.key)?.state == .ringing else {
                replyHandler(["ok": false, "error": "stale_call"]); return
            }
            rememberEndCheck(LocalWatchCall(requestID: nil, callID: message["call_id"] as? String ?? "",
                uuid: uuid, api: target.api, backendID: target.backendID, agentID: target.route.key.agentID))
            do { try await model.callKitEnd(uuid: uuid); replyHandler(["ok": true, "end_confirmation_supported": true]) }
            catch { replyHandler(["ok": false, "error": error.localizedDescription, "end_confirmation_supported": true]) }
            return
        }
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
            if let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:)) {
                rememberEndCheck(LocalWatchCall(requestID: nil, callID: callID, uuid: uuid, api: api))
            }
            _ = try await api.rejectCall(callID: current.id)
            replyHandler(["ok": true, "end_confirmation_supported": true])
        } catch {
            replyHandler(["ok": false, "error": error.localizedDescription, "end_confirmation_supported": true])
        }
    }

    @MainActor
    private func monitorLocalAudio(callID: String, backendID: String? = nil, api: AirSIMAPI) {
        Task { @MainActor in
            for _ in 0..<120 {
                guard localWatchCall?.callID == callID else { return }
                if let current = try? await api.callStatus().active {
                    guard current.id == (backendID ?? callID) else { return }
                    if current.state == "active" {
                        let outcome = try? await CallAudioRegistrationCoordinator.register(service: api)
                        if outcome == .registered { return }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            NSLog("[AirSIM Watch] VoWLAN 音频主机注册超时；call=%@", callID)
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
                        NSLog("[AirSIM Watch Dial] 模块未确认挂断：%@", final.error ?? final.status)
                    }
                } catch {
                    NSLog("[AirSIM Watch Dial] 等待模块挂断确认失败：%@", error.localizedDescription)
                }
            }
        } catch {
            // 已拨号但交接失败必须可诊断，不能悄悄遗留蜂窝通话。
            NSLog("[AirSIM Watch Dial] 取消呼出失败：%@", error.localizedDescription)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            let lease = WatchRequestExecutionLease()
            defer { lease.end() }
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
            if !self.consumeWatchRegistration(message) { _ = await self.consumeWatchOwnership(message) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            let lease = WatchRequestExecutionLease()
            defer { lease.end() }
            if userInfo["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(userInfo, replyHandler: { _ in })
                return
            }
            if userInfo["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(userInfo, replyHandler: { _ in })
                return
            }
            if !self.consumeWatchRegistration(userInfo) { _ = await self.consumeWatchOwnership(userInfo) }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            let lease = WatchRequestExecutionLease()
            defer { lease.end() }
            if applicationContext["action"] as? String == "watch_local_end" {
                await self.endLocalWatchCall(applicationContext, replyHandler: { _ in })
                return
            }
            if applicationContext["action"] as? String == "watch_local_reject" {
                await self.rejectLocalWatchCall(applicationContext, replyHandler: { _ in })
                return
            }
            if !self.consumeWatchRegistration(applicationContext) { _ = await self.consumeWatchOwnership(applicationContext) }
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
		print("[AirSIM iPhone WC] 已接收 Watch VoIP token；字符数=\(token.count)")
#endif
        return true
    }

    @MainActor
    func consumeWatchOwnership(_ message: [String: Any]) async -> Bool {
        guard message["event"] as? String == "watch_call_owner",
              let phase = message["phase"] as? String else { return false }
        let callID = message["call_id"] as? String
        let uuid = (message["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
        if phase == "handoff_failed" {
            if let uuid, !abandonedAnswers.contains(uuid) {
                abandonedAnswers.append(uuid)
                if abandonedAnswers.count > 32 { abandonedAnswers.removeFirst() }
            }
            if let call = localWatchCall, call.requestID == nil, call.callID == callID, call.uuid == uuid {
                localWatchCall = nil
                await model?.resumeAfterWatchHandoffFailure(uuid: call.uuid)
            }
            return true
        }
        if phase == WatchCallPhase.ended.rawValue, let call = localWatchCall,
           call.callID == callID, call.uuid == uuid {
            // Owner notifications are durable, unlike a live RPC whose sender
            // can be suspended as soon as watchOS closes its call screen.
            await endLocalWatchCall(message, replyHandler: { _ in })
            return true
        }
        if let active = watchOutgoingCall, active.call.callID == callID, active.call.uuid == uuid,
           phase == WatchCallPhase.ended.rawValue {
            model?.deviceCallContext.releaseAdmission(active.requestID)
            watchOutgoingCall = nil
        }
        guard CallKitController.shared.matchesCurrentCall(callID: callID, uuid: uuid) else { return true }
        if phase == WatchCallPhase.active.rawValue {
            CallKitController.shared.reportCurrentCallEnded(reason: .answeredElsewhere)
        }
        return true
    }
}

private enum WatchCompanionPayloadError: Error { case tooLarge }

/// Explicitly holds execution while handling a background Watch message.
@MainActor
private final class WatchRequestExecutionLease {
    private var token: UIBackgroundTaskIdentifier = .invalid
    init() {
        token = UIApplication.shared.beginBackgroundTask(withName: "AirSIM Watch request") { [weak self] in
            Task { @MainActor [weak self] in self?.end() }
        }
    }
    func end() {
        guard token != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token); token = .invalid
    }
}

private final class WatchCompanionReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (([String: Any]) -> Void)?
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func send(_ reply: [String: Any]) {
        lock.lock(); let action = callback; callback = nil; lock.unlock()
        action?(reply)
    }
}
