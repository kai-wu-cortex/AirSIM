import ActivityKit
import UIKit

enum LiveActivityCreationPolicy {
    static func pushType(localModeEnabled: Bool) -> PushType? {
        localModeEnabled ? nil : .token
    }

    static func shouldCreate(
        appIsActive: Bool,
        moduleOnline: Bool,
        hasActivity: Bool
    ) -> Bool {
        !hasActivity && appIsActive
    }
}

enum LiveActivityAgentOrder {
    static let orderKey = "airsim.live-activity-agent-order"
    static let pinnedKey = "airsim.live-activity-pinned-agents"

    static func ordered(
        _ agents: [AndroidAgentPresentation],
        defaults: UserDefaults = .standard
    ) -> [AndroidAgentPresentation] {
        let pinned = Set(defaults.stringArray(forKey: pinnedKey) ?? [])
        let order = defaults.stringArray(forKey: orderKey) ?? []
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return agents.sorted { left, right in
            let leftPinned = pinned.contains(left.id)
            let rightPinned = pinned.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            let leftRank = rank[left.id] ?? Int.max
            let rightRank = rank[right.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.deviceName.localizedCaseInsensitiveCompare(right.deviceName) == .orderedAscending
        }
    }

    static func isPinned(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        Set(defaults.stringArray(forKey: pinnedKey) ?? []).contains(id)
    }

    static func togglePin(_ id: String, defaults: UserDefaults = .standard) {
        var pinned = Set(defaults.stringArray(forKey: pinnedKey) ?? [])
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        defaults.set(Array(pinned).sorted(), forKey: pinnedKey)
    }

    /// Moves one row within the currently visible order and persists the full
    /// normalized order so later additions append instead of reshuffling.
    static func move(
        _ id: String,
        by delta: Int,
        agents: [AndroidAgentPresentation],
        defaults: UserDefaults = .standard
    ) {
        var ids = ordered(agents, defaults: defaults).map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        defaults.set(ids, forKey: orderKey)
    }
}

struct LiveActivityAgentSnapshot: Equatable {
    let deviceName: String?
    let phoneNumber: String?
    let agentKind: String?
    let pairedAgentCount: Int
    let vowlanOnline: Bool
    let bluetoothOnline: Bool
    let cloudOnline: Bool
    let agents: [AirSIMCallActivityAttributes.ContentState.AgentSummary]
    let page: Int

    init(
        agent: AndroidAgentPresentation?,
        pairedAgentCount: Int,
        agents: [AndroidAgentPresentation] = [],
        currentID: String? = nil,
        page: Int = 0
    ) {
        let current = agent
            ?? agents.first(where: { $0.id == currentID })
            ?? agents.first(where: \.isCurrent)
            ?? agents.first
        deviceName = current?.deviceName
        phoneNumber = current?.phoneNumber
        agentKind = current?.agentKind
        self.pairedAgentCount = pairedAgentCount
        vowlanOnline = current?.vowlanOnline == true
        bluetoothOnline = current?.bluetoothOnline == true
        cloudOnline = current?.cloudOnline == true
        self.page = max(0, page)
        self.agents = agents.map { value in
            AirSIMCallActivityAttributes.ContentState.AgentSummary(
                id: value.id,
                name: value.deviceName,
                phoneNumber: value.phoneNumber,
                agentKind: value.agentKind,
                vowlanOnline: value.vowlanOnline,
                bluetoothOnline: value.bluetoothOnline,
                cloudOnline: value.cloudOnline,
                isCurrent: value.id == current?.id
            )
        }
    }
}

enum LiveActivityStateBuilder {
    static func make(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: AirSIMCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        agent: LiveActivityAgentSnapshot? = nil,
        idleStartedAt: Date,
        downloadBytesPerSecond: Double? = nil,
        uploadBytesPerSecond: Double? = nil
    ) -> AirSIMCallActivityAttributes.ContentState {
        // VoWLAN 本地控制、Relay 心跳、VoBLE 任一路可达即视为 Agent 在线。
        // 双通道下 Wi-Fi 断开但 BLE 仍连着时，不能把整个 Agent 误报成离线。
        // When a paired device is selected, its verified channels are authoritative.
        // A global/previous-device flag must not contradict the device rows.
        let localOnline = agent.map { $0.vowlanOnline || $0.bluetoothOnline } ?? moduleOnline
        let relayOnline = agent?.cloudOnline ?? cloudOnline
        guard localOnline || relayOnline else {
            return .init(
                callID: "",
                number: "",
                displayName: "Agent 离线",
                phase: .offline,
                startedAt: idleStartedAt,
                agentDeviceName: agent?.deviceName,
                agentPhoneNumber: agent?.phoneNumber,
                agentKind: agent?.agentKind,
                pairedAgentCount: agent?.pairedAgentCount,
                vowlanOnline: agent?.vowlanOnline,
                bluetoothOnline: agent?.bluetoothOnline,
                cloudOnline: agent?.cloudOnline,
                agents: agent?.agents,
                agentPage: agent?.page
            )
        }
        // Calls are managed exclusively by CallKit; the Live Activity is an Agent-status
        // surface only. Never publish incoming/active/held phases or call action buttons.
        let cloudOnly = relayOnline && !localOnline
        return .init(
            callID: "",
            number: "",
            displayName: cloudOnly ? "公网中继已连接" : "等待 Agent 来电",
            phase: cloudOnly ? .cloudStandby : .standby,
            startedAt: idleStartedAt,
            transport: cloudOnly ? .cloud : transport,
            signalDBM: radio?.signalDBM,
            operatorName: radio?.operatorName,
            networkMode: radio?.networkMode,
            radioBand: radio?.radioBand,
            downloadBytesPerSecond: nil,
            uploadBytesPerSecond: nil,
            agentDeviceName: agent?.deviceName,
            agentPhoneNumber: agent?.phoneNumber,
            agentKind: agent?.agentKind,
            pairedAgentCount: agent?.pairedAgentCount,
            vowlanOnline: agent?.vowlanOnline,
            bluetoothOnline: agent?.bluetoothOnline,
            cloudOnline: agent?.cloudOnline,
            agents: agent?.agents,
            agentPage: agent?.page
        )
    }
}

struct LiveActivityEntry {
    let id: String
    let state: AirSIMCallActivityAttributes.ContentState
    let isRunning: Bool
}

/// Keep the system boundary injectable so restart, duplicate and suspended-update
/// races can be exercised without creating real lock-screen activities in tests.
@MainActor
protocol LiveActivityStore: AnyObject {
    var available: Bool { get }
    var onActivityAdded: (() -> Void)? { get set }
    func entries() -> [LiveActivityEntry]
    func create(_ state: AirSIMCallActivityAttributes.ContentState) throws -> String
    func update(_ id: String, state: AirSIMCallActivityAttributes.ContentState) async
    func end(_ id: String) async
}

@MainActor
final class SystemLiveActivityStore: LiveActivityStore {
    var onActivityAdded: (() -> Void)?
    private var handles: [String: Activity<AirSIMCallActivityAttributes>] = [:]
    private var observation: Task<Void, Never>?
    var available: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    init() {
        observation = Task { @MainActor [weak self] in
            for await activity in Activity<AirSIMCallActivityAttributes>.activityUpdates {
                guard !Task.isCancelled, let self else { return }
                self.handles[activity.id] = activity
                self.onActivityAdded?()
            }
        }
    }

    deinit { observation?.cancel() }

    func entries() -> [LiveActivityEntry] {
        for activity in Activity<AirSIMCallActivityAttributes>.activities { handles[activity.id] = activity }
        return handles.values.map {
            .init(id: $0.id, state: $0.content.state,
                  isRunning: $0.activityState == .active || $0.activityState == .stale)
        }
    }

    func create(_ state: AirSIMCallActivityAttributes.ContentState) throws -> String {
        let activity = try Activity.request(attributes: AirSIMCallActivityAttributes(moduleName: "AirSIM"),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: LiveActivityCreationPolicy.pushType(localModeEnabled: !CloudModePreference.isEnabled()))
        handles[activity.id] = activity
        VoIPPushController.shared.observeLiveActivity(activity)
        return activity.id
    }

    func update(_ id: String, state: AirSIMCallActivityAttributes.ContentState) async {
        guard let activity = handles[id] else { return }
        VoIPPushController.shared.observeLiveActivity(activity)
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end(_ id: String) async {
        guard let activity = handles[id] else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        handles.removeValue(forKey: id)
    }
}

/// One aggregate status activity for all paired devices. Serialize ActivityKit
/// mutations: @MainActor alone does not prevent reentrancy across await.
@MainActor
final class LiveActivityController {
    private struct Request {
        let state: AirSIMCallActivityAttributes.ContentState
        let appIsActive: Bool
        let force: Bool
    }
    private let store: any LiveActivityStore
    private var selectedID: String?
    private var desired: Request?
    private var revision = 0
    private var needsSync = false
    private var syncing = false
    private let idleStartedAt = Date()
    private var enabled = true

    init(store: (any LiveActivityStore)? = nil) {
        self.store = store ?? SystemLiveActivityStore()
        self.store.onActivityAdded = { [weak self] in
            guard let self, self.desired != nil || !self.enabled else { return }
            self.needsSync = true
            Task { await self.drain() }
        }
    }

    /// 用户关闭开关时立即清理系统活动；重新开启后由下一轮模块状态同步按需创建。
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            desired = nil
            revision &+= 1
            needsSync = true
            Task { [weak self] in await self?.drain() }
        }
    }

    func update(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: AirSIMCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        agent: LiveActivityAgentSnapshot? = nil,
        appIsActive: Bool,
        downloadBytesPerSecond: Double? = nil,
        uploadBytesPerSecond: Double? = nil,
        force: Bool = false
    ) async {
        guard enabled else { return }
        desired = Request(state: LiveActivityStateBuilder.make(
            call: call, callerName: callerName, moduleOnline: moduleOnline, cloudOnline: cloudOnline,
            transport: transport, radio: radio, agent: agent, idleStartedAt: idleStartedAt,
            downloadBytesPerSecond: downloadBytesPerSecond, uploadBytesPerSecond: uploadBytesPerSecond),
            appIsActive: appIsActive, force: force)
        revision &+= 1
        needsSync = true
        await drain()
    }

    func markOffline(agent: LiveActivityAgentSnapshot? = nil, appIsActive: Bool) async {
        await update(
            call: nil,
            callerName: nil,
            moduleOnline: false,
            radio: nil,
            agent: agent,
            appIsActive: appIsActive
        )
    }

    func stop() async {
        desired = nil
        revision &+= 1
        needsSync = true
        await drain()
    }

    private func drain() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while needsSync {
            needsSync = false
            let currentRevision = revision
            let entries = store.entries()
            guard enabled, let request = desired else {
                selectedID = nil
                for entry in entries {
                    guard revision == currentRevision else { break }
                    await store.end(entry.id)
                }
                continue
            }
            let running = entries.filter(\.isRunning).sorted { $0.id < $1.id }
            let selected = running.first { $0.id == selectedID } ?? running.first
            selectedID = selected?.id
            // End both duplicates and lingering ended cards immediately. Never
            // update only the first entry and leave the rest on the lock screen.
            for entry in entries where entry.id != selectedID {
                guard revision == currentRevision else { break }
                await store.end(entry.id)
            }
            guard revision == currentRevision else { continue }
            if let selected {
                // Compare actual ActivityKit content, not a cache of our last write:
                // a remote update or a recovered handle may have changed it.
                if request.force || selected.state != request.state {
                    await store.update(selected.id, state: request.state)
                }
            } else if request.appIsActive, store.available {
                do { selectedID = try store.create(request.state) }
                catch {
#if DEBUG
                    print("[AirSIM LiveActivity] create_failed error=\(error)")
#endif
                }
            }
        }
    }

}
