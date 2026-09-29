import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AirSIMLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AirSIMLiveActivityWidget()
    }
}

/// 待机态保持极简，展开与锁屏态再呈现网络详情和通话动作。
struct AirSIMLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AirSIMCallActivityAttributes.self) { context in
            let state = context.state.liveActivityDisplayState(isStale: context.isStale)
            lockScreenView(state)
                .foregroundStyle(.white)
                .activityBackgroundTint(activityBackgroundTint(for: state))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state.liveActivityDisplayState(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandIdentity(for: state)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(idleTitle(state))
                            .font(.headline)
                            .lineLimit(1)
                        Text(activityStatusLine(state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint(for: state.phase))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailingView(state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottomView(state)
                }
            } compactLeading: {
                compactLeadingView(state)
            } compactTrailing: {
                compactTrailingView(state)
            } minimal: {
                Image(systemName: compactSymbolName(for: state))
                    .foregroundStyle(tint(for: state.phase))
            }
            .keylineTint(tint(for: state.phase))
        }
    }

    @ViewBuilder
    private func islandIdentity(
        for state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .standby || state.phase == .cloudStandby {
            statusMark(for: state.phase, size: 38)
        } else if state.phase == .incoming || state.phase == .active || state.phase == .held {
            callerMark(size: 38)
        } else {
            statusMark(for: state.phase, size: 38)
        }
    }

    @ViewBuilder
    private func compactLeadingView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .standby || state.phase == .cloudStandby {
            Image(systemName: compactSymbolName(for: state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint(for: state.phase))
        } else {
            Image(systemName: symbolName(for: state.phase))
                .foregroundStyle(tint(for: state.phase))
        }
    }

    @ViewBuilder
    private func expandedTrailingView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .standby:
            if state.transport == .vowlan {
                Text("VoWLAN")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        case .cloudStandby:
            Text("在线")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
        case .active:
            Text(state.startedAt, style: .timer)
                .font(.caption.weight(.semibold).monospacedDigit())
        case .incoming:
            Image(systemName: "phone.badge.waveform.fill")
                .foregroundStyle(.green)
        case .held:
            Text("保持")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .offline:
            Text("离线")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func lockScreenView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if state.phase == .standby || state.phase == .cloudStandby {
                    statusMark(for: state.phase, size: 44)
                } else if state.phase == .incoming || state.phase == .active || state.phase == .held {
                    callerMark(size: 44)
                } else {
                    statusMark(for: state.phase, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(idleTitle(state))
                        .font(.headline)
                        .lineLimit(1)
                    if state.phase == .standby {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(state.transport == .vowlan ? "VoWLAN 在线" : "模块在线")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        Text(standbyNetworkLine(state))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    } else if state.phase == .cloudStandby {
                        HStack(spacing: 5) {
                            Circle().fill(Color.cyan).frame(width: 7, height: 7)
                            Text("云端在线")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.cyan)
                        }
                        Text("公网中继保持连接 · 可接收来电与短信")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    } else {
                        Text(activityStatusLine(state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint(for: state.phase))
                    }
                }
                Spacer(minLength: 8)
                lockScreenMetric(state)
            }

            if state.phase != .standby && state.phase != .cloudStandby && state.phase != .offline {
                actionButtons(state)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // ActivityKit 在锁屏上已经提供系统级 Live Activity 容器。iOS 26 再给
        // 根内容叠加 glassEffect 会生成第二个采样层，真机上可能只显示空玻璃壳。
        // 透明 activityBackgroundTint 负责启用宿主 Liquid Glass，正文保持普通布局。
    }

    @ViewBuilder
    private func lockScreenMetric(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .active {
            Text(state.startedAt, style: .timer)
                .font(.title3.weight(.semibold).monospacedDigit())
        } else if state.phase == .standby {
            VStack(alignment: .trailing, spacing: 2) {
                signalBars(dbm: state.signalDBM)
                if let signal = state.signalDBM {
                    Text("\(signal) dBm")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        } else if state.phase == .cloudStandby {
            Image(systemName: "checkmark.icloud.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.cyan)
        } else if state.phase == .incoming {
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
        } else if state.phase == .offline {
            Text("离线")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private func expandedBottomView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .standby:
            standbyDashboard(state)
        case .cloudStandby:
            Label("Agent 已连接安全公网中继", systemImage: "lock.icloud.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.76))
                .padding(.top, 4)
        case .offline:
            Label("等待三星网络恢复", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .padding(.top, 4)
        case .incoming, .active, .held:
            actionButtons(state)
        }
    }

    @ViewBuilder
    private func actionButtons(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            switch state.phase {
            case .incoming:
                HStack(spacing: 10) {
                    Button(intent: RejectAirSIMCallIntent(callID: state.callID)) {
                        Label("拒绝", systemImage: "phone.down.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .modifier(LiveActivityGlassButtonStyle(
                        prominent: false,
                        tint: Color.white.opacity(0.17)
                    ))

                    Button(intent: AnswerAirSIMCallIntent(callID: state.callID)) {
                        Label("接听", systemImage: "phone.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .modifier(LiveActivityGlassButtonStyle(prominent: true, tint: .green))
                }
            case .active, .held:
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: state.phase == .held ? "pause.fill" : "waveform")
                            .foregroundStyle(tint(for: state.phase))
                        Text(state.phase == .held ? "通话保持" : "通话中")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.16), in: Capsule())

                    Button(intent: HangUpAirSIMCallIntent(callID: state.callID)) {
                        Label("挂断", systemImage: "phone.down.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .modifier(LiveActivityGlassButtonStyle(prominent: true, tint: .red))
                }
            case .standby, .cloudStandby, .offline:
                EmptyView()
            }
        } else if state.phase == .incoming {
            Text("打开 AirSIM 接听")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    @ViewBuilder
    private func compactTrailingView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .active:
            Text(state.startedAt, style: .timer)
                .font(.caption2.monospacedDigit())
                .frame(width: 42)
        case .incoming:
            Text("来电")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .standby:
            Image(systemName: "cellularbars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        case .cloudStandby:
            Image(systemName: "checkmark.icloud.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
        case .held:
            Image(systemName: "pause.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .offline:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func standbyDashboard(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 0) {
            dashboardMetric(nonEmpty(state.networkMode) ?? "网络")
            if let band = nonEmpty(state.radioBand) {
                metricDivider
                dashboardMetric(band)
            }
            metricDivider
            HStack(spacing: 6) {
                signalBars(dbm: state.signalDBM)
                if let signal = state.signalDBM {
                    Text("\(signal) dBm")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func dashboardMetric(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        Capsule()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 18)
    }

    private func signalBars(dbm: Int?) -> some View {
        let strength: Int
        let measured = dbm ?? -120
        if measured >= -79 {
            strength = 4
        } else if measured >= -89 {
            strength = 3
        } else if measured >= -99 {
            strength = 2
        } else if measured >= -109 {
            strength = 1
        } else {
            strength = 0
        }
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < strength ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .frame(height: 14)
        .accessibilityLabel(dbm.map { "信号 \($0) dBm" } ?? "信号未知")
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func standbyNetworkLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        var parts: [String] = []
        if let mode = state.networkMode, !mode.isEmpty { parts.append(mode) }
        if let band = state.radioBand, !band.isEmpty { parts.append(band) }
        return parts.isEmpty ? "正在读取蜂窝网络" : parts.joined(separator: " · ")
    }

    private func standbyCarrierName(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        nonEmpty(state.operatorName) ?? "蜂窝网络"
    }

    private func idleTitle(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        switch state.phase {
        case .standby:
            return standbyCarrierName(state)
        case .cloudStandby:
            return "云端在线"
        case .incoming, .active, .held, .offline:
            return state.displayName
        }
    }

    private func activityBackgroundTint(
        for state: AirSIMCallActivityAttributes.ContentState
    ) -> Color {
        if #available(iOSApplicationExtension 26.0, *) {
            // 所有阶段让锁屏壁纸成为系统 Liquid Glass 的采样背景。
            return .clear
        }
        return Color(red: 0.012, green: 0.028, blue: 0.065)
    }

    private func statusMark(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase,
        size: CGFloat
    ) -> some View {
        Image(systemName: symbolName(for: phase))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint(for: phase))
            .frame(width: size, height: size)
            .background(tint(for: phase).opacity(0.2), in: Circle())
    }

    private func callerMark(size: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.18), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func symbolName(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase
    ) -> String {
        switch phase {
        case .standby: return "antenna.radiowaves.left.and.right"
        case .cloudStandby: return "icloud.fill"
        case .incoming: return "phone.arrow.down.left.fill"
        case .active: return "waveform"
        case .held: return "pause.fill"
        case .offline: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func compactSymbolName(
        for state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        if state.transport == .vowlan,
           state.phase != .offline,
           state.phase != .cloudStandby {
            return state.transport?.systemImage ?? "wifi"
        }
        return symbolName(for: state.phase)
    }

    private func activityStatusLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        guard let transport = state.transport else { return state.phase.title }
        switch state.phase {
        case .incoming, .active, .held:
            return "\(state.phase.title) · \(transport.title)"
        case .standby:
            return "\(transport.title) 在线"
        case .cloudStandby, .offline:
            return state.phase.title
        }
    }

    private func tint(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase
    ) -> Color {
        switch phase {
        case .incoming, .active, .standby: return .green
        case .cloudStandby: return .cyan
        case .held: return .orange
        case .offline: return .secondary
        }
    }

}

private struct LiveActivityGlassButtonStyle: ViewModifier {
    let prominent: Bool
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(tint)
            } else {
                content.buttonStyle(.glass).tint(tint)
            }
        } else {
            content.buttonStyle(.borderedProminent).tint(tint)
        }
    }
}
