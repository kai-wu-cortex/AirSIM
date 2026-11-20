import CryptoKit
import Foundation
import UIKit
import WatchConnectivity

final class WatchCallCoordinator: NSObject, WCSessionDelegate {
    static let shared = WatchCallCoordinator()
    private weak var model: AppModel?
    private var session: WCSession?
    @MainActor private var watchReplyInFlight = false

    @MainActor
    func configure(model: AppModel) { self.model = model }

    @MainActor
    func start() {
        guard session == nil, WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

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
            guard action.hasPrefix("watch_sms_") else {
                replyHandler(["ok": false, "error": "Watch 仅支持短信"])
                return
            }
            if action == "watch_sms_direct_route" {
                replyHandler(await self.watchSMSDirectRoute(previousHost: message["previous_host"] as? String))
                return
            }
            if action == "watch_sms_reply_status" {
                await self.handleTrackedWatchSMS(message, statusOnly: true, replyHandler: replyHandler)
                return
            }
            if action == "watch_sms_reply_options" || action == "watch_sms_reply_send" || action == "watch_sms_tracked_reply_send" {
                await self.handleWatchReply(message, replyHandler: replyHandler)
                return
            }
            if action == "watch_sms_list", let model = self.model,
               !model.callLifecycleSnapshot.state.representsCall {
                await model.refreshMessages(silently: true)
            }
            if action.hasPrefix("watch_sms_") {
                self.handleWatchSMS(message, replyHandler: replyHandler)
                return
            }
        }
    }

    @MainActor
    private func watchSMSDirectRoute(previousHost: String?) async -> [String: Any] {
        let paired = PairedAndroidDeviceStore.records()
        guard paired.count == 1, let device = paired.first else { return ["revoked": true] }
        let existing = verifiedWatchRoute(agentID: device.id)
        if existing == nil || existing?.host == previousHost {
            await model?.refreshWatchSMSRoute(agentID: device.id, previousHost: previousHost)
        }
        guard let route = verifiedWatchRoute(agentID: device.id),
              let data = try? JSONEncoder().encode(route) else { return ["ok": false] }
        return ["ok": true, "route": data]
    }

    @MainActor
    private func verifiedWatchRoute(agentID: String) -> WatchSMSDirectRoute? {
        let paired = PairedAndroidDeviceStore.records()
        guard paired.count == 1, paired.first?.id == agentID,
              let api = model?.localDevices.api(for: agentID),
              case let .vowlan(endpoint, credential) = api.route, !endpoint.usesTLS else { return nil }
        let route = WatchSMSDirectRoute(agentID: agentID, host: endpoint.host, port: endpoint.controlPort,
            secret: WatchSMSDirectRoute.scopedSecret(credential.secret), clockOffset: credential.clockOffset)
        return route.allowsLocalAccess ? route : nil
    }

    @MainActor
    private func handleTrackedWatchSMS(_ message: [String: Any], statusOnly: Bool, recipient: String? = nil,
                                       replyHandler: ([String: Any]) -> Void) async {
        guard let agentID = message["agent_id"] as? String,
              let operation = message["operation_id"] as? String, UUID(uuidString: operation) != nil else {
            replyHandler(["ok": false, "error": "发送记录标识无效"]); return
        }
        guard let route = verifiedWatchRoute(agentID: agentID) else {
            replyHandler(["ok": false, "error": "iPhone 未连上已配对安卓"]); return
        }
        var payload: [String: Any] = ["operation_id": operation]
        if statusOnly {
            let capabilities: WatchSMSCapabilities? = try? await WatchSMSTransport.request("/api/watch/sms", route: route, timeout: 3)
            guard capabilities?.operation_status == true else {
                replyHandler(["ok": false, "uncertain": true]); return
            }
            payload["status_only"] = true
        } else {
            guard let recipient, let body = message["body"] as? String, let slot = message["slot_id"] as? String else {
                replyHandler(["ok": false, "error": "发送信息无效"]); return
            }
            let capabilities: WatchSMSCapabilities? = try? await WatchSMSTransport.request("/api/watch/sms", route: route)
            guard capabilities?.operation_status == true,
                  verifiedWatchRoute(agentID: agentID) == route,
                  model?.callLifecycleSnapshot.state.representsCall == false,
                  let deadline = message["expires_at"] as? TimeInterval, deadline > Date().timeIntervalSince1970 else {
                replyHandler(["ok": false, "error": "安卓未就绪，短信未发送"]); return
            }
            payload["number"] = recipient
            payload["body"] = body
            payload["slot"] = slot
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let result: WatchDirectSend = try await WatchSMSTransport.request("/api/watch/sms/send", route: route,
                                                                              body: data, timeout: statusOnly ? 5 : nil)
            switch result.outcome {
            case .sent:
                if !statusOnly, let recipient, let body = payload["body"] as? String, let slotID = payload["slot"] as? String {
                    model?.recordTrackedWatchSMS(recipient: recipient, body: body, agentID: agentID,
                                                slotID: slotID, deliveryID: operation)
                }
                replyHandler(["ok": true, "status_result": statusOnly])
            case .uncertain: replyHandler(["ok": false, "uncertain": true, "status_result": statusOnly])
            case let .failed(error): replyHandler(["ok": false, "error": error, "status_result": statusOnly])
            }
        } catch {
            replyHandler(["ok": false, "uncertain": true])
        }
    }

    @MainActor
    func handleWatchReply(_ message: [String: Any], replyHandler: ([String: Any]) -> Void) async {
        func fail(_ error: String) { replyHandler(["ok": false, "error": error]) }
        guard let model, !model.callLifecycleSnapshot.state.representsCall else {
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
        let tracked = message["action"] as? String == "watch_sms_tracked_reply_send"
        guard tracked || message["action"] as? String == "watch_sms_reply_send",
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
        if tracked {
            await handleTrackedWatchSMS(message, statusOnly: false, recipient: recipient, replyHandler: replyHandler)
            return
        }
        switch await model.sendWatchSMSReply(recipient: recipient, body: body, agentID: agentID, slotID: slotID) {
        case .sent: replyHandler(["ok": true])
        case let .failed(message): fail(message)
        case .uncertain: replyHandler(["ok": false, "uncertain": true])
        }
    }

    @MainActor
    func handleWatchSMS(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let model else { replyHandler(["ok": false, "error": "iPhone 尚未就绪"]); return }
        guard !model.callLifecycleSnapshot.state.representsCall else {
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
                outgoing: record.isOutgoing, unread: model.unreadMessageIDs.contains(record.id),
                deliveryKey: record.deliveryID.flatMap { $0.isEmpty ? nil : WatchSMSPolicy.digest($0) })
        }
        do {
            let action = message["action"] as? String
            if action == "watch_sms_read_batch" {
                guard let selected, requested == selected, let keys = message["read_keys"] as? [String],
                      !keys.isEmpty, keys.count <= 40, keys.allSatisfy({ $0.utf8.count <= 80 }) else {
                    replyHandler(["ok": false]); return
                }
                let pending = Set(keys)
                let matches = records.compactMap { record -> (String, SMSMessage)? in
                    guard !record.isOutgoing else { return nil }
                    let delivery = record.deliveryID.flatMap { $0.isEmpty ? nil : WatchSMSPolicy.digest($0) }
                    let key = WatchSMSPolicy.readKey(messageID: opaqueID(record), deliveryKey: delivery)
                    return pending.contains(key) ? (key, record) : nil
                }
                model.markMessagesRead(matches.map { $0.1 })
                let accepted = matches.filter { !model.unreadMessageIDs.contains($0.1.id) }.map { $0.0 }
                replyHandler(["ok": true, "accepted": Array(Set(accepted))])
                return
            }
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
