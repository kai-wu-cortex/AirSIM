import Combine
import CryptoKit
import Foundation
import SwiftUI
import UserNotifications

struct OtherDeviceCallReminder: Identifiable, Equatable, Sendable {
    let key: DeviceCallKey
    let deviceName: String
    let number: String?
    let stillRinging: Bool
    var id: String { Self.notificationID(for: key) }
    static func notificationID(for key: DeviceCallKey) -> String {
        let value = "\(key.agentID.utf8.count):\(key.agentID)\(key.callID.utf8.count):\(key.callID):\(key.generation)"
        return "other-android-" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var userInfo: [String: Any] {
        ["event": "other_android_incoming", "agent_id": key.agentID,
         "call_id": key.callID, "generation": String(key.generation)]
    }
    static func key(from info: [AnyHashable: Any]) -> DeviceCallKey? {
        guard info["event"] as? String == "other_android_incoming",
              let agent = info["agent_id"] as? String, !agent.isEmpty, agent.utf8.count <= 512,
              let call = info["call_id"] as? String, !call.isEmpty, call.utf8.count <= 512,
              let raw = info["generation"] as? String, let generation = UInt64(raw), generation > 0 else { return nil }
        return .init(agentID: agent, callID: call, generation: generation)
    }
}

@MainActor
final class OtherDeviceCallReminderController: ObservableObject {
    @Published private(set) var reminders: [OtherDeviceCallReminder] = []
    private let lookup: (DeviceCallKey) -> OtherDeviceCallReminder?
    private let notify: (OtherDeviceCallReminder) async -> Void
    private let remove: (String) -> Void
    private var watched = Set<DeviceCallKey>()
    private var announced = Set<DeviceCallKey>()
    private var jobs: [DeviceCallKey: Task<Void, Never>] = [:]
    var onNewReminder: ((OtherDeviceCallReminder) -> Void)?
    init(lookup: @escaping (DeviceCallKey) -> OtherDeviceCallReminder?,
         notify: ((OtherDeviceCallReminder) async -> Void)? = nil, remove: ((String) -> Void)? = nil) {
        self.lookup = lookup
        self.notify = notify ?? { reminder in
            guard UIApplication.shared.applicationState != .active else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            guard lookup(reminder.key)?.stillRinging == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "其他安卓来电 · \(reminder.deviceName)"
            content.body = reminder.number ?? "号码未提供"
            content.userInfo = reminder.userInfo
            content.sound = nil // Never mix a second ringtone into the current call.
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: nil))
        }
        self.remove = remove ?? { id in
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }
    func consume(_ effects: [DeviceCallEffect]) {
        let previous = Set(reminders.map(\.key))
        for effect in effects {
            switch effect {
            case let .present(key), let .remind(key), let .update(key): watched.insert(key)
            case let .dismiss(key), let .ended(key):
                announced.remove(key)
                if watched.remove(key) != nil { remove(OtherDeviceCallReminder.notificationID(for: key)) }
                jobs.removeValue(forKey: key)?.cancel()
            }
        }
        reminders = watched.sorted { $0.generation < $1.generation }.compactMap(lookup).filter(\.stillRinging)
        let valid = Set(reminders.map(\.key))
        for key in previous.symmetricDifference(valid) {
            let phase = valid.contains(key) ? "reminder_added" : "reminder_removed"
            Task { @MainActor in
                await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "call", phase: phase,
                    title: "其他设备来电状态", fields: ["device_id": key.agentID,
                        "call_id": key.callID, "generation": String(key.generation)])
            }
        }
        for key in watched where !valid.contains(key) {
            if announced.contains(key) { remove(OtherDeviceCallReminder.notificationID(for: key)) }
        }
        for reminder in reminders where announced.insert(reminder.key).inserted {
            let key = reminder.key
            onNewReminder?(reminder)
            jobs[key] = Task { [weak self] in
                guard let self, let current = self.lookup(key), current.stillRinging, !Task.isCancelled else { return }
                await self.notify(current)
                // End may race notification authorization or delivery. Withdraw
                // again after add() completes so it cannot leave a stale alert.
                if Task.isCancelled || self.lookup(key)?.stillRinging != true { self.remove(current.id) }
                self.jobs.removeValue(forKey: key)
            }
        }
    }
    func waitForNotifications() async { for job in Array(jobs.values) { await job.value } }
}

struct OtherDeviceCallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let reminder: OtherDeviceCallReminder
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                if model.otherDeviceCallReminders.count > 1 {
                    Section("选择来电设备") {
                        ForEach(model.otherDeviceCallReminders) { item in
                            Button {
                                _ = model.openOtherDeviceCallNotification(item.userInfo)
                            } label: {
                                HStack {
                                    Text(item.deviceName)
                                    Spacer()
                                    if item.key == reminder.key { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                            .accessibilityIdentifier("other-device-\(item.key.agentID)")
                        }
                    }
                }
                Section("来电设备") {
                    Text(reminder.deviceName).font(.headline)
                    Text(reminder.number ?? "号码未提供")
                    Text(model.cloudCallOwnsPrimaryPresentation
                         ? "当前云端通话继续；请先结束当前通话再接听"
                         : (model.deviceCalls.active == nil
                            ? "接听将使用此设备的本地链路"
                            : "当前通话继续；请先结束当前通话再接听"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("接听此设备", action: answer)
                    .disabled(model.deviceCalls.active != nil || model.cloudCallOwnsPrimaryPresentation)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("其他设备来电")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func answer() {
        Task {
            do { try await model.answerOtherDeviceCall(reminder.key); dismiss() }
            catch { failure = error.localizedDescription }
        }
    }
}
