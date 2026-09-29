import SwiftUI
import UIKit

enum RecentCallTimeFormatter {
    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let currentDay = calendar.dateComponents([.year, .month, .day], from: now)
        if day == currentDay {
            let time = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == calendar.dateComponents([.year, .month, .day], from: yesterday) {
            return "昨天"
        }
        if day.year == currentDay.year {
            return String(format: "%02d/%02d", day.month ?? 0, day.day ?? 0)
        }
        return String(format: "%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}

enum DialPadDeletePolicy {
    static func removingLast(from number: String) -> String {
        String(number.dropLast())
    }
}

struct DialPadTransportPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let transport: CallTransport

    static func make(
        vowlanOnline: Bool,
        moduleLocalReachable: Bool,
        cloudOnline: Bool
    ) -> DialPadTransportPresentation? {
        if vowlanOnline {
            return DialPadTransportPresentation(
                title: "VoWLAN",
                detail: "拨号及通话音频将通过同一 Wi-Fi 或三星热点",
                systemImage: "wifi",
                transport: .vowlan
            )
        }
        if moduleLocalReachable {
            return DialPadTransportPresentation(
                title: "模块本地",
                detail: "拨号及通话音频将通过模块本地链路",
                systemImage: "cable.connector",
                transport: .moduleLocal
            )
        }
        if cloudOnline {
            return DialPadTransportPresentation(
                title: "云端",
                detail: "拨号及通话音频将通过云端 Relay",
                systemImage: "cloud.fill",
                transport: .cloud
            )
        }
        return nil
    }
}

private enum PhoneListMetrics {
    static let rowHeight: CGFloat = 74
    static let avatarSize: CGFloat = 50
    static let horizontalInset: CGFloat = 16
    static let avatarSpacing: CGFloat = 11
    static let trailingSpacing: CGFloat = 8
    static let timeColumnWidth: CGFloat = 76
    static let actionSize: CGFloat = 44
    static let separatorLeading: CGFloat = horizontalInset + avatarSize + avatarSpacing
}

// MARK: - 拨号

struct DialPadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var deleteRepeatTask: Task<Void, Never>?
    @State private var zeroWasLongPressed = false
    @State private var showingModuleStatus = false
    @State private var moduleStatusFeedback = UIImpactFeedbackGenerator(style: .medium)
    @State private var moduleStatusDotPressed = false
    @State private var moduleStatusLongPressTriggered = false
    @State private var dialKeyFeedback = DialKeyFeedback()

    private let rows = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    private var matchedName: String? {
        model.contacts.contact(for: model.numberInput)?.name
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var keySize: CGFloat { isCompact ? 84 : 90 }
    private var keySpacing: CGFloat { isCompact ? 28 : 34 }
    private var rowSpacing: CGFloat { isCompact ? 12 : 16 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: isCompact ? 16 : 22) {
                    VStack(spacing: 2) {
                        Text(model.numberInput.isEmpty ? L10n.t("输入号码") : model.numberInput)
                            .font(.system(size: isCompact ? 36 : 42, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(model.numberInput.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .frame(height: 50)

                        Text(matchedName ?? " ")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                            .frame(height: 22)
                    }
                    .padding(.horizontal, 12)

                    if let route = model.dialPadTransportPresentation {
                        DialPadTransportBadge(route: route)
                    }

                    dialKeyGrid

                    HStack(spacing: keySpacing) {
                        Color.clear.frame(width: keySize, height: keySize)
                        Button {
                            Task { await model.dial() }
                        } label: {
                            Circle()
                                .fill(.green)
                                .frame(width: keySize, height: keySize)
                                .overlay {
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: isCompact ? 27 : 30, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            model.numberInput.isEmpty
                                || model.isBusy
                                || !model.canStartOutgoingCommand
                        )
                        .opacity(
                            model.numberInput.isEmpty || !model.canStartOutgoingCommand ? 0.4 : 1
                        )

                        Image(systemName: "delete.left")
                            .font(.system(size: isCompact ? 22 : 24))
                            .foregroundStyle(.secondary)
                            .frame(width: keySize, height: keySize)
                            .contentShape(Rectangle())
                            .gesture(deleteGesture)
                            .allowsHitTesting(!model.numberInput.isEmpty)
                            .opacity(model.numberInput.isEmpty ? 0.4 : 1)
                            .accessibilityLabel(L10n.t("删除"))
                            .accessibilityHint(L10n.t("轻点删除一位，长按连续删除"))
                            .accessibilityAddTraits(.isButton)
                    }
                    .frame(width: keypadWidth)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .phoneReportsTabBarCompactState()
            .background(PhoneBackdrop())
            .navigationTitle(L10n.t("拨号"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { dialStatusToolbar }
            .onDisappear(perform: stopRepeatingDelete)
        }
    }

    @ViewBuilder
    private var dialKeyGrid: some View {
        if #available(iOS 26.0, *) {
            // 融合距离必须明显小于按键的真实间距，否则 Liquid Glass 会把相邻圆键吸成一体。
            GlassEffectContainer(spacing: 6) {
                dialKeyRows
            }
        } else {
            dialKeyRows
        }
    }

    private var dialKeyRows: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: keySpacing) {
                    ForEach(row, id: \.0) { digit, letters in
                        DialKey(digit: digit, letters: letters)
                    }
                }
            }
        }
        .frame(width: keypadWidth)
    }

    private func deleteLastDigit() {
        guard !model.numberInput.isEmpty else { return }
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
    }

    private func playDialKeySound() {
        guard !model.isMuted else { return }
        dialKeyFeedback.play()
    }

    private func beginDeleting() {
        guard deleteRepeatTask == nil, !model.numberInput.isEmpty else { return }
        deleteLastDigit()
        deleteRepeatTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            while !Task.isCancelled, !model.numberInput.isEmpty {
                deleteLastDigit()
                try? await Task.sleep(for: .milliseconds(90))
            }
            deleteRepeatTask = nil
        }
    }

    private func stopRepeatingDelete() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    private var deleteGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in beginDeleting() }
            .onEnded { _ in stopRepeatingDelete() }
    }

    private func dismissModuleStatusPopover() {
        showingModuleStatus = false
    }

    @ToolbarContentBuilder
    private var dialStatusToolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { dialStatusDot }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { dialStatusDot }
        }
    }

    private var dialStatusDot: some View {
        Button {
            guard !moduleStatusLongPressTriggered else {
                moduleStatusLongPressTriggered = false
                return
            }
            toggleModuleStatus()
        } label: {
            ZStack {
                Circle()
                    .fill(moduleStatusTint)
                    .frame(width: 9, height: 9)
                    .shadow(color: moduleStatusTint.opacity(0.38), radius: 3)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(moduleStatusDotPressed ? 0.72 : 1)
        .animation(.easeOut(duration: 0.12), value: moduleStatusDotPressed)
        .simultaneousGesture(LongPressGesture(
            minimumDuration: 0.18,
            maximumDistance: 36,
        ).onChanged { _ in
            moduleStatusDotPressed = true
            moduleStatusFeedback.prepare()
        }.onEnded { _ in
            moduleStatusDotPressed = false
            moduleStatusLongPressTriggered = true
            presentModuleStatus()
        })
        .onChange(of: showingModuleStatus) { isShowing in
            if !isShowing {
                moduleStatusLongPressTriggered = false
            }
        }
        .popover(isPresented: $showingModuleStatus, arrowEdge: .top) {
            moduleStatusDetails
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(moduleStatusTitle)
        .accessibilityHint("轻点或按住查看模块状态")
    }

    private func toggleModuleStatus() {
        if showingModuleStatus {
            dismissModuleStatusPopover()
        } else {
            presentModuleStatus()
        }
    }

    private func presentModuleStatus() {
        guard !showingModuleStatus else { return }
        moduleStatusFeedback.impactOccurred()
        moduleStatusFeedback.prepare()
        showingModuleStatus = true
    }

    @ViewBuilder
    private var moduleStatusDetails: some View {
        if #available(iOS 16.4, *) {
            ModuleStatusPopover(onDismiss: dismissModuleStatusPopover)
                .environmentObject(model)
                .presentationCompactAdaptation(.popover)
        } else {
            ModuleStatusPopover(onDismiss: dismissModuleStatusPopover)
                .environmentObject(model)
        }
    }

    private var moduleStatusTitle: String {
        if model.vowlan.availability.isOnlineForDisplay { return "VoWLAN 在线" }
        return CloudModePreference.isEnabled() && model.cloudAgentStatus?.cloudOnline == true
            ? "云端在线" : "AirSIM 未连接"
    }

    private var moduleStatusTint: Color {
        if model.vowlan.availability.isOnlineForDisplay { return .green }
        return CloudModePreference.isEnabled() && model.cloudAgentStatus?.cloudOnline == true
            ? .blue : .red
    }

    @ViewBuilder
    private func DialKey(digit: String, letters: String) -> some View {
        Button {
            guard !(digit == "0" && zeroWasLongPressed) else {
                zeroWasLongPressed = false
                return
            }
            model.numberInput.append(digit)
            playDialKeySound()
        } label: {
            VStack(spacing: 0) {
                Text(digit).font(.system(size: isCompact ? 28 : 31, weight: .regular, design: .rounded))
                Text(letters).font(.system(size: isCompact ? 9 : 10, weight: .semibold)).tracking(1.4)
            }
            .foregroundStyle(.primary)
            .frame(width: keySize, height: keySize)
            .dialKeySurface()
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if digit == "0" {
                    zeroWasLongPressed = true
                    model.numberInput.append("+")
                    playDialKeySound()
                }
            }
        )
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
    }
}

private struct DialPadTransportBadge: View {
    let route: DialPadTransportPresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: route.systemImage)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(route.title)
                    .font(.subheadline.weight(.semibold))
                Text(route.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(route.transport == .cloud ? Color.blue : Color.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// 使用系统输入点击音，不启动新的音频会话，避免干扰 CallKit 路由。
private final class DialKeyFeedback {
    func play() {
        UIDevice.current.playInputClick()
    }
}

// MARK: - AirSIM 连接状态

private struct ModuleStatusPopover: View {
    @EnvironmentObject private var model: AppModel
    let onDismiss: () -> Void

    private var vowlanOnline: Bool { model.vowlan.availability.isOnlineForDisplay }
    private var cloudOnline: Bool {
        CloudModePreference.isEnabled() && model.cloudAgentStatus?.cloudOnline == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 40, height: 40)
                    .background(statusTint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(moduleStatusTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(connectionRouteTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                closeButton
            }

            Text(vowlanOnline ? "三星局域网控制与音频已就绪" : "请在设置中配对三星手机；如已启用云端，请检查 Relay 心跳。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusGroup("AirSIM") {
                statusRow("三星 VoWLAN", vowlanOnline ? "已连接" : "未连接")
                Divider()
                statusRow("云端 Relay", cloudOnline ? "在线" : "未连接")
            }
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26.0, *) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.glass)
            .frame(width: 44, height: 44)
            .accessibilityLabel(L10n.t("关闭"))
        } else {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .background(Color(uiColor: .secondarySystemFill), in: Circle())
            .accessibilityLabel(L10n.t("关闭"))
        }
    }

    private var moduleStatusTitle: String {
        vowlanOnline ? "VoWLAN 在线" : (cloudOnline ? "云端在线" : "AirSIM 未连接")
    }

    private var connectionRouteTitle: String {
        vowlanOnline ? "同一 Wi-Fi / 三星热点" : "独立 Relay"
    }

    private var statusTint: Color {
        vowlanOnline ? .green : (cloudOnline ? .blue : .red)
    }

    private var statusIcon: String {
        vowlanOnline ? "wifi" : (cloudOnline ? "cloud.fill" : "exclamationmark.triangle.fill")
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
        .frame(minHeight: 34)
    }

    private func statusGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - 最近通话

struct RecentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var selectedCall: CallRecord?
    @State private var suppressNextCallTap = false

    var body: some View {
        ZStack {
            NavigationStack {
                Group {
                    if model.callHistory.isEmpty {
                        EmptyStateView(
                            title: L10n.t("暂无通话记录"),
                            systemImage: "phone.arrow.up.right"
                        )
                    } else {
                        List(model.callHistory) { call in
                            let contact = call.number.flatMap { contacts.contact(for: $0) }
                            Button {
                                if suppressNextCallTap {
                                    suppressNextCallTap = false
                                    return
                                }
                                if let number = RecentCallDialPolicy.numberToDial(call.number) {
                                    onCall(number)
                                }
                            } label: {
                                CallHistoryRow(
                                    call: call,
                                    contact: contact,
                                    displayName: contact?.name ?? contacts.displayName(for: call.number)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(RecentCallDialPolicy.numberToDial(call.number) == nil)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.38).onEnded { _ in
                                    guard call.number?.isEmpty == false else { return }
                                    suppressNextCallTap = true
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                        selectedCall = call
                                    }
                                }
                            )
                            .accessibilityHint("轻点回拨，按住查看详情")
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(
                                top: 0,
                                leading: PhoneListMetrics.horizontalInset,
                                bottom: 0,
                                trailing: PhoneListMetrics.horizontalInset
                            ))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in
                                PhoneListMetrics.separatorLeading
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let number = call.number {
                                    Button { onMessage(number) } label: {
                                        Label(L10n.t("短信"), systemImage: "message.fill")
                                    }
                                    .tint(.blue)
                                    Button { onCall(number) } label: {
                                        Label(L10n.t("拨号"), systemImage: "phone.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
                        .phoneReportsTabBarCompactState()
                    }
                }
                .background(PhoneBackdrop())
                .navigationTitle(L10n.t("最近通话"))
            }
            .allowsHitTesting(selectedCall == nil)

            if let call = selectedCall,
               let number = RecentCallDialPolicy.numberToDial(call.number) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismissCallDetails)
                    .transition(.opacity)

                callDetailsCard(call: call, number: number)
                    .padding(.horizontal, 28)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedCall?.id)
    }

    private func callDetailsCard(call: CallRecord, number: String) -> some View {
        let contact = contacts.contact(for: number)
        let displayName = contact?.name ?? contacts.displayName(for: number)

        return VStack(spacing: 16) {
            InitialAvatar(
                name: displayName,
                photoData: contact?.photoData,
                fallbackContent: RecentAvatarPolicy.content(contactName: contact?.name),
                size: 58
            )

            VStack(spacing: 4) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                Text(number)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(RecentCallTimeFormatter.string(for: call.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                dismissCallDetails()
                onCall(number)
            } label: {
                Label(L10n.t("回拨"), systemImage: "phone.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)

            Button {
                dismissCallDetails()
                onMessage(number)
            } label: {
                Label(L10n.t("发短信"), systemImage: "message.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(L10n.t("取消"), action: dismissCallDetails)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minHeight: 34)
        }
        .padding(22)
        .frame(maxWidth: 340)
        .phoneGlassSurface(cornerRadius: 28)
        .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
    }

    private func dismissCallDetails() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedCall = nil
        }
    }

    private struct CallHistoryRow: View {
        let call: CallRecord
        let contact: ContactStore.Contact?
        let displayName: String

        var body: some View {
            HStack(spacing: PhoneListMetrics.avatarSpacing) {
                InitialAvatar(
                    name: displayName,
                    photoData: contact?.photoData,
                    fallbackContent: RecentAvatarPolicy.content(contactName: contact?.name),
                    size: PhoneListMetrics.avatarSize
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(call.missed ? .red : .primary)
                    HStack(spacing: 4) {
                        Image(systemName: call.direction == "incoming" ? "arrow.down.left" : "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                        Text(call.missed ? L10n.t("未接") : "AirSIM 音频")
                    }
                    .font(.subheadline)
                    .foregroundStyle(call.missed ? .red : .secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(RecentCallTimeFormatter.string(for: call.startedAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: PhoneListMetrics.timeColumnWidth, alignment: .trailing)

                Image(systemName: "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: PhoneListMetrics.actionSize, height: PhoneListMetrics.actionSize)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
            .frame(minHeight: PhoneListMetrics.rowHeight)
        }
    }
}

// MARK: - 短信

struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var pendingRecipient: String?
    @State private var showingComposer = false
    @State private var showingClearConfirmation = false

    private var conversations: [(sender: String, messages: [SMSMessage])] {
        Dictionary(grouping: model.messages, by: \.sender)
            .map { ($0.key, $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if conversations.isEmpty {
                    EmptyStateView(title: L10n.t("暂无短信"), systemImage: "message")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(conversations, id: \.sender) { conversation in
                        NavigationLink {
                            MessageThreadView(sender: conversation.sender)
                        } label: {
                            MessageConversationRow(sender: conversation.sender, messages: conversation.messages)
                                .contentShape(Rectangle())
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(
                            top: 0,
                            leading: PhoneListMetrics.horizontalInset,
                            bottom: 0,
                            trailing: PhoneListMetrics.horizontalInset
                        ))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in
                            PhoneListMetrics.separatorLeading
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
            .phoneReportsTabBarCompactState()
            .background(PhoneBackdrop())
            .navigationTitle(L10n.t("短信"))
            .toolbar {
                phoneMorphingToolbarItem(placement: .topBarLeading, id: "top-action-leading-more") {
                    Menu {
                        Button { Task { await model.refreshMessages() } } label: {
                            Label(L10n.t("刷新"), systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) { showingClearConfirmation = true } label: {
                            Label(L10n.t("清空全部短信"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("短信操作")
                }
                phoneMorphingToolbarItem(placement: .topBarTrailing, id: "top-action-trailing-primary") {
                    Button { showingComposer = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(L10n.t("新信息"))
                }
            }
            .task {
                await model.loadMessagesFromAgent(silently: true)
            }
            .onChange(of: pendingRecipient) { recipient in
                if recipient != nil { showingComposer = true }
            }
            .sheet(isPresented: $showingComposer, onDismiss: { pendingRecipient = nil }) {
                MessageComposer(initialRecipient: pendingRecipient ?? "")
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(L10n.t("清空全部短信"), isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                Button(L10n.t("删除"), role: .destructive) {
                    Task {
                        try? await model.api.clearModuleSMS()
                        model.clearLocalMessages()
                    }
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text("这会删除本机短信以及尚未交付的模块短信，无法恢复。")
            }
        }
    }

    private struct MessageConversationRow: View {
        @EnvironmentObject private var model: AppModel
        let sender: String
        let messages: [SMSMessage]

        private var contact: ContactStore.Contact? {
            model.contacts.contact(for: sender)
        }

        private var displayName: String {
            contact?.name ?? model.contacts.displayName(for: sender)
        }

        var body: some View {
            HStack(spacing: PhoneListMetrics.avatarSpacing) {
                InitialAvatar(
                    name: displayName,
                    photoData: contact?.photoData,
                    fallbackContent: contact == nil
                        ? .person
                        : RecentAvatarPolicy.content(contactName: contact?.name),
                    size: PhoneListMetrics.avatarSize
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(messages.last?.content ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(messages.last?.timestamp ?? .now, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: PhoneListMetrics.timeColumnWidth, alignment: .trailing)
            }
            .frame(minHeight: PhoneListMetrics.rowHeight)
        }
    }
}

private struct MessageThreadView: View {
    @EnvironmentObject private var model: AppModel
    let sender: String
    @State private var reply = ""

    private var messages: [SMSMessage] {
        model.messages
            .filter { $0.sender == sender }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(messages) { message in
                            HStack {
                                if message.isOutgoing { Spacer(minLength: 48) }
                                VStack(
                                    alignment: message.isOutgoing ? .trailing : .leading,
                                    spacing: 3
                                ) {
                                    Text(message.content)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(
                                            message.isOutgoing
                                                ? Color.blue
                                                : Color(uiColor: .secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 18)
                                        )
                                        .foregroundStyle(message.isOutgoing ? .white : .primary)
                                    if message.isOutgoing {
                                        Text(L10n.t("已发送"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !message.isOutgoing { Spacer(minLength: 48) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onAppear { if let id = messages.last?.id { proxy.scrollTo(id) } }
            }
            Divider()
            HStack(spacing: 10) {
                TextField(L10n.t("短信内容"), text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let body = reply
                    reply = ""
                    Task { _ = await model.sendSMS(to: sender, content: body) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(model.contacts.displayName(for: sender))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessageComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var recipient: String
    @State private var content = ""
    @State private var sending = false
    @State private var showingContacts = false

    init(initialRecipient: String) { _recipient = State(initialValue: initialRecipient) }

    private var matchedContact: ContactStore.Contact? {
        model.contacts.contact(for: recipient)
    }

    private var suggestions: [ContactStore.Contact] {
        let query = recipient.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, matchedContact == nil else { return [] }
        return Array(model.contacts.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains {
                    $0.localizedCaseInsensitiveContains(query) || $0.hasSuffix(query)
                }
        }.prefix(5))
    }

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recipientBar

                if !suggestions.isEmpty {
                    Divider()
                    contactSuggestions
                }

                Divider()
                Spacer(minLength: 0)
                Divider()
                messageInputBar
            }
            .background(PhoneBackdrop())
            .navigationTitle(L10n.t("新信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("发送"), action: sendNow)
                        .disabled(!canSend)
                }
            }
            .task { await model.contacts.loadIfAuthorized() }
            .sheet(isPresented: $showingContacts) {
                MessageContactPicker { phone in
                    recipient = phone
                    showingContacts = false
                }
                .environmentObject(model)
            }
        }
    }

    private var recipientBar: some View {
        HStack(spacing: 9) {
            Button {
                showingContacts = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("从通讯录选择"))

            Text(L10n.t("收件人："))
                .foregroundStyle(.secondary)

            TextField(L10n.t("输入号码或姓名"), text: $recipient)
                .textFieldStyle(.plain)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)

            if let contact = matchedContact {
                HStack(spacing: 6) {
                    InitialAvatar(name: contact.name, photoData: contact.photoData, size: 28)
                    Text(contact.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: 130, alignment: .trailing)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("已识别联系人：\(contact.name)")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var contactSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { contact in
                    Button {
                        recipient = contact.phones.first ?? recipient
                    } label: {
                        HStack(spacing: 7) {
                            InitialAvatar(name: contact.name, photoData: contact.photoData, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(contact.phones.first ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var messageInputBar: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 9) {
                TextField(L10n.t("短信内容"), text: $content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                Button(action: sendNow) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            canSend ? Color.blue : Color.secondary.opacity(0.4),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(L10n.t("发送"))
            }

            Text(L10n.t("短信将通过 4G 模块发送"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private func sendNow() {
        guard canSend else { return }
        sending = true
        Task {
            if await model.sendSMS(to: recipient, content: content) { dismiss() }
            sending = false
        }
    }
}

private struct MessageContactPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    let onSelect: (String) -> Void

    private var filteredContacts: [ContactStore.Contact] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.contacts.isAuthorized {
                    EmptyStateView(
                        title: L10n.t("授权访问通讯录"),
                        systemImage: "person.crop.circle.badge.questionmark",
                        actionTitle: L10n.t("授权访问通讯录")
                    ) {
                        Task { await model.contacts.requestAccessAndLoad() }
                    }
                } else if filteredContacts.isEmpty {
                    EmptyStateView(title: L10n.t("通讯录为空"), systemImage: "person.2")
                } else {
                    List(filteredContacts) { contact in
                        ForEach(contact.phones, id: \.self) { phone in
                            Button {
                                onSelect(phone)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    InitialAvatar(name: contact.name, photoData: contact.photoData)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(contact.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(phone)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("选择联系人"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: L10n.t("搜索姓名或号码"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
            .task { await model.contacts.loadIfAuthorized() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 通讯录

struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var search = ""

    private var filtered: [ContactStore.Contact] {
        guard !search.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.phones.contains { $0.contains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.contacts.isAuthorized {
                    EmptyStateView(
                        title: model.contacts.authorizationState == .denied
                            ? "通讯录权限已关闭"
                            : L10n.t("授权访问通讯录"),
                        systemImage: "person.crop.circle.badge.questionmark",
                        actionTitle: model.contacts.authorizationState == .denied
                            ? "前往系统设置"
                            : L10n.t("授权访问通讯录")
                    ) {
                        if model.contacts.authorizationState == .denied {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        } else {
                            Task { await model.contacts.requestAccessAndLoad() }
                        }
                    }
                } else if filtered.isEmpty {
                    EmptyStateView(title: L10n.t("通讯录为空"), systemImage: "person.2")
                } else {
                    List(filtered) { contact in
                        NavigationLink {
                            ContactDetailView(contact: contact, onCall: onCall, onMessage: onMessage)
                        } label: {
                            HStack(spacing: PhoneListMetrics.avatarSpacing) {
                                InitialAvatar(
                                    name: contact.name,
                                    photoData: contact.photoData,
                                    fallbackContent: RecentAvatarPolicy.content(contactName: contact.name),
                                    size: PhoneListMetrics.avatarSize
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contact.name)
                                        .font(.body.weight(.semibold))
                                        .lineLimit(1)
                                    Text(contact.phones.first ?? "")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: PhoneListMetrics.rowHeight)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(
                            top: 0,
                            leading: PhoneListMetrics.horizontalInset,
                            bottom: 0,
                            trailing: PhoneListMetrics.horizontalInset
                        ))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in
                            PhoneListMetrics.separatorLeading
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
                    .phoneReportsTabBarCompactState()
                }
            }
            .background(PhoneBackdrop())
            .navigationTitle("\(L10n.t("通讯录")) · \(model.contacts.contacts.count)")
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.t("搜索姓名或号码")
            )
            .refreshable { await model.contacts.requestAccessAndLoad() }
            .task { await model.contacts.loadIfAuthorized() }
        }
    }
}

private extension View {
    @ViewBuilder
    func dialKeySurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
    }
}

private struct ContactDetailView: View {
    let contact: ContactStore.Contact
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        InitialAvatar(name: contact.name, photoData: contact.photoData, size: 82)
                        Text(contact.name).font(.title2.weight(.semibold))
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(contact.phones, id: \.self) { phone in
                    HStack {
                        Text(phone)
                            .font(.body.monospacedDigit())
                        Spacer()
                        HStack(spacing: 12) {
                            Button { onMessage(phone) } label: {
                                Image(systemName: "message.fill")
                                    .foregroundStyle(.blue)
                                    .frame(width: 42, height: 42)
                                    .background(Color.blue.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("发短信"))

                            Button { onCall(phone) } label: {
                                Image(systemName: "phone.fill")
                                    .foregroundStyle(.green)
                                    .frame(width: 42, height: 42)
                                    .background(Color.green.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("拨号"))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AvatarFallbackContent: Equatable {
    case person
    case initial(String)
}

enum RecentAvatarPolicy {
    static func content(contactName: String?) -> AvatarFallbackContent {
        let trimmed = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = trimmed.first else { return .person }
        return .initial(String(first))
    }
}

struct InitialAvatar: View {
    let name: String
    var photoData: Data? = nil
    var fallbackContent: AvatarFallbackContent? = nil
    var size: CGFloat = 44

    private var resolvedFallback: AvatarFallbackContent {
        fallbackContent
            ?? .initial(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
    }

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var avatarFallback: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: fallbackColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                switch resolvedFallback {
                case .person:
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(y: size * 0.08)
                case let .initial(initial):
                    Text(initial)
                        .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: Color.indigo.opacity(0.55), radius: 1.4, x: 0, y: 1.2)
                        .overlay {
                            Text(initial)
                                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.28))
                                .offset(y: -0.8)
                        }
                }
            }
            .overlay {
                Circle().stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: fallbackColors.last?.opacity(0.22) ?? .clear, radius: 3, y: 2)
    }

    private var fallbackColors: [Color] {
        switch resolvedFallback {
        case .person:
            return [
                Color(red: 0.64, green: 0.76, blue: 0.91),
                Color(red: 0.43, green: 0.48, blue: 0.78),
            ]
        case .initial:
            return [
                Color(red: 0.66, green: 0.78, blue: 0.92),
                Color(red: 0.43, green: 0.49, blue: 0.79),
            ]
        }
    }
}

/// 新系统使用原生 ContentUnavailableView，iOS 16 保留等价回退。
private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(emptyStateDescription)
            } actions: {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var emptyStateDescription: String {
        switch systemImage {
        case "message": return "收到的短信会显示在这里。"
        case "phone.arrow.up.right": return "完成通话后，记录会显示在这里。"
        case "person.2": return "联系人会从系统通讯录同步。"
        default: return "完成连接或授权后即可使用。"
        }
    }
}

// MARK: - 通话覆盖层

enum CallSurfacePhase: Equatable {
    case incoming
    case connected
}

enum CallSurfaceAction: Equatable {
    case decline
    case answer
    case mute
    case end
    case keypad
    case speaker
}

struct CallSurfaceContent: Equatable {
    let phase: CallSurfacePhase
    let primaryActions: [CallSurfaceAction]
    let secondaryActions: [CallSurfaceAction]
    let showsDuration: Bool

    init(state: String) {
        if ["incoming", "waiting"].contains(state) {
            phase = .incoming
            primaryActions = [.decline, .answer]
            secondaryActions = []
            showsDuration = false
        } else {
            phase = .connected
            primaryActions = [.end]
            secondaryActions = [.mute, .keypad, .speaker]
            showsDuration = true
        }
    }
}

enum CallProximityPolicy {
    static func shouldMonitor(state: String, speakerEnabled: Bool) -> Bool {
        guard !speakerEnabled else { return false }
        return ["dialing", "alerting", "connecting", "active", "held", "ending"].contains(state)
    }
}

struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let call: CallRecord
    @State private var showingKeypad = false

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var content: CallSurfaceContent { CallSurfaceContent(state: call.state) }
    private var avatarSize: CGFloat {
        content.phase == .incoming ? (isCompact ? 116 : 132) : (isCompact ? 92 : 112)
    }
    private var controlSize: CGFloat { isCompact ? 62 : 68 }
    private var displayName: String { model.contacts.displayName(for: call.number) }
    private var contactPhotoData: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }

    var body: some View {
        ZStack {
            CallBackdrop()
            Group {
                if content.phase == .incoming {
                    incomingSurface
                } else {
                    connectedSurface
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, isCompact ? 20 : 32)
            .padding(.vertical, isCompact ? 18 : 26)
        }
        // 来电提醒与接通后的通话都是聚焦型全屏任务。保持固定画布，避免
        // ScrollView 的拖动/回弹，也避免手势误触影响接听和挂断。
        .contentShape(Rectangle())
        .sheet(isPresented: $showingKeypad) { DTMFKeypadView() }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear { updateProximityMonitoring() }
        .onChange(of: call.state) { _ in updateProximityMonitoring() }
        .onChange(of: model.audio.speakerEnabled) { _ in updateProximityMonitoring() }
        .onDisappear { UIDevice.current.isProximityMonitoringEnabled = false }
    }

    private var incomingSurface: some View {
        VStack(spacing: 0) {
            callHeader(title: "AirSIM 来电", showsRecording: false)

            Spacer(minLength: isCompact ? 36 : 54)

            InitialAvatar(
                name: displayName,
                photoData: contactPhotoData,
                size: avatarSize
            )
            .overlay { Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1) }
            .shadow(color: .black.opacity(0.34), radius: 28, y: 16)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(displayName)
                    .font(isCompact ? .system(size: 38, weight: .semibold) : .system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
                    .multilineTextAlignment(.center)

                if let number = call.number, number != displayName {
                    Text(number)
                        .font(.title3.weight(.regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.68))
                        .textSelection(.enabled)
                }

                Text(L10n.t("等待接听"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(.top, 24)

            connectivityBadge
                .padding(.top, 22)

            Spacer(minLength: isCompact ? 52 : 76)

            HStack {
                CallDecisionButton(
                    title: L10n.t("拒接"),
                    icon: "phone.down.fill",
                    color: .red
                ) {
                    Task { await model.reject() }
                }

                Spacer(minLength: 56)

                CallDecisionButton(
                    title: L10n.t("接听"),
                    icon: "phone.fill",
                    color: .green
                ) {
                    Task { await model.answer() }
                }
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, isCompact ? 12 : 28)
            .padding(.bottom, isCompact ? 16 : 28)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
    }

    private var connectedSurface: some View {
        VStack(spacing: 0) {
            callHeader(title: "AirSIM 通话", showsRecording: true)

            Spacer(minLength: isCompact ? 24 : 42)

            InitialAvatar(name: displayName, photoData: contactPhotoData, size: avatarSize)
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(displayName)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                if let number = call.number, number != displayName {
                    Text(number)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.66))
                        .textSelection(.enabled)
                }
                if content.showsDuration {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(at: context.date))
                            .font(.title2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.82))
                            .contentTransition(.numericText())
                    }
                }
            }
            .padding(.top, 22)

            audioStatusBadge
                .padding(.top, 20)

            if let audioError = model.audio.errorMessage, !audioError.isEmpty {
                Text(audioError)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 10)
            }

            Spacer(minLength: isCompact ? 34 : 54)

            HStack(spacing: isCompact ? 20 : 34) {
                CallCircleButton(
                    title: model.isMuted ? L10n.t("取消静音") : L10n.t("静音"),
                    icon: model.isMuted ? "mic.slash.fill" : "mic.fill",
                    color: model.isMuted ? .orange : nil,
                    foregroundColor: .white,
                    size: controlSize
                ) {
                    Task { await model.toggleMute() }
                }
                CallCircleButton(
                    title: "键盘",
                    icon: "circle.grid.3x3.fill",
                    color: nil,
                    foregroundColor: .white,
                    size: controlSize
                ) {
                    showingKeypad = true
                }
                SpeakerRouteButton(
                    audio: model.audio,
                    size: controlSize,
                    action: model.toggleSpeaker
                )
            }
            .frame(maxWidth: 430)

            CallDecisionButton(
                title: L10n.t("挂断"),
                icon: "phone.down.fill",
                color: .red
            ) {
                Task { await model.hangup() }
            }
            .padding(.top, isCompact ? 30 : 42)
            .padding(.bottom, isCompact ? 8 : 18)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
    }

    private func callHeader(title: String, showsRecording: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .symbolRenderingMode(.hierarchical)
            Text(title)
            Spacer()
            if showsRecording {
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(model.isRecording ? .red : .white)
                        .frame(width: 44, height: 44)
                }
                .callControlGlass(tint: model.isRecording ? .red.opacity(0.16) : nil)
                .accessibilityLabel(model.isRecording ? L10n.t("停止录音") : L10n.t("录音"))
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white.opacity(0.72))
        .frame(maxWidth: 520)
    }

    private var connectivityBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(moduleIsReachable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(connectivityText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .callControlGlass(tint: (moduleIsReachable ? Color.green : Color.orange).opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    private var audioStatusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.callAudioIsActive ? Color.green : audioStatusColor)
                .frame(width: 8, height: 8)
            Text(model.callAudioStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
            if model.audio.active, !model.audio.routeDescription.isEmpty {
                Text("· \(model.audio.routeDescription)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 38)
        .callControlGlass(tint: audioStatusColor.opacity(0.10))
    }

    private var moduleIsReachable: Bool {
        model.isOnline || model.cloudAgentStatus?.cloudOnline == true
    }

    private var connectivityText: String {
        let status = moduleIsReachable ? "模块在线" : "模块连接中"
        let signal = model.modemStatus?.signalDBM ?? model.cloudAgentStatus?.signalDBM
        guard let signal else { return status }
        return "\(status) · 信号 \(signal) dBm"
    }

    private var audioStatusColor: Color {
        switch model.cloudCallAudioState {
        case .failed: return .red
        case .connected: return .green
        case .connecting: return .orange
        case .idle: return model.audio.active ? .green : .orange
        }
    }

    private func durationText(at date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(call.startedAt)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func updateProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = CallProximityPolicy.shouldMonitor(
            state: call.state,
            speakerEnabled: model.audio.speakerEnabled
        )
    }
}

private struct SpeakerRouteButton: View {
    @ObservedObject var audio: AudioSessionController
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        CallCircleButton(
            title: L10n.t("扬声器"),
            icon: audio.speakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
            color: audio.speakerEnabled ? .blue : nil,
            foregroundColor: .white,
            size: size,
            action: action
        )
    }
}

private struct CallDecisionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Circle()
                    .fill(color.gradient)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: color.opacity(0.28), radius: 16, y: 8)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(minWidth: 96, minHeight: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct CallCircleButton: View {
    let title: String
    let icon: String
    let color: Color?
    var foregroundColor: Color = .white
    var size: CGFloat = 68
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Circle().fill(.clear).frame(width: size, height: size).overlay {
                    Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(foregroundColor)
                }
                .callControlGlass(tint: color?.opacity(0.24), shape: .circle)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: size)
        }
        .buttonStyle(.plain)
    }
}

private struct CallBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.008, green: 0.012, blue: 0.025)
            RadialGradient(
                colors: [Color.blue.opacity(0.24), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.12), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

private enum CallControlShape { case capsule, circle }

private struct CallControlGlass: ViewModifier {
    let tint: Color?
    let shape: CallControlShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            switch shape {
            case .capsule:
                content.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
            case .circle:
                content.glassEffect(.regular.tint(tint).interactive(), in: Circle())
            }
        } else {
            switch shape {
            case .capsule:
                content.background(.ultraThinMaterial, in: Capsule())
            case .circle:
                content.background(.ultraThinMaterial, in: Circle())
            }
        }
    }
}

private extension View {
    func callControlGlass(
        tint: Color? = nil,
        shape: CallControlShape = .capsule
    ) -> some View {
        modifier(CallControlGlass(tint: tint, shape: shape))
    }
}

private struct DTMFKeypadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: AppModel
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    private var keySize: CGFloat { horizontalSizeClass == .compact ? 62 : 70 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ForEach(rows, id: \.description) { row in
                    HStack(spacing: 24) {
                        ForEach(row, id: \.self) { digit in
                            Button {
                                Task { await model.sendDTMF(digit) }
                            } label: {
                                Text(digit)
                                    .font(.title)
                                    .frame(width: keySize, height: keySize)
                                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("DTMF")
            .toolbar { Button(L10n.t("取消")) { dismiss() } }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
