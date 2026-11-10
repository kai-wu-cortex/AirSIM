import SwiftUI
import WidgetKit
import AppIntents

/// Shared with the host solely so tests render the exact extension views.
struct AirSIMDeviceWidgetView: View {
    let snapshot: AirSIMWidgetSnapshot
    let date: Date
    let family: WidgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.colorScheme) private var colorScheme
    private var device: AirSIMWidgetSnapshot.Device? { snapshot.devices.first }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.42, green: 0.70, blue: 1) : Color(red: 0, green: 0.32, blue: 0.78) }
    private var secondaryText: Color { colorScheme == .dark ? Color(red: 0.67, green: 0.71, blue: 0.78) : Color(red: 0.35, green: 0.40, blue: 0.47) }
    private var primaryText: Color { colorScheme == .dark ? Color(red: 0.95, green: 0.96, blue: 0.98) : Color(red: 0.06, green: 0.11, blue: 0.20) }
    private var hasSwitchControls: Bool {
        snapshot.controls.map { $0.nextAgentID != nil || $0.mode != $0.nextMode } ?? false
    }
    private var accessory: Bool { [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) }

    var body: some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(AirSIMWidgetDestination.status.url(agentID: device?.id))
            .privacySensitive()
    }

    @ViewBuilder private var content: some View {
        if accessory { lockScreen }
        else if let device {
            if textSize.isAccessibilitySize { accessible(device) } else {
            switch family {
            case .systemSmall: small(device)
            case .systemMedium: medium(device)
            case .systemExtraLarge: extraLarge
            default: large(device)
            }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                brand(size: 36)
                Text("连接你的安卓手机").font(.headline)
                Text("打开 AirSIM 完成配对").font(.caption).foregroundStyle(secondaryText)
                if family != .systemSmall {
                    Link(destination: AirSIMWidgetDestination.status.url()) {
                        Label("打开 AirSIM", systemImage: "arrow.up.forward")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }.widgetAccentable()
                }
            }
        }
    }

    @ViewBuilder private func accessible(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.caption2.bold()).lineLimit(1)
                Text(d.status(at: date)).font(.caption2).lineLimit(1).minimumScaleFactor(0.6)
                if let observed = d.observedAt {
                    Text(observed, style: .time).font(.caption2).foregroundStyle(secondaryText)
                        .accessibilityLabel("最近更新时间 \(observed.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        } else if family == .systemMedium {
            HStack(spacing: 12) {
                accessibleIdentity(d).frame(maxWidth: .infinity, alignment: .leading)
                if hasSwitchControls { switchControls(vertical: true, compact: true).frame(maxWidth: .infinity) }
                else { VStack(spacing: 8) {
                    action("通话", symbol: nil, to: .recents, agent: d.id)
                    action("短信", symbol: nil, to: .messages, agent: d.id)
                }.frame(maxWidth: .infinity) }
            }
        } else if family == .systemExtraLarge {
            HStack(alignment: .top, spacing: 24) {
                ForEach(Array(snapshot.devices.prefix(2))) { item in
                    accessibleDetails(item).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else { accessibleDetails(d) }
    }
    private func accessibleIdentity(_ d: AirSIMWidgetSnapshot.Device, showTimestamp: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(d.name).font(.caption2.bold()).lineLimit(1)
            Text(d.status(at: date)).font(.caption2).foregroundStyle(secondaryText).lineLimit(1).minimumScaleFactor(0.6)
            if showTimestamp, let observed = d.observedAt {
                Text(observed, style: .time).font(.caption2).foregroundStyle(secondaryText)
            }
        }
    }
    private func accessibleDetails(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            accessibleIdentity(d, showTimestamp: true)
            if let controls = snapshot.controls,
               family != .systemExtraLarge || d.id == controls.currentAgentID {
                switchControls(vertical: false, compact: true)
            }
            Divider()
            recentDetails(d)
            Spacer(minLength: 0)
        }
    }

    private func small(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { brand(size: 24); Spacer(); battery(d).font(.caption2) }
            Text(d.name).font(.headline).lineLimit(1)
            status(d)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                action("拨号", symbol: "phone.fill", to: .dial, agent: d.id, primary: true)
                action("短信", symbol: "message.fill", to: .messages, agent: d.id)
            }
            updated(d).font(.system(size: 9))
        }
    }

    private func medium(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                brand(size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(d.status(at: date)).font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                statusDot(d)
                battery(d)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text("最近通话").font(.caption2); Spacer(minLength: 0); attentionBadge(d.unseenMissedCalls ?? 0, missed: true) }
                    if let call = snapshot.latestCall(for: d.id) {
                        Link(destination: AirSIMWidgetDestination.recents.url(agentID: d.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(call.displayNumber).font(.caption.weight(.medium)).lineLimit(1)
                                    .foregroundStyle(call.missed ? Color.red : primaryText)
                                Text(call.missed ? "\(call.detailText) · 未接" : call.detailText)
                                    .font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
                            }
                        }
                    } else { Text("暂无记录").font(.caption2).foregroundStyle(secondaryText) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text("最近短信").font(.caption2); Spacer(minLength: 0); attentionBadge(d.unreadMessages ?? 0, missed: false) }
                    if let message = snapshot.latestMessage(for: d.id) {
                        Link(destination: AirSIMWidgetDestination.messages.url(agentID: d.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(message.sender ?? "短信") · \(message.simSlot ?? "SIM 未记录")")
                                    .font(.caption).foregroundStyle(primaryText).lineLimit(1)
                                Text(message.displayText).font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
                            }
                        }
                    } else { Text("暂无记录").font(.caption2).foregroundStyle(secondaryText) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            widgetFooter(d)
        }
    }

    private func recentSummary(_ title: String, symbol: String, text: String?, timestamp: Date?,
                               to destination: AirSIMWidgetDestination, agent: String, count: Int = 0, detail: String? = nil) -> some View {
        Link(destination: destination.url(agentID: agent)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Label(title, systemImage: symbol).font(.caption.weight(.semibold))
                        .foregroundStyle(title == "未接来电" ? Color.red : accent).lineLimit(1)
                    Spacer(minLength: 0)
                    attentionBadge(count, missed: destination == .recents)
                }
                Text(text ?? "暂无记录").font(.caption2).foregroundStyle(primaryText).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(secondaryText).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(title)，\(count) 条\(destination == .recents ? "未查看的未接来电" : "未读短信")，\(text ?? "暂无记录")\(timestamp.map { "，" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")，打开记录")
    }

    private func large(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            widgetHeader(d)
            Divider()
            callSection(d, limit: 2)
            Divider()
            messageSection(d)
            Spacer(minLength: 0)
            widgetFooter(d)
        }
    }
    private func widgetHeader(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        HStack(spacing: 10) {
            brand(size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.headline).lineLimit(1)
                status(d)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                battery(d)
                Text(callStateText(d)).font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
            }
        }
    }
    private func callStateText(_ d: AirSIMWidgetSnapshot.Device) -> String {
        guard d.isFresh(at: date), d.refreshFailed != true else { return "通话状态待同步" }
        switch d.activeState {
        case "active": return "正在通话"
        case "dialing", "alerting", "connecting": return "正在呼叫"
        case "incoming", "waiting": return "有来电"
        case "idle", "ended", "failed": return "当前无通话"
        default: return "VoWLAN 直连"
        }
    }
    private func callSection(_ d: AirSIMWidgetSnapshot.Device, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("最近通话").font(.caption.weight(.semibold))
                Spacer()
                attentionBadge(d.unseenMissedCalls ?? 0, missed: true)
            }
            let records = snapshot.calls.filter { $0.agentID == d.id }.prefix(limit)
            if records.isEmpty { Text("暂无通话记录").font(.caption).foregroundStyle(secondaryText) }
            ForEach(Array(records)) { call in
                Link(destination: AirSIMWidgetDestination.recents.url(agentID: d.id)) {
                    HStack(spacing: 9) {
                        Image(systemName: call.missed ? "phone.down.fill" : call.incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill")
                            .foregroundStyle(call.missed ? Color.red : accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.displayNumber).font(.subheadline.weight(.medium)).lineLimit(1)
                                .foregroundStyle(call.missed ? Color.red : primaryText)
                            Text(call.missed ? "\(call.detailText) · 未接来电" : "\(call.detailText) · \(call.incoming ? "呼入" : "呼出")")
                                .font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(recordTime(call.date)).font(.caption2).foregroundStyle(secondaryText)
                    }.contentShape(Rectangle())
                }.accessibilityElement(children: .combine)
            }
        }
    }
    private func messageSection(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("最近短信").font(.caption.weight(.semibold))
                Spacer()
                attentionBadge(d.unreadMessages ?? 0, missed: false)
            }
            Link(destination: AirSIMWidgetDestination.messages.url(agentID: d.id)) {
                if let message = snapshot.latestMessage(for: d.id) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "message.fill").foregroundStyle(accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(message.sender ?? "短信") · \(message.simSlot ?? "SIM 未记录")")
                                .font(.caption.weight(.medium)).foregroundStyle(primaryText).lineLimit(1)
                            Text(message.displayText).font(.caption).foregroundStyle(secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(recordTime(message.date)).font(.caption2).foregroundStyle(secondaryText)
                    }.contentShape(Rectangle())
                } else {
                    Text("暂无短信记录").font(.caption).foregroundStyle(secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.accessibilityElement(children: .combine)
        }
    }
    private func recordTime(_ value: Date) -> String {
        Calendar.current.isDate(value, inSameDayAs: date)
            ? value.formatted(date: .omitted, time: .shortened)
            : value.formatted(.dateTime.month().day())
    }
    private func widgetFooter(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        HStack(spacing: 6) {
            updated(d).font(.caption2)
            Spacer(minLength: 0)
            if #available(iOS 17.0, *) {
                Button(intent: AirSIMWidgetRefreshIntent()) {
                    Label("刷新", systemImage: "arrow.clockwise").font(.caption)
                        .frame(minHeight: 32).contentShape(Rectangle())
                }.foregroundStyle(accent).accessibilityLabel("刷新安卓状态与最近记录")
            }
        }
    }

    private func recentDetails(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        let call = snapshot.latestCall(for: d.id)
        let message = snapshot.latestMessage(for: d.id)
        return HStack(alignment: .top, spacing: 12) {
            recordDetail("最近通话", symbol: "phone.fill", to: .recents, agent: d.id, count: d.unseenMissedCalls ?? 0) {
                if let call {
                    Text(call.displayNumber)
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    if !textSize.isAccessibilitySize {
                        Text(call.missed ? "未接来电" : call.incoming ? "呼入" : "呼出")
                            .font(.caption2).foregroundStyle(call.missed ? Color.red : secondaryText)
                        Text(call.detailText).font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
                        recordDate(call.date)
                    }
                } else {
                    Text("暂无通话记录").font(.caption).foregroundStyle(secondaryText)
                }
            }
            Divider()
            recordDetail("最近短信", symbol: "message.fill", to: .messages, agent: d.id, count: d.unreadMessages ?? 0) {
                if let message {
                    Text(message.displayText).font(.subheadline)
                        .lineLimit(textSize.isAccessibilitySize ? 2 : 3)
                    if !textSize.isAccessibilitySize {
                        Text(message.incoming ? "收到" : "发出")
                            .font(.caption2).foregroundStyle(secondaryText)
                        recordDate(message.date)
                    }
                } else {
                    Text("暂无短信记录").font(.caption).foregroundStyle(secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func recordDetail<Content: View>(_ title: String, symbol: String,
                                             to destination: AirSIMWidgetDestination, agent: String, count: Int,
                                             @ViewBuilder content: () -> Content) -> some View {
        Link(destination: destination.url(agentID: agent)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 3) {
                    Label(title, systemImage: symbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(title == "未接来电" ? Color.red : accent).lineLimit(1)
                    Spacer(minLength: 0)
                    attentionBadge(count, missed: destination == .recents)
                }
                content()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开\(title)记录")
    }

    private func recordDate(_ value: Date) -> some View {
        Text(value.formatted(.dateTime.month().day().hour().minute()))
            .font(.caption2).foregroundStyle(secondaryText).lineLimit(2)
    }

    @ViewBuilder private func attentionBadge(_ count: Int, missed: Bool) -> some View {
        if let text = AirSIMWidgetSnapshot.badgeText(count) {
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.red, in: Capsule()).fixedSize()
                .accessibilityLabel("\(count) 条\(missed ? "未查看的未接来电" : "未读短信")")
        }
    }

    private var extraLarge: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(snapshot.devices.prefix(2).enumerated()), id: \.element.id) { index, d in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            brand(size: 42)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(d.name).font(.headline).lineLimit(1)
                                status(d)
                            }
                        }
                        HStack { battery(d); Spacer(); updated(d).font(.caption2) }
                        actions(d, compact: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if snapshot.devices.count == 1 { Spacer(minLength: 0) }
            }
            Divider()
            if hasSwitchControls { switchControls(vertical: false) }
            recentHeader
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(snapshot.devices.prefix(2).enumerated()), id: \.element.id) { index, d in
                    if index > 0 { Divider() }
                    history(agent: d.id, limit: hasSwitchControls || textSize.isAccessibilitySize ? 1 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func switchControls(vertical: Bool, compact: Bool = false) -> some View {
        if let controls = snapshot.controls {
            let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                  : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                if controls.nextAgentID != nil { switchControl(action: "device", title: "设备",
                    value: snapshot.devices.first(where: { $0.id == controls.currentAgentID })?.name ?? "未选择",
                    expected: controls.currentAgentID, target: controls.nextAgentID ?? "",
                    hint: controls.nextAgentName.map { "切换到 \($0)" } ?? "仅有一台配对设备",
                    disabled: controls.blockedByCall || controls.nextAgentID == nil, compact: compact) }
                if controls.mode != controls.nextMode { switchControl(action: "mode", title: "模式", value: controls.modeTitle,
                    expected: controls.mode, target: controls.nextMode,
                    hint: "切换为 \(controls.nextModeTitle)", disabled: controls.blockedByCall, compact: compact) }
            }
        }
    }

    @ViewBuilder private func switchControl(action: String, title: String, value: String,
                                            expected: String, target: String, hint: String,
                                            disabled: Bool, compact: Bool) -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: AirSIMWidgetSwitchIntent(action: action, expected: expected, target: target)) {
                controlLabel(title: title, value: value, compact: compact)
            }
            .disabled(disabled).opacity(disabled ? 0.55 : 1)
            .accessibilityLabel("\(title)：\(value)")
            .accessibilityHint(snapshot.controls?.blockedByCall == true ? "通话中不能切换" : hint + "，后台执行")
        } else {
            controlLabel(title: title, value: value, compact: compact)
                .opacity(0.55)
                .accessibilityLabel("\(title)：\(value)，后台切换需要 iOS 17 或更新版本")
        }
    }

    private func controlLabel(title: String, value: String, compact: Bool) -> some View {
        HStack(spacing: 4) {
            if compact {
                Text(title).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.6)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption2).foregroundStyle(secondaryText)
                    Text(value).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var lockScreen: some View {
        switch family {
        case .accessoryInline:
            Label(device.map { "\($0.name) · \($0.status(at: date))" } ?? "AirSIM · 打开 App 配对", systemImage: "phone.fill")
        case .accessoryCircular:
            VStack(spacing: 2) {
                Image(systemName: "phone.fill").font(.title3)
                Text(device?.name ?? "AirSIM").font(.caption2.bold()).lineLimit(1)
                Text(device.map { $0.isFresh(at: date) ? "最近更新" : "待刷新" } ?? "待配对").font(.caption2).lineLimit(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            HStack(spacing: 8) {
                Image(systemName: "phone.fill").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device?.name ?? "AirSIM").font(.headline).lineLimit(1)
                    if let d = device { updated(d).font(.caption); Text(d.status(at: date)).font(.caption) }
                    else { Text("打开 App 配对").font(.caption) }
                }
            }.frame(maxHeight: .infinity)
        }
    }

    private func brand(size: CGFloat) -> some View {
        Image(systemName: "phone.fill")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            // Inherit WidgetKit's corner geometry rather than assuming a
            // radius that only fits one Home Screen size or display.
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.28))

            .accessibilityHidden(true)
    }
    private func statusDot(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        Circle().fill(d.isFresh(at: date) && d.recentlyReachable && d.refreshFailed != true ? Color.green : Color.secondary)
            .frame(width: 8, height: 8).accessibilityHidden(true)
    }
    private func status(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        HStack(spacing: 5) {
            statusDot(d)
            Text(d.isFresh(at: date) && d.recentlyReachable && d.refreshFailed != true && !d.transport.isEmpty
                 ? "\(d.status(at: date)) · \(d.transport)" : d.status(at: date))
                .lineLimit(2)
        }.font(.caption).foregroundStyle(secondaryText)
    }
    private func updated(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let attempt = d.lastRefreshAttempt {
                Text("\(d.refreshInProgress(at: date) ? "正在刷新" : d.refreshPending == true ? "刷新中断" : d.refreshFailed == true ? "刷新失败" : "刷新成功") · 尝试 \(attempt.formatted(.dateTime.hour().minute().second()))")
            }
            if let observed = d.observedAt {
                Text("最近成功 \(observed.formatted(.dateTime.month().day().hour().minute().second()))")
            } else { Text("尚无成功记录") }
            if let reason = d.refreshFailureReason, !d.refreshInProgress(at: date) { Text(reason) }
        }.foregroundStyle(secondaryText).lineLimit(1).minimumScaleFactor(0.8)
    }
    private func battery(_ d: AirSIMWidgetSnapshot.Device) -> some View {
        let reading = d.battery.flatMap { $0.isFresh(at: date) ? $0 : nil }
        return HStack(spacing: 5) {
            Image(systemName: reading?.symbol ?? "battery.0percent")
                .foregroundStyle(reading.map { $0.charging ? Color.green : $0.percent <= 20 ? Color.red : primaryText } ?? secondaryText)
            Text(reading.map { "\($0.percent)%" } ?? "—")
        }
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel(reading.map { "安卓电量 \($0.percent)%，\($0.charging ? "正在充电" : "未充电")，采样于 \($0.observedAt.formatted(date: .omitted, time: .shortened))" } ?? "安卓电量待刷新")
    }
    private func transportSymbol(_ d: AirSIMWidgetSnapshot.Device) -> String {
        d.transport == "云端" ? "cloud" : d.transport == "VoBLE" ? "antenna.radiowaves.left.and.right" : "wifi"
    }
    private func action(_ title: String, symbol: String?, to destination: AirSIMWidgetDestination,
                        agent: String? = nil, primary: Bool = false) -> some View {
        Link(destination: destination.url(agentID: agent)) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(primary && renderingMode == .fullColor ? (colorScheme == .dark ? Color.black : Color.white) : accent)
            .background(primary ? accent : accent.opacity(0.09), in: ContainerRelativeShape())
            .contentShape(ContainerRelativeShape())
        }.widgetAccentable()
    }
    private func actions(_ d: AirSIMWidgetSnapshot.Device, compact: Bool) -> some View {
        HStack(spacing: 8) {
            action(compact ? "拨号" : "打开拨号", symbol: "phone.fill", to: .dial, agent: d.id)
            action(compact ? "短信" : "查看短信", symbol: "message.fill", to: .messages, agent: d.id)
            if compact && !textSize.isAccessibilitySize { action("联系人", symbol: "person.fill", to: .contacts, agent: d.id) }
        }
    }
    private var recentHeader: some View {
        Link(destination: AirSIMWidgetDestination.recents.url()) {
            HStack {
                Text("最近通话").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(secondaryText)
            }.foregroundStyle(.primary)
        }
    }
    @ViewBuilder private func history(agent: String?, limit: Int) -> some View {
        let calls = snapshot.calls.filter { agent == nil || $0.agentID == agent }
        if calls.isEmpty {
            Text("暂无通话记录").font(.subheadline).foregroundStyle(secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(calls.prefix(limit))) { call in
                    Link(destination: AirSIMWidgetDestination.recents.url(agentID: call.agentID)) {
                        HStack(spacing: 9) {
                            Image(systemName: call.missed ? "phone.down.fill" : "phone.fill")
                                .font(.subheadline).foregroundStyle(call.missed ? Color.red : Color.secondary)
                                .frame(width: 30, height: 30)
                                .background(Color.secondary.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(call.displayNumber).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(call.date.formatted(.dateTime.month().day().hour().minute())) · \(call.missed ? "未接来电" : call.incoming ? "呼入" : "呼出")")
                                    .font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

@available(iOS 17.0, *)
struct AirSIMWidgetRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新 AirSIM 小组件"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        _ = await WidgetDirectRefresh.snapshot(showProgress: true)
        WidgetCenter.shared.reloadTimelines(ofKind: AirSIMWidgetSnapshot.kind)
        return .result()
    }
}
