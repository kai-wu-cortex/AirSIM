import ActivityKit
import UIKit

enum LiveActivityCreationPolicy {
    static func shouldCreate(
        appIsActive: Bool,
        moduleOnline: Bool,
        hasActivity: Bool
    ) -> Bool {
        !hasActivity && appIsActive
    }
}

enum LiveActivityStateBuilder {
    static func make(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: DJOneHubCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        idleStartedAt: Date,
        downloadBytesPerSecond: Double? = nil,
        uploadBytesPerSecond: Double? = nil
    ) -> DJOneHubCallActivityAttributes.ContentState {
        // 只有本地控制与 Relay 心跳同时不可达才显示离线；云端心跳新鲜时使用
        // 独立待机态，避免把 USB ECM 中断误报成整个模块离线。
        guard moduleOnline || cloudOnline else {
            return .init(
                callID: "",
                number: "",
                displayName: "模块离线",
                phase: .offline,
                startedAt: idleStartedAt
            )
        }
        guard let call else {
            let cloudOnly = cloudOnline && !moduleOnline
            return .init(
                callID: "",
                number: "",
                displayName: cloudOnly ? "公网中继已连接" : "等待模块来电",
                phase: cloudOnly ? .cloudStandby : .standby,
                startedAt: idleStartedAt,
                transport: cloudOnly ? .cloud : transport,
                signalDBM: radio?.signalDBM,
                operatorName: radio?.operatorName,
                networkMode: radio?.networkMode,
                radioBand: radio?.radioBand,
                downloadBytesPerSecond: nil,
                uploadBytesPerSecond: nil
            )
        }

        let phase: DJOneHubCallActivityAttributes.ContentState.Phase
        if call.direction == "incoming", ["incoming", "waiting"].contains(call.state) {
            phase = .incoming
        } else if call.state == "held" {
            phase = .held
        } else {
            phase = .active
        }
        let number = call.number?.isEmpty == false ? call.number! : "未知号码"
        return .init(
            callID: call.id,
            number: number,
            displayName: callerName?.isEmpty == false ? callerName! : number,
            phase: phase,
            startedAt: call.startedAt,
            transport: transport
        )
    }
}

/// 主 App 负责预启动并持续同步灵动岛；后台只能更新已经存在的 Live Activity。
@MainActor
final class LiveActivityController {
    private var activity: Activity<DJOneHubCallActivityAttributes>?
    private var lastState: DJOneHubCallActivityAttributes.ContentState?
    private let idleStartedAt = Date()
    private var enabled = true

    /// 用户关闭开关时立即清理系统活动；重新开启后由下一轮模块状态同步按需创建。
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            Task { @MainActor [weak self] in await self?.stop() }
        }
    }

    func update(
        call: CallRecord?,
        callerName: String?,
        moduleOnline: Bool,
        cloudOnline: Bool = false,
        transport: DJOneHubCallActivityAttributes.ContentState.Transport? = nil,
        radio: ModemStatus?,
        appIsActive: Bool,
        downloadBytesPerSecond: Double? = nil,
        uploadBytesPerSecond: Double? = nil
    ) async {
        guard enabled, UIDevice.current.userInterfaceIdiom == .phone else { return }
        resolveExistingActivity()
#if DEBUG
        let requestedPhase = call != nil ? "call" : (moduleOnline ? "standby" : (cloudOnline ? "cloud_standby" : "offline"))
        print("[DJOneHub LiveActivity] requestedPhase=\(requestedPhase) existingCount=\(Activity<DJOneHubCallActivityAttributes>.activities.count) selected=\(activity?.id ?? "none")")
#endif

        if activity == nil {
            // iOS 不保证后台能本地创建活动。前台离线时也允许创建，以替换升级安装后
            // 系统仍显示、但 Activity.activities 已无法返回句柄的孤立活动。
            guard LiveActivityCreationPolicy.shouldCreate(
                      appIsActive: appIsActive,
                      moduleOnline: moduleOnline,
                      hasActivity: false
                  ),
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                let initialState = LiveActivityStateBuilder.make(
                    call: call,
                    callerName: callerName,
                    moduleOnline: moduleOnline,
                    cloudOnline: cloudOnline,
                    transport: transport,
                    radio: radio,
                    idleStartedAt: idleStartedAt,
                    downloadBytesPerSecond: downloadBytesPerSecond,
                    uploadBytesPerSecond: uploadBytesPerSecond
                )
                activity = try Activity.request(
                    attributes: DJOneHubCallActivityAttributes(moduleName: "AirSIM"),
                    content: ActivityContent(
                        state: initialState,
                        staleDate: nil
                    ),
                    pushType: .token
                )
                if let activity {
                    VoIPPushController.shared.observeLiveActivity(activity)
                }
#if DEBUG
                print("[DJOneHub LiveActivity] created id=\(activity?.id ?? "none") phase=\(initialState.phase.rawValue)")
#endif
                lastState = initialState
            } catch {
                return
            }
        } else if let activity {
            let nextState = LiveActivityStateBuilder.make(
                call: call,
                callerName: callerName,
                moduleOnline: moduleOnline,
                cloudOnline: cloudOnline,
                transport: transport,
                radio: radio,
                idleStartedAt: idleStartedAt,
                downloadBytesPerSecond: downloadBytesPerSecond,
                uploadBytesPerSecond: uploadBytesPerSecond
            )
            // 在线/离线由真实模块请求决定；不以 ActivityKit stale 代替连通性探测。
            guard nextState != lastState else { return }
            await activity.update(
                ActivityContent(
                    state: nextState,
                    staleDate: nil
                )
            )
#if DEBUG
            print("[DJOneHub LiveActivity] updated id=\(activity.id) phase=\(nextState.phase.rawValue)")
#endif
            lastState = nextState
        }
    }

    func markOffline(appIsActive: Bool) async {
        await update(call: nil, callerName: nil, moduleOnline: false, radio: nil, appIsActive: appIsActive)
    }

    func stop() async {
        resolveExistingActivity()
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastState = nil
    }

    private func resolveExistingActivity() {
        guard activity == nil else { return }
        let existing = Activity<DJOneHubCallActivityAttributes>.activities
        activity = existing.first
        if let activity {
            VoIPPushController.shared.observeLiveActivity(activity)
        }
#if DEBUG
        let summary = existing.map { "\($0.id):\($0.content.state.phase.rawValue)" }.joined(separator: ",")
        print("[DJOneHub LiveActivity] resolved count=\(existing.count) activities=[\(summary)]")
#endif
        lastState = activity?.content.state
    }

}
