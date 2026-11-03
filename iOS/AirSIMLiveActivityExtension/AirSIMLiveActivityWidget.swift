import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AirSIMLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AirSIMLiveActivityWidget()
        AirSIMDeviceWidget()
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
                    if usesAgentList(state) {
                        agentListBrandMark
                            .padding(.top, 2)
                            .padding(.leading, 2)
                    } else {
                        islandIdentity(for: state)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if usesAgentList(state) {
                        agentListCenter(state)
                    } else {
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
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if usesAgentList(state) {
                        agentListCount(state)
                            .padding(.top, 2)
                            .padding(.trailing, 2)
                    } else {
                        expandedTrailingView(state)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if usesAgentList(state) {
                        expandedAgentList(state)
                    } else {
                        expandedBottomView(state)
                    }
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
            statusMark(for: state.phase, size: 32)
        } else if state.phase == .incoming || state.phase == .active || state.phase == .held {
            callerMark(size: 32)
        } else {
            statusMark(for: state.phase, size: 32)
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
            agentSwitchControl(state)
        case .cloudStandby:
            agentSwitchControl(state)
        case .active, .incoming, .held:
            EmptyView()
        case .offline:
            Text("离线")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lockScreenView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if usesAgentList(state) {
            agentListLockScreen(state)
        } else {
            callLockScreenView(state)
        }
    }

    private func callLockScreenView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        let callPhase = state.phase == .incoming || state.phase == .active || state.phase == .held
        return VStack(spacing: callPhase ? 10 : 12) {
            HStack(spacing: 10) {
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
                        .minimumScaleFactor(0.8)
                    if state.phase == .standby {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(connectionStatusLine(state) ?? "Agent 在线")
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
                Spacer(minLength: 6)
                lockScreenMetric(state)
                    .layoutPriority(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // Call phases already use the height for the action row; repeating the
            // agent summary here pushed the lock-screen card past its system bounds.
            if hasAgentMetadata(state), !callPhase {
                agentSummaryRow(state)
            }


        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ActivityKit 在锁屏上已经提供系统级 Live Activity 容器。iOS 26 再给
        // 根内容叠加 glassEffect 会生成第二个采样层，真机上可能只显示空玻璃壳。
        // 透明 activityBackgroundTint 负责启用宿主 Liquid Glass，正文保持普通布局。
    }

    private func usesAgentList(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        switch state.phase {
        case .standby, .cloudStandby, .offline: return true
        case .incoming, .active, .held: return false
        }
    }

    private var agentListBrandMark: some View {
        Text("AirSIM")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
    }

    private func agentListCount(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        let count = agentCount(state)
        let pages = LiveActivityAgentPaging.pageCount(for: count)
        let page = LiveActivityAgentPaging.pageIndex(state.agentPage, for: count)
        return HStack(spacing: 4) {
            if #available(iOS 17.0, *), pages > 1 {
                Button(intent: SwitchAirSIMAgentIntent()) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到下一页 Android Agent")
            }
            Text(pages > 1
                ? "第 \(page + 1)/\(pages) 页 · 共 \(count) 台"
                : "共 \(count) 台")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
        }
    }

    private func agentListFooter(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        let count = agentCount(state)
        let pages = LiveActivityAgentPaging.pageCount(for: count)
        if pages > 1 {
            let page = LiveActivityAgentPaging.pageIndex(state.agentPage, for: count)
            return "第 \(page + 1)/\(pages) 页 · 右上角翻页"
        }
        return count > 1 ? "轻点设备，切换下一通拨号" : "Android Agent 列表"
    }

    private func agentListCenter(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        let current = state.agents?.first(where: \.isCurrent)
            ?? displayAgents(state).first(where: \.isCurrent)
            ?? displayAgents(state).first
        return Text(current?.name ?? "Android Agent")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func agentCount(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Int {
        max(displayAgents(state).count,
            state.pairedAgentCount ?? 0,
            state.agents?.count ?? 0)
    }

    private func displayAgents(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> [AirSIMCallActivityAttributes.ContentState.AgentSummary] {
        if let values = state.agents, !values.isEmpty {
            // AppModel 已按“置顶固定 + 用户排序”排好序；每页最多 3 台。
            return LiveActivityAgentPaging.slice(values, requestedPage: state.agentPage)
        }
        guard let name = nonEmpty(state.agentDeviceName) else {
            return [.init(
                id: "current",
                name: "Android Agent",
                phoneNumber: nil,
                agentKind: state.agentKind,
                vowlanOnline: state.vowlanOnline == true,
                bluetoothOnline: state.bluetoothOnline == true,
                cloudOnline: state.cloudOnline == true,
                isCurrent: true
            )]
        }
        return [.init(
            id: "current",
            name: name,
            phoneNumber: state.agentPhoneNumber,
            agentKind: state.agentKind,
            vowlanOnline: state.vowlanOnline == true,
            bluetoothOnline: state.bluetoothOnline == true,
            cloudOnline: state.cloudOnline == true,
            isCurrent: true
        )]
    }

    private func agentListLockScreen(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        let agents = displayAgents(state)
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                agentListBrandMark
                Spacer(minLength: 4)
                agentListCount(state)
            }
            VStack(spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.offset) { index, agent in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, 42)
                    }
                    agentRow(agent, compact: false)
                }
            }
            Text(agentListFooter(state))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.18))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.20), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
        }
    }

    private func expandedAgentList(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        let agents = displayAgents(state)
        return VStack(spacing: 1) {
            ForEach(Array(agents.enumerated()), id: \.offset) { index, agent in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 0.5)
                        .padding(.leading, 34)
                }
                agentRow(agent, compact: true)
            }
            Text(agentListFooter(state))
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func agentRow(
        _ agent: AirSIMCallActivityAttributes.ContentState.AgentSummary,
        compact: Bool
    ) -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: SelectAirSIMAgentIntent(agentID: agent.id)) {
                agentRowContent(agent, compact: compact)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(agent.name)，\(agent.isCurrent ? "当前设备" : "切换到此设备")")
        } else {
            agentRowContent(agent, compact: compact)
        }
    }

    private func agentRowContent(
        _ agent: AirSIMCallActivityAttributes.ContentState.AgentSummary,
        compact: Bool
    ) -> some View {
        let color = agent.isCurrent ? Color.green : transportColor(agent.transport)
        return HStack(spacing: compact ? 6 : 8) {
            Image(systemName: "iphone")
                .font(.system(size: compact ? 11 : 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(agent.name)
                        .font(.system(size: compact ? 11 : 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .layoutPriority(1)
                    if agent.isCurrent {
                        Text("当前")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.16), in: Capsule())
                            .fixedSize()
                    }
                }
                Text("SIM · \(displayAgentNumber(agent.phoneNumber))")
                    .font(.system(size: compact ? 8.5 : 9.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            agentTransportPill(agent, compact: compact)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background {
            if agent.isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            }
        }
        .overlay {
            if agent.isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.22), lineWidth: 0.7)
            }
        }
        .contentShape(Rectangle())
    }

    private func agentTransportPill(
        _ agent: AirSIMCallActivityAttributes.ContentState.AgentSummary,
        compact: Bool
    ) -> some View {
        let transport = agent.transport
        let color = transportColor(transport)
        let title = transport?.title ?? "离线"
        let symbol = transport?.systemImage ?? "wifi.slash"
        return HStack(spacing: compact ? 3 : 4) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(title)
                .font(.system(size: compact ? 8.5 : 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(color.opacity(transferBackgroundOpacity(transport)), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
    }

    private func transferBackgroundOpacity(
        _ transport: AirSIMCallActivityAttributes.ContentState.Transport?
    ) -> Double {
        transport == .cloud || transport == nil ? 0.10 : 0.15
    }

    private func transportColor(
        _ transport: AirSIMCallActivityAttributes.ContentState.Transport?
    ) -> Color {
        switch transport {
        case .vowlan: return .green
        case .bluetooth: return Color(red: 0.30, green: 0.66, blue: 1.0)
        case .cloud: return .white.opacity(0.70)
        case nil: return .white.opacity(0.45)
        }
    }

    private func displayAgentNumber(_ raw: String?) -> String {
        LiveActivityNumberFormatter.display(raw)
    }

    @ViewBuilder
    private func lockScreenMetric(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .standby {
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
            expandedAgentDetail(state)
        case .cloudStandby:
            expandedAgentDetail(state)
        case .offline:
            expandedAgentDetail(state)
        case .incoming, .active, .held:
            EmptyView()
        }
    }

    /// 展开态的设备名和连接状态已在顶部呈现；底部只保留一行补充信息，
    /// 避免在系统限制的灵动岛高度里重复卡片并裁掉最后一行。
    private func expandedAgentDetail(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 6) {
            if let number = nonEmpty(state.agentPhoneNumber) {
                Text("SIM \(number)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if state.phase == .offline {
                Label("等待 Android Agent 恢复", systemImage: "wifi.exclamationmark")
                    .lineLimit(1)
            } else {
                Text(standbyNetworkLine(state))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(agentKindTitle(state.agentKind))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .modifier(ProgressiveIslandGlassSurface())
    }

    @ViewBuilder
    private func agentSwitchControl(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if #available(iOS 17.0, *), (state.pairedAgentCount ?? 0) > 1 {
            Button(intent: SwitchAirSIMAgentIntent()) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint(for: state.phase))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换 Android Agent，共 \(state.pairedAgentCount ?? 0) 台")
        } else {
            pairedAgentCountView(state)
        }
    }

    private func pairedAgentCountView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        Group {
            if let count = state.pairedAgentCount, count > 1 {
                Text("\(count) 台")
            } else {
                Image(systemName: state.phase == .cloudStandby ? "icloud.fill" : "smartphone")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint(for: state.phase))
    }

    private func agentSummaryRow(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "smartphone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 26, height: 26)
                .background(Color.green.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(nonEmpty(state.agentDeviceName) ?? "Android Agent")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                    if let count = state.pairedAgentCount, count > 1 {
                        Text("共 \(count) 台")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.52))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 6)
                    if #available(iOS 17.0, *), (state.pairedAgentCount ?? 0) > 1 {
                        Button(intent: SwitchAirSIMAgentIntent()) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("切换")
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("切换 Android Agent，共 \(state.pairedAgentCount ?? 0) 台")
                    }
                }
                Text(agentDetailLine(state))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func compactTrailingView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .active, .incoming, .held:
            EmptyView()
        case .standby:
            Image(systemName: "cellularbars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        case .cloudStandby:
            Image(systemName: "checkmark.icloud.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
        case .offline:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private func hasAgentMetadata(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        nonEmpty(state.agentDeviceName) != nil
            || nonEmpty(state.agentPhoneNumber) != nil
            || (state.pairedAgentCount ?? 0) > 0
    }

    private func agentDetailLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        var parts: [String] = []
        if let number = nonEmpty(state.agentPhoneNumber) {
            parts.append("SIM \(number)")
        }
        parts.append(agentKindTitle(state.agentKind))
        return parts.joined(separator: " · ")
    }

    private func agentKindTitle(_ kind: String?) -> String {
        switch kind {
        case "standalone": return "Standalone"
        case "avf": return "AVF Agent"
        default: return "Android Agent"
        }
    }

    private func vowlanIsOnline(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        state.vowlanOnline == true || state.transport == .vowlan
    }

    private func cloudIsOnline(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        state.cloudOnline == true || state.transport == .cloud
    }

    private func bluetoothIsOnline(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        state.bluetoothOnline == true || state.transport == .bluetooth
    }

    private func connectionStatusLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String? {
        var values: [String] = []
        if vowlanIsOnline(state) { values.append("VoWLAN 在线") }
        if bluetoothIsOnline(state) { values.append("VoBLE 在线") }
        if cloudIsOnline(state) { values.append("云端在线") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
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
            return nonEmpty(state.agentDeviceName) ?? standbyCarrierName(state)
        case .cloudStandby:
            return nonEmpty(state.agentDeviceName) ?? "云端在线"
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
        if state.transport == .vowlan || state.transport == .bluetooth,
           state.phase != .offline,
           state.phase != .cloudStandby {
            return state.transport?.systemImage ?? "wifi"
        }
        return symbolName(for: state.phase)
    }

    private func activityStatusLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        switch state.phase {
        case .incoming, .active, .held:
            guard let transport = state.transport else { return state.phase.title }
            return "\(state.phase.title) · \(transport.title)"
        case .standby:
            if let status = connectionStatusLine(state) { return status }
            if let transport = state.transport { return "\(transport.title) 在线" }
            return state.phase.title
        case .cloudStandby:
            return connectionStatusLine(state) ?? state.phase.title
        case .offline:
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
                content.buttonStyle(.glassProminent).tint(tint).buttonBorderShape(.circle)
            } else {
                content.buttonStyle(.glass).tint(tint).buttonBorderShape(.circle)
            }
        } else {
            content.buttonStyle(.borderedProminent).tint(tint)
        }
    }
}

/// 灵动岛外壳由系统绘制且不透明；渐变只作用于岛内的原生玻璃信息条。
private struct ProgressiveIslandGlassSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 26.0, *) {
            content.background {
                Color.clear
                    .glassEffect(.regular.tint(.white.opacity(0.12)),
                                 in: .rect(cornerRadius: 14))
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.45), location: 0.42),
                                .init(color: .white, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
        } else {
            content
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
