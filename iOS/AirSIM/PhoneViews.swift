import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import LinkPresentation
import UniformTypeIdentifiers
import UserNotifications
import Contacts
import ContactsUI

enum DialPadPasteSanitizer {
    static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        var filtered = String(value.unicodeScalars.filter { allowed.contains($0) })
        if filtered.dropFirst().contains("+") {
            filtered = String(filtered.enumerated().compactMap { index, character in
                character == "+" && index != 0 ? nil : character
            })
        }
        return String(filtered.prefix(64))
    }
}

enum SMSVerificationCodeClipboard {
    static let enabledKey = "airsim.auto-copy-sms-code"

    @MainActor
    static func handle(_ messages: [SMSMessage]) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        guard enabled else { return }
        let recent = messages
            .filter { !$0.isOutgoing && $0.timestamp > Date().addingTimeInterval(-300) }
            .sorted { $0.timestamp < $1.timestamp }
        guard let message = recent.last,
              let code = SMSVerificationCodeExtractor.extract(from: message.content) else { return }
        let delivery = message.deliveryID ?? message.id
        guard defaults.string(forKey: "airsim.last-auto-copied-sms-code") != delivery else { return }
        UIPasteboard.general.string = code
        defaults.set(delivery, forKey: "airsim.last-auto-copied-sms-code")
    }
}

enum SMSVerificationCodeExtractor {
    static func extract(from text: String) -> String? {
        let patterns = [
            "(?:验证码|校验码|动态码|确认码|verification code|security code|code|otp)[^0-9]{0,24}([0-9]{4,8})",
            "(?<![0-9])([0-9]{4,8})(?![0-9])",
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = expression.firstMatch(in: text, options: [], range: range),
               let codeRange = Range(match.range(at: 1), in: text) {
                return String(text[codeRange])
            }
        }
        return nil
    }
}

enum PhoneContentSearch {
    static func numberMatches(_ number: String?, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        guard let number else { return false }
        if number.localizedStandardContains(query) { return true }
        let allowed = CharacterSet(charactersIn: "+0123456789 -().")
        guard query.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        func digits(_ value: String) -> String {
            let compact = value.filter { $0.isASCII && $0.isNumber }
            if value.trimmingCharacters(in: .whitespaces).hasPrefix("+86") { return String(compact.dropFirst(2)) }
            if value.trimmingCharacters(in: .whitespaces).hasPrefix("0086") { return String(compact.dropFirst(4)) }
            return compact
        }
        let token = digits(query)
        return !token.isEmpty && digits(number).contains(token)
    }
    static func smsMatches(sender: String, contactName: String?, messages: [SMSMessage], query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || numberMatches(sender, query: query)
            || contactName?.localizedStandardContains(query) == true
            || messages.contains { $0.content.localizedStandardContains(query) }
    }
}

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
        mode: AirSIMConnectionMode = .automatic,
        vowlanOnline: Bool,
        cloudOnline: Bool,
        bluetoothReady: Bool = false
    ) -> DialPadTransportPresentation? {
        let selected = DialRouteSelector.preferred(
            mode: mode,
            vowlanReady: vowlanOnline,
            bluetoothReady: bluetoothReady,
            cloudReady: cloudOnline
        )
        if selected == .vowlan {
            return DialPadTransportPresentation(
                title: "VoWLAN",
                detail: "拨号及通话音频将通过同一 Wi-Fi 或三星热点",
                systemImage: "wifi",
                transport: .vowlan
            )
        }
        if selected == .bluetooth {
            return DialPadTransportPresentation(
                title: "蓝牙",
                detail: "拨号及通话音频将通过 VoBLE，不使用 Relay",
                systemImage: "wave.3.right",
                transport: .bluetooth
            )
        }
        if selected == .cloud {
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

enum DialPadAgentSection: Equatable {
    case current, selection, bluetooth, none

    static func make(mode: AirSIMConnectionMode, hasCurrent: Bool, pairedCount: Int) -> Self {
        if hasCurrent { return .current }
        if pairedCount > 0 { return .selection }
        if mode == .bluetooth { return .bluetooth }
        return .none
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

/// Window-based rules: regular-width phones and resizable windows are not iPads.
/// Keep two usable columns; accessibility sizes retain a scrollable single column.
enum PhoneWindowLayout {
    static func usesTwoColumns(_ size: CGSize, accessibilitySize: Bool) -> Bool {
        !accessibilitySize && size.width >= 700 && size.height >= 280
    }
}

struct DialPadLayoutMetrics {
    let keySize: CGFloat
    let keySpacing: CGFloat
    let rowSpacing: CGFloat
    let sectionSpacing: CGFloat
    let verticalPadding: CGFloat
    let numberFontSize: CGFloat
    let numberHeight: CGFloat
    let contactHeight: CGFloat

    var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    var digitFontSize: CGFloat { min(42, max(23, keySize * 0.46)) }
    var letterFontSize: CGFloat { min(12, max(8, keySize * 0.14)) }
    var callIconSize: CGFloat { min(30, max(23, keySize * 0.33)) }
    var deleteIconSize: CGFloat { min(24, max(19, keySize * 0.27)) }

    init(availableHeight: CGFloat, availableWidth: CGFloat, compactWidth: Bool, twoColumns: Bool = false) {
        let compactHeight = availableHeight < 700
        let desiredKeySize: CGFloat = compactWidth ? 88 : 92
        let desiredKeySpacing: CGFloat = compactWidth ? 24 : 34
        let reservedHeight: CGFloat = twoColumns ? 64 : (compactHeight ? 205 : 220)
        let verticalKeySize = (availableHeight - reservedHeight) / 5
        let contentWidth = min(520, max(0, availableWidth - 32))
        let horizontalKeySize = (contentWidth - desiredKeySpacing * 2) / 3

        keySize = min(desiredKeySize, max(twoColumns ? 44 : 56, min(verticalKeySize, horizontalKeySize)))
        keySpacing = min(
            desiredKeySpacing,
            max(14, (contentWidth - keySize * 3) / 2)
        )
        rowSpacing = compactHeight ? 8 : 20
        sectionSpacing = compactHeight ? 8 : 26
        verticalPadding = compactHeight ? 6 : 10
        numberFontSize = compactHeight ? 32 : (compactWidth ? 36 : 42)
        numberHeight = compactHeight ? 40 : 46
        contactHeight = compactHeight ? 18 : 20
    }
}

// MARK: - 拨号

struct DialPadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var deleteRepeatTask: Task<Void, Never>?
    @State private var zeroWasLongPressed = false
    @State private var showingNewContact = false

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

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let twoColumns = PhoneWindowLayout.usesTwoColumns(proxy.size,
                    accessibilitySize: dynamicTypeSize.isAccessibilitySize)
                let layout = twoColumns
                    ? AnyLayout(HStackLayout(alignment: .center, spacing: 32))
                    : AnyLayout(VStackLayout(spacing: 12))
                let metrics = DialPadLayoutMetrics(
                    availableHeight: proxy.size.height,
                    availableWidth: twoColumns ? (proxy.size.width - 64) / 2 : proxy.size.width,
                    compactWidth: isCompact,
                    twoColumns: twoColumns
                )

                ScrollView {
                    layout {
                        VStack(spacing: metrics.sectionSpacing) {
                            Group {
                                if model.numberInput.isEmpty {
                                    Color.clear.accessibilityHidden(true)
                                } else {
                                    DialSIMLinePicker()
                                }
                            }
                            .frame(height: 44)
                            VStack(spacing: 2) {
                                Text(model.numberInput.isEmpty ? L10n.t("输入号码") : model.numberInput)
                                    .font(
                                        .system(
                                            size: metrics.numberFontSize,
                                            weight: .regular,
                                            design: .default
                                        )
                                    )
                                    .monospacedDigit()
                                    .foregroundStyle(model.numberInput.isEmpty ? Color.clear : .primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.45)
                                    .frame(minHeight: metrics.numberHeight)
                                    .accessibilityIdentifier("dialpad.number")
                                    .accessibilityLabel(model.numberInput.isEmpty ? L10n.t("输入号码") : model.numberInput)

                                Group {
                                    if let matchedName { Text(matchedName).foregroundStyle(.secondary) }
                                    else { Text(" ").accessibilityHidden(true) }
                                }
                                .font(.subheadline)
                                .frame(minHeight: metrics.contactHeight)

                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = model.numberInput
                                } label: {
                                    Label("复制号码", systemImage: "doc.on.doc")
                                }
                                .disabled(model.numberInput.isEmpty)
                                Button("清空号码", action: clearNumber).disabled(model.numberInput.isEmpty)
                                Button {
                                    guard let raw = UIPasteboard.general.string else { return }
                                    model.numberInput = DialPadPasteSanitizer.sanitize(raw)
                                } label: {
                                    Label("粘贴号码", systemImage: "doc.on.clipboard")
                                }
                            }


                        }
                        .frame(maxWidth: twoColumns ? 420 : 520)

                        VStack(spacing: metrics.sectionSpacing) {
                            dialKeyGrid(metrics: metrics)
                            dialActions(metrics: metrics)
                        }
                    }
                    .frame(maxWidth: twoColumns ? 1000 : 520)
                    .padding(.horizontal, 16)
                    .padding(.vertical, metrics.verticalPadding)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollDisabled(true)
                .scrollIndicators(.hidden)
            }
            .background(PhoneBackdrop(grouped: false))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewContact, onDismiss: {
                Task { await model.contacts.loadIfAuthorized(force: true) }
            }) { NewDialContactView(number: model.numberInput) }
            .onDisappear(perform: stopRepeatingDelete)
        }
    }

    @ViewBuilder
    private func dialKeyGrid(metrics: DialPadLayoutMetrics) -> some View {
        if #available(iOS 26.0, *) {
            // 融合距离必须明显小于按键的真实间距，否则 Liquid Glass 会把相邻圆键吸成一体。
            GlassEffectContainer(spacing: 6) {
                dialKeyRows(metrics: metrics)
            }
        } else {
            dialKeyRows(metrics: metrics)
        }
    }

    private func dialKeyRows(metrics: DialPadLayoutMetrics) -> some View {
        VStack(spacing: metrics.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: metrics.keySpacing) {
                    ForEach(row, id: \.0) { digit, letters in
                        dialKey(digit: digit, letters: letters, metrics: metrics)
                    }
                }
            }
        }
        .frame(width: metrics.keypadWidth)
    }

    private func dialActions(metrics: DialPadLayoutMetrics) -> some View {
        VStack(spacing: 6) {
        if let status = model.outgoingDialStatus {
            Text(status).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityIdentifier("dialpad.callStatus")
        } else if let reason = model.outgoingDialFailure {
            Text("呼出失败 · " + reason).font(.caption).foregroundStyle(.red)
                .multilineTextAlignment(.center).accessibilityIdentifier("dialpad.callFailure")
        } else if let result = model.remoteEndFeedback { Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        HStack(spacing: metrics.keySpacing) {
            Group {
                if model.numberInput.isEmpty {
                    Color.clear.accessibilityHidden(true)
                } else {
                    Button { showingNewContact = true } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: metrics.deleteIconSize))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加号码")
                    .accessibilityIdentifier("dialpad.addContact")
                }
            }
            .frame(width: metrics.keySize, height: metrics.keySize)
            Button {
                if model.numberInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.recallLastOutgoingNumber()
                } else { Task { await model.dial() } }
            } label: {
                Circle()
                    .fill(.clear)
                    .frame(width: metrics.keySize, height: metrics.keySize)
                    .dialCallSurface()
                    .overlay {
                        Image(systemName: "phone.fill")
                            .font(.system(size: metrics.callIconSize, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
            .buttonStyle(.plain)
            .disabled(
                model.isBusy || model.isSubmittingOutgoing || (model.numberInput.isEmpty && model.mostRecentOutgoingNumber == nil)
            )
            .opacity((model.isSubmittingOutgoing || (model.numberInput.isEmpty && model.mostRecentOutgoingNumber == nil)) ? 0.4 : 1)
            .accessibilityLabel(model.numberInput.isEmpty ? "填入最近一次呼出号码" : "呼出")

            Group {
                if model.numberInput.isEmpty {
                    Color.clear.accessibilityHidden(true)
                } else {
            Image(systemName: "delete.left.fill")
                .font(.system(size: metrics.deleteIconSize))
                .foregroundStyle(Color(uiColor: .tertiarySystemFill))
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: metrics.deleteIconSize * 0.46, weight: .semibold))
                        .foregroundStyle(.primary)
                        .offset(x: metrics.deleteIconSize * 0.12)
                }
                .frame(width: metrics.keySize, height: metrics.keySize)
                .contentShape(Rectangle())
                .gesture(deleteGesture)
                .allowsHitTesting(!model.numberInput.isEmpty)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("dialpad.delete")
                .accessibilityLabel(L10n.t("删除"))
                .accessibilityHint(L10n.t("轻点删除一位，长按连续删除"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { deleteLastDigit() }
                .accessibilityAction(named: Text(L10n.t("清空号码"))) { clearNumber() }
                }
            }
            .frame(width: metrics.keySize, height: metrics.keySize)
        }
        .frame(width: metrics.keypadWidth)
        }
    }

    private func clearNumber() {
        stopRepeatingDelete()
        model.numberInput = ""
    }

    private func deleteLastDigit() {
        guard !model.numberInput.isEmpty else { return }
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
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

    @ViewBuilder
    private func dialKey(
        digit: String,
        letters: String,
        metrics: DialPadLayoutMetrics
    ) -> some View {
        Button {
            guard !(digit == "0" && zeroWasLongPressed) else {
                zeroWasLongPressed = false
                return
            }
            model.numberInput.append(digit)
        } label: {
            Group {
                if digit == "*" {
                    Image(systemName: "asterisk")
                        .font(.system(size: metrics.digitFontSize * 0.62, weight: .regular))
                } else {
                    VStack(spacing: 0) {
                        Text(digit)
                            .font(.system(size: metrics.digitFontSize, weight: .regular))
                        Text(letters)
                            .font(.system(size: letters == "+" ? metrics.letterFontSize * 1.4 : metrics.letterFontSize, weight: .semibold))
                            .tracking(1.4)
                    }
                }
            }
            .foregroundStyle(.primary)
            .frame(width: metrics.keySize, height: metrics.keySize)
            .dialKeySurface()
            .contentShape(Circle())
        }
        .buttonStyle(DialToneButtonStyle(digit: digit, enabled: !model.isMuted && !model.callLifecycleSnapshot.state.representsCall))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if digit == "0" {
                    zeroWasLongPressed = true
                    model.numberInput.append("+")
                }
            }
        )
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
    }
}

private struct NewDialContactView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let number: String
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = CNMutableContact()
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                               value: CNPhoneNumber(stringValue: number))]
        let editor = CNContactViewController(forNewContact: contact)
        editor.contactStore = CNContactStore()
        editor.delegate = context.coordinator
        return UINavigationController(rootViewController: editor)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss()
        }
    }
}

private struct DialSIMLinePicker: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let agentID = model.currentAndroidAgent?.id ?? AndroidAgentBindingPreference.selected() {
            let slots = dialSlots(agentID: agentID)
            if !slots.isEmpty {
                let selected = slots.first { $0.id == model.selectedSIMSlotID(for: agentID) } ?? slots.first
                CompactSIMPicker(slots: slots, selectedID: selected?.id,
                    select: { model.selectSIMSlot($0.id, for: agentID) }) {
                    HStack(spacing: 5) {
                        Text(selected.map { CompactSIMSelectionPanel.title(for: $0) } ?? "安卓默认通话卡")
                            .font(.subheadline).lineLimit(1)
                        if slots.count > 1 { Image(systemName: "chevron.down").font(.caption2) }
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(slots.count < 2)
                .accessibilityIdentifier("dial-pad-sim-slot")
                .accessibilityLabel("拨号使用的 SIM 卡槽，\(selected.map { CompactSIMSelectionPanel.title(for: $0) } ?? "安卓默认通话卡")")
            }
        }
    }
    private func dialSlots(agentID: String) -> [AndroidSIMSlot] {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["AIRSIM_UI_DEVICE"] == "1" {
            return model.smsSIMSlots(for: agentID)
        }
#endif
        return model.simSlots(for: agentID)
    }

}

private struct SIMLineSelectorLabel: View {
    let slot: AndroidSIMSlot?
    var showsChevron = true
    var body: some View {
        HStack(spacing: 6) {
            Text(slot?.slotIndex.map { "SIM \($0 + 1)" } ?? slot?.label ?? "发送卡")
                .font(.subheadline.weight(.medium)).lineLimit(1)
            if showsChevron { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).frame(minHeight: 44)
        .phoneGlassSurface(cornerRadius: 22, interactive: true)
    }
}

/// The same authenticated status previously shown on the dial pad now lives in Settings.
struct AndroidDeviceStatusCard: View {
    @EnvironmentObject private var model: AppModel
    let agent: AndroidAgentPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(agent.deviceName, systemImage: "smartphone")
                .font(.headline)
                .accessibilityIdentifier("settings.deviceStatus")
            let liveSlots = model.simSlots(for: agent.id)
            let slots = liveSlots.isEmpty ? model.smsSIMSlots(for: agent.id) : liveSlots
            if !slots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if liveSlots.isEmpty {
                        Text("上次读取的 SIM 信息").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(slots) { slot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CompactSIMSelectionPanel.title(for: slot))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(slot.displayNumber ?? "号码未提供")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(slot.displayNumber == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.simNumber.\(slot.id)")
                    }
                }
            }
            if slots.isEmpty || slots.allSatisfy({ $0.displayNumber == nil }) {
                if let number = agent.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty {
                    Text(number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .textSelection(.enabled).accessibilityIdentifier("settings.deviceNumber")
                } else if slots.isEmpty {
                    Text("号码未提供").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                AgentTransportPill(title: "VoWLAN", online: agent.vowlanOnline, enabled: true)
                if DedicatedCallPolicy.vowlanOnly {
                    AgentPushSMSPills(agentID: agent.id, vowlanOnline: agent.vowlanOnline)
                } else {
                    HStack {
                        AgentTransportPill(title: "VoBLE", online: agent.bluetoothOnline, enabled: true)
                        AgentTransportPill(title: "云端", online: agent.cloudOnline, enabled: CloudModePreference.isEnabled(), lastConfirmed: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct AgentTransportPill: View {
    let title: String
    let online: Bool
    let enabled: Bool
    let lastConfirmed: Bool

    init(title: String, online: Bool, enabled: Bool, lastConfirmed: Bool = false) {
        self.title = title; self.online = online; self.enabled = enabled
        self.lastConfirmed = lastConfirmed
    }

    private var statusText: String {
        if !enabled { return "关闭" }
        if !online { return "离线" }
        return lastConfirmed ? "上次在线" : "在线"
    }

    private var color: Color { !enabled ? .secondary : (online ? .green : .secondary) }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(statusText)")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.1), in: Capsule())
    }
}

private struct PairedAndroidAgentsView: View {
    @Environment(\.dismiss) private var dismiss
    let agents: [AndroidAgentPresentation]
    let cloudModeEnabled: Bool
    let selectAgent: (String) -> Void

    var body: some View {
        NavigationStack {
            List(agents) { agent in
                Button {
                    selectAgent(agent.id)
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.deviceName)
                                .font(.headline)
                            Text(agent.phoneNumber ?? "号码未提供")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                            Image(systemName: agent.isCurrent ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(agent.isCurrent ? .green : .secondary)
                    }
                    HStack(spacing: 8) {
                        AgentTransportPill(title: "VoWLAN", online: agent.vowlanOnline, enabled: true)
                        if DedicatedCallPolicy.vowlanOnly {
                            AgentPushSMSPills(agentID: agent.id, vowlanOnline: agent.vowlanOnline)
                        } else {
                            AgentTransportPill(title: "VoBLE", online: agent.bluetoothOnline, enabled: true)
                            AgentTransportPill(title: "云端", online: agent.cloudOnline, enabled: cloudModeEnabled, lastConfirmed: true)
                        }
                        Spacer()
                        Text(agent.agentKindTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if agents.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "smartphone.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("暂无已配对 Android Agent")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("已配对 Android Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DialToneButtonStyle: ButtonStyle {
    let digit: String
    let enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed && enabled { LocalDialTone.shared.start(digit) }
                else { LocalDialTone.shared.stop(respectingMinimum: true) }
            }.onChange(of: enabled) { value in
                if !value { LocalDialTone.shared.stop() }
            }.onDisappear { LocalDialTone.shared.stop() }
    }
}

enum DialToneTiming {
    static let minimumDuration: TimeInterval = 0.16
    static func releaseDelay(held: TimeInterval) -> TimeInterval { max(0, minimumDuration - max(0, held)) }
}

enum LocalDialToneWaveform {
    static func wavData(for digit: String) -> Data? {
        guard digit.count == 1 else { return nil }
        let rows = ["123", "456", "789", "*0#"]
        guard let row = rows.firstIndex(where: { $0.contains(digit) }),
              let column = rows[row].firstIndex(of: Character(digit)) else { return nil }
        let low = [697.0,770,852,941][row], high = [1209.0,1336,1477][rows[row].distance(from: rows[row].startIndex, to: column)]
        // Whole-second integer-frequency cycles join without periodic fades.
        let rate = 44100, count = 44100
        var pcm = Data()
        for n in 0..<count {
            let t = Double(n) / Double(rate)
            var sample = Int16((sin(2 * .pi * low * t) + sin(2 * .pi * high * t)) * 4500).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func word<T: FixedWidthInteger>(_ number: T) { var value = number.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        wav.append(Data("RIFF".utf8)); word(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate*2)); word(UInt16(2)); word(UInt16(16))
        wav.append(Data("data".utf8)); word(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }
}

enum DialToneAudioSessionPolicy {
    @MainActor
    static func prepareIfIdle(session: AVAudioSession = .sharedInstance(),
                              systemCallID: UUID?, systemAudioActive: Bool) throws -> Bool {
        guard systemCallID == nil, !systemAudioActive else { return false }
        // Nonessential keypad feedback must obey the Ring/Silent switch.
        // Never activate/deactivate or reconfigure a CallKit-owned session.
        try session.setCategory(.ambient, mode: .default, options: [])
        return true
    }
}

@MainActor private final class LocalDialTone {
    static let shared = LocalDialTone()
    private var player: AVAudioPlayer?
    private var cachedTones: [String: Data] = [:]
    private var startedAt: TimeInterval = 0
    private var releaseTask: Task<Void, Never>?
    func start(_ digit: String) {
        stop()
        let callKit = CallKitController.shared
        do {
            guard try DialToneAudioSessionPolicy.prepareIfIdle(
                systemCallID: callKit.currentSystemCallUUID,
                systemAudioActive: callKit.audioSessionIsActive) else { return }
        } catch { return }
        guard let wav = cachedTones[digit] ?? LocalDialToneWaveform.wavData(for: digit) else { return }
        cachedTones[digit] = wav
        // Call media configures its own session when dialing begins.
        startedAt = ProcessInfo.processInfo.systemUptime
        player = try? AVAudioPlayer(data: wav); player?.numberOfLoops = -1; player?.volume = 0; player?.play()
        player?.setVolume(0.55, fadeDuration: 0.005)
    }
    func stop(respectingMinimum: Bool = false) {
        releaseTask?.cancel(); releaseTask = nil
        let remaining = DialToneTiming.releaseDelay(held: ProcessInfo.processInfo.systemUptime - startedAt)
        if respectingMinimum, player != nil, remaining > 0 {
            releaseTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self?.stop()
            }
            return
        }
        guard let endingPlayer = player else { return }
        player = nil
        // Stopping at an arbitrary phase produces a broadband click. Fade
        // this captured player only; a later key owns a different instance.
        endingPlayer.setVolume(0, fadeDuration: 0.02)
        Task { @MainActor in
            defer { endingPlayer.stop() }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
        }
    }
}

// MARK: - 最近通话

struct RecentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var pendingDeletion: Set<String> = []
    @State private var confirmingDeletion = false
    @State private var searchText = ""
    @State private var missedOnly = false
    @State private var selectedGroupID: String?
    private var groups: [RecentCallGroup] {
        RecentCallGroup.grouped(model.callHistory.filter { !missedOnly || ($0.direction == "incoming" && $0.missed) }).filter { group in
            group.records.contains { PhoneContentSearch.numberMatches($0.number, query: searchText) }
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Picker("通话记录筛选", selection: $missedOnly) {
                    Text("全部").tag(false)
                    Text("未接来电").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(4).phoneGlassSurface(cornerRadius: 24)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 8, leading: PhoneListMetrics.horizontalInset,
                                     bottom: 12, trailing: PhoneListMetrics.horizontalInset))
                .accessibilityIdentifier("recents.filter")

                if groups.isEmpty {
                    EmptyStateView(title: searchText.isEmpty ? (missedOnly ? "暂无未接来电" : L10n.t("暂无通话记录")) : "未找到匹配号码",
                                   systemImage: searchText.isEmpty ? (missedOnly ? "phone.badge.checkmark" : "phone.arrow.up.right") : "magnifyingglass")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(groups) { group in
                    Button { selectedGroupID = group.id } label: {
                        HStack(spacing: PhoneListMetrics.avatarSpacing) {
                            InitialAvatar(name: contacts.displayName(for: group.latest.number),
                                photoData: group.latest.number.flatMap { contacts.contact(for: $0)?.photoData },
                                fallbackContent: RecentAvatarPolicy.content(contactName: group.latest.number.flatMap { contacts.contact(for: $0)?.name }),
                                size: PhoneListMetrics.avatarSize)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(contacts.displayName(for: group.latest.number))
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(group.latest.missed ? Color.red : Color.primary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(RecentCallTimeFormatter.string(for: group.latest.startedAt))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: PhoneListMetrics.timeColumnWidth, alignment: .trailing)
                                        .accessibilityLabel(Text(group.latest.startedAt, style: .date))
                                }
                                HStack(spacing: 5) {
                                    Image(systemName: group.latest.missed ? "phone.badge.xmark" : group.latest.direction == "incoming" ? "arrow.down.left" : "arrow.up.right")
                                        .foregroundStyle(group.latest.missed ? Color.red : .secondary)
                                    Text([group.latest.missed ? "未接来电" : group.latest.direction == "incoming" ? "呼入" : "呼出",
                                          group.latest.slotIndex.map { "SIM \($0 + 1)" } ?? "SIM 未记录"].joined(separator: " · "))
                                    if group.records.contains(where: { model.unseenMissedCallIDs.contains($0.id) }) {
                                        Text("未查看").foregroundStyle(.red)
                                    }
                                }.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                Text([group.latest.missed ? group.latest.ringingDurationLabel : group.latest.connectedDurationLabel,
                                      PhoneRegionLookup.resolvedRegion(number: group.latest.number, androidRegion: group.latest.numberRegion),
                                      "\(group.records.count) 次通话"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "info.circle").font(.title3).foregroundStyle(.tint)
                                .frame(width: 32, height: 44).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                        .frame(minHeight: PhoneListMetrics.rowHeight)

                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: PhoneListMetrics.horizontalInset,
                                         bottom: 0, trailing: PhoneListMetrics.horizontalInset))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in PhoneListMetrics.separatorLeading }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if group.records.contains(where: { model.unseenMissedCallIDs.contains($0.id) }) {
                            Button { model.markMissedCallsSeen(group.records) } label: { Label("标为已读", systemImage: "checkmark") }
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDeletion = RecentCallGroup.grouped(model.callHistory).first { $0.id == group.id }?.recordIDs ?? group.recordIDs; confirmingDeletion = true } label: { Label("删除全部记录", systemImage: "trash") }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
            .phoneReportsTabBarCompactState()
            .background(PhoneBackdrop(grouped: false))
            .navigationTitle(L10n.t("最近通话"))
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索号码")
            .navigationDestination(isPresented: Binding(get: { selectedGroupID != nil },
                set: { if !$0 { selectedGroupID = nil } })) {
                if let selectedGroupID { detail(selectedGroupID) }
            }
            .toolbar {
                phoneMorphingToolbarItem(placement: .topBarTrailing, id: "recents-actions") {
                    Menu {
                        Button { model.markMissedCallsSeen() } label: {
                            Label("将全部未接来电标为已读", systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("recents.markAllSeen")
                        .disabled(model.unseenMissedCallIDs.isEmpty)
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("通话记录操作")
                    .accessibilityIdentifier("recents.actions")
                }
            }
            .confirmationDialog("删除该号码的全部本机通话记录？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                Button("删除 \(pendingDeletion.count) 条记录", role: .destructive) {
                    model.deleteCallHistory(ids: pendingDeletion)
                    pendingDeletion = []
                }
            } message: { Text("仅删除此 iPhone 的 AirSIM 历史，不操作安卓系统记录。") }
        }
    }
    private func quickAction(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.subheadline).fixedSize(horizontal: true, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 52)
    }
    private func detailNumber(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 11, digits.hasPrefix("1") else { return raw }
        return String(digits.prefix(3)) + " " + String(digits.dropFirst(3).prefix(4)) + " " + String(digits.suffix(4))
    }

    private func detailAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 25))
                    .frame(width: 68, height: 68).callControlGlass(tint: .white.opacity(0.08))
                Text(title).font(.caption)
            }
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func recentDetailRow(_ call: CallRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(call.missed ? "未接来电" : call.direction == "incoming" ? "呼入" : "呼出")
                    .foregroundStyle(call.missed ? Color.red : .white)
                Spacer()
                Text(call.startedAt.formatted(date: .numeric, time: .shortened))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }
            Text(call.slotIndex.map { "SIM \($0 + 1)" } ?? "SIM 未记录")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            if call.missed { Text(call.ringingDurationLabel ?? "响铃时长未记录").font(.subheadline).foregroundStyle(.red) }
            else { Text(call.connectedDurationLabel ?? "通话时长未记录").font(.subheadline).foregroundStyle(.white.opacity(0.65)) }
        }
    }

    @ViewBuilder private func detail(_ id: String) -> some View {
        let records = RecentCallGroup.grouped(model.callHistory).first { $0.id == id }?.records ?? []
        ScrollView {
            VStack(spacing: 24) {
                if let first = records.first {
                    let name = contacts.displayName(for: first.number)
                    let number = first.number ?? "未知号码"
                    VStack(spacing: 16) {
                        InitialAvatar(name: name, photoData: first.number.flatMap { contacts.contact(for: $0)?.photoData },
                            fallbackContent: RecentAvatarPolicy.content(contactName: first.number.flatMap { contacts.contact(for: $0)?.name }), size: 220, glassFallback: true)
                            .padding(.top, 20).padding(.bottom, 12)
                        Text(name == number ? detailNumber(number) : name)
                            .font(.largeTitle.bold()).multilineTextAlignment(.center)
                        if name != number { Text(detailNumber(number)).font(.title3).textSelection(.enabled) }
                        if let info = PhoneRegionLookup.infoLine(number: first.number, slotIndex: first.slotIndex, androidRegion: first.numberRegion) {
                            Text(info).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                        }
                    }.frame(maxWidth: .infinity)
                    .contextMenu { Button("复制号码") { UIPasteboard.general.string = number } }
                    if let target = RecentCallDialPolicy.numberToDial(first.number) {
                        HStack(spacing: 32) {
                            detailAction("短信", icon: "message.fill") { onMessage(target) }
                            detailAction("呼出", icon: "phone.fill") { onCall(target) }
                        }.padding(.vertical, 8)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("最近一通").font(.title3.weight(.medium))
                        recentDetailRow(first)
                    }.padding(20).phoneGlassSurface(cornerRadius: 28)
                    DisclosureGroup("全部记录 · \(records.count) 次通话") {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(records) { call in
                                Divider()
                                recentDetailRow(call)
                                Text("结束原因 · " + call.disconnectReasonLabel)
                                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                            }
                        }.padding(.top, 12)
                    }.tint(.white).padding(20).phoneGlassSurface(cornerRadius: 28)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("电话").font(.caption).foregroundStyle(.white.opacity(0.65))
                        Text(detailNumber(number)).font(.title3).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20).phoneGlassSurface(cornerRadius: 28)
                } else { Text("记录已删除").foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.bottom, 28)
        }
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [Color(red: 0.40, green: 0.43, blue: 0.55),
                Color(red: 0.23, green: 0.17, blue: 0.38), Color(red: 0.10, green: 0.08, blue: 0.18)],
                startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle("通话详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.markMissedCallsSeen(records) }
    }
}

// MARK: - 短信

struct SMSConversationListState {
    var searchText = ""
    var showingComposer = false
    var showingClearConfirmation = false
    var editMode: EditMode = .inactive
    var selectedConversations: Set<String> = []
    var pendingDeletion: Set<String> = []
    var showingDeleteConfirmation = false

    mutating func requestDelete(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
        showingDeleteConfirmation = true
    }
}

/// The TabView root owns the navigation bar; the list and toolbar share only
/// presentation state so the title/actions cannot be swallowed by the tab.
struct SMSConversationListToolbar: ToolbarContent {
    @EnvironmentObject private var model: AppModel
    @Binding var state: SMSConversationListState

    var body: some ToolbarContent {
        phoneMorphingToolbarItem(placement: .topBarLeading, id: "top-action-leading-more") {
            SMSCompactActionsMenu(menu: actionsMenu)
                .frame(width: 44, height: 44)

        }
        phoneMorphingToolbarItem(placement: .topBarTrailing, id: "top-action-trailing-primary") {
            Button { state.showingComposer = true } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel(L10n.t("新信息"))
            .accessibilityIdentifier("sms-compose")
        }
    }
    private var actionsMenu: UIMenu {
        let toggle = UIAction(title: L10n.t(state.editMode.isEditing ? "完成选择" : "选择会话"),
                              image: UIImage(systemName: "checkmark.circle")) { _ in
            state.editMode = state.editMode.isEditing ? .inactive : .active
            state.selectedConversations = []
        }
        let refresh = UIAction(title: L10n.t("刷新短信"), image: UIImage(systemName: "arrow.clockwise")) { _ in
            Task { await model.refreshMessages() }
        }
        let markRead = UIAction(title: L10n.t("全部已读"), image: UIImage(systemName: "checkmark.circle"),
                                attributes: model.unreadMessageIDs.isEmpty ? [.disabled] : []) { _ in
            model.markMessagesRead(model.messages)
        }
        var management: [UIMenuElement] = []
        if state.editMode.isEditing {
            management.append(UIAction(title: L10n.t("删除所选会话"), image: UIImage(systemName: "trash"),
                attributes: state.selectedConversations.isEmpty ? [.destructive, .disabled] : [.destructive]) { _ in
                state.requestDelete(Set(model.messages.filter { state.selectedConversations.contains($0.sender) }.map(\.id)))
            })
        }
        management.append(UIAction(title: L10n.t("清空全部短信"), image: UIImage(systemName: "trash"),
                                   attributes: model.messages.isEmpty ? [.destructive, .disabled] : [.destructive]) { _ in
            state.pendingDeletion = Set(model.messages.map(\.id))
            state.showingClearConfirmation = true
        })
        let menu = UIMenu(children: [UIMenu(options: .displayInline, children: [toggle, refresh, markRead]),
                                    UIMenu(options: .displayInline, children: management)])
        menu.preferredElementSize = .small
        return menu
    }

}

/// Native compact menu metrics, with the same glass toolbar shell as compose.
private struct SMSCompactActionsMenu: UIViewRepresentable {
    let menu: UIMenu
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold), forImageIn: .normal)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = L10n.t("短信操作")
        button.accessibilityIdentifier = "sms-list-actions"
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) { button.menu = menu }
}

struct MessagesView: View {
    @State private var decryptFailures = AirSIMHealthStore.load().failures.filter { !$0.resolved }
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Binding var pendingRecipient: String?
    @Binding var state: SMSConversationListState
    let openConversation: (String) -> Void

    private var conversations: [(sender: String, messages: [SMSMessage])] {
        Dictionary(grouping: model.messages, by: \.sender)
            .map { ($0.key, $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .filter { sender, messages in
                PhoneContentSearch.smsMatches(sender: sender, contactName: contacts.contact(for: sender)?.name,
                    messages: messages, query: state.searchText)
            }
            .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    var body: some View {
        Group {
            // Outside explicit deletion mode, row taps belong to navigation, not selection.
            List(selection: state.editMode.isEditing ? $state.selectedConversations : nil) {
                if !decryptFailures.isEmpty {
                    NavigationLink {
                        AirSIMDiagnosticsView().environmentObject(model)
                    } label: {
                        Label("有 \(decryptFailures.count) 条短信解密异常，查看设备与恢复步骤", systemImage: "exclamationmark.lock")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }
                if conversations.isEmpty {
                    EmptyStateView(title: state.searchText.isEmpty ? L10n.t("暂无短信") : "未找到匹配短信", systemImage: state.searchText.isEmpty ? "message" : "magnifyingglass")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(conversations, id: \.sender) { conversation in
                        Group {
                            if state.editMode.isEditing {
                                MessageConversationRow(sender: conversation.sender, messages: conversation.messages, searchQuery: state.searchText)
                            } else {
                                Button {
                                    openConversation(conversation.sender)
                                } label: {
                                    HStack(spacing: 8) {
                                        MessageConversationRow(sender: conversation.sender, messages: conversation.messages, searchQuery: state.searchText)
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
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
                        .tag(conversation.sender)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                state.requestDelete(Set(conversation.messages.map(\.id)))
                            } label: { Label("删除会话", systemImage: "trash") }
                        }
                    }
                }
            }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                decryptFailures = AirSIMHealthStore.load().failures.filter { !$0.resolved }
            }
            .onAppear { decryptFailures = AirSIMHealthStore.load().failures.filter { !$0.resolved } }
            .listStyle(.plain)
            .environment(\.editMode, $state.editMode)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
            .phoneReportsTabBarCompactState()
            .background(PhoneBackdrop(grouped: false))
            .searchable(text: $state.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索联系人、号码或内容")
            .onChange(of: state.searchText) { _ in state.selectedConversations = [] }
            .task { await contacts.loadIfAuthorized() }
            .task {
                await model.loadMessagesFromAgent(silently: true)
            }
            .onChange(of: pendingRecipient) { recipient in
                if recipient != nil { state.showingComposer = true }
            }
            .sheet(isPresented: $state.showingComposer, onDismiss: { pendingRecipient = nil }) {
                MessageComposer(initialRecipient: pendingRecipient ?? "")
                    .id(pendingRecipient ?? "")
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(L10n.t("清空全部短信"), isPresented: $state.showingClearConfirmation, titleVisibility: .visible) {
                Button(L10n.t("删除"), role: .destructive) {
                    model.deleteMessages(ids: state.pendingDeletion)
                    state.pendingDeletion = []
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text("仅删除此 iPhone 上 AirSIM 内的短信记录，不删除安卓系统短信，无法恢复。")
            }
            .confirmationDialog("删除短信记录？", isPresented: $state.showingDeleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    model.deleteMessages(ids: state.pendingDeletion)
                    state.selectedConversations = []
                    state.pendingDeletion = []
                }
                Button("取消", role: .cancel) { state.pendingDeletion = [] }
            } message: {
                Text("仅删除此 iPhone 上的所选记录，不删除安卓系统短信。新收到的短信不受影响。")
            }
        }
    }

    private struct MessageConversationRow: View {
        @EnvironmentObject private var model: AppModel
        @EnvironmentObject private var contacts: ContactStore
        let sender: String
        let messages: [SMSMessage]
        var searchQuery = ""
        private var previewMessage: SMSMessage? {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? messages.last : (messages.last { $0.content.localizedStandardContains(query) } ?? messages.last)
        }

        private var contact: ContactStore.Contact? {
            contacts.contact(for: sender)
        }

        private var displayName: String {
            contact?.name ?? contacts.displayName(for: sender)
        }

        private var unreadCount: Int {
            messages.filter { model.unreadMessageIDs.contains($0.id) }.count
        }

        var body: some View {
            HStack(spacing: PhoneListMetrics.avatarSpacing) {
                Group {
                    if unreadCount > 0 {
                        Circle().fill(Color(uiColor: .systemBlue))
                            .accessibilityLabel(String(format: L10n.t("%d 条未读短信"), unreadCount))
                            .accessibilityIdentifier("smsConversation.unread.\(sender)")
                    } else { Color.clear.accessibilityHidden(true) }
                }.frame(width: 9, height: 9)
                InitialAvatar(
                    name: displayName,
                    photoData: contact?.photoData,
                    fallbackContent: contact == nil
                        ? .person
                        : RecentAvatarPolicy.content(contactName: contact?.name),
                    size: PhoneListMetrics.avatarSize, serviceNumber: sender
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)

                        Spacer(minLength: 4)
                        Text(RecentCallTimeFormatter.string(for: previewMessage?.timestamp ?? .now))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(previewMessage?.content ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let latest = previewMessage {
                        Text(latest.simDeliveryLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)


            }
            .frame(minHeight: PhoneListMetrics.rowHeight)
        }
    }
}

private struct SMSAccountPicker: View {
    @EnvironmentObject private var model: AppModel
    let recipient: String
    var body: some View {
        if let agentID = model.currentAndroidAgent?.id ?? AndroidAgentBindingPreference.selected() {
            let slots = model.smsSIMSlots(for: agentID)
            if !slots.isEmpty {
                CompactSIMPicker(slots: slots,
                    selectedID: model.selectedSMSSlotID(for: agentID, recipient: recipient),
                    select: { slot in model.selectSMSSlot(slot.id, for: agentID, recipient: recipient) }) {
                    SIMLineSelectorLabel(slot: slots.first {
                        $0.id == model.selectedSMSSlotID(for: agentID, recipient: recipient)
                    }, showsChevron: slots.count > 1)
                }
                .disabled(slots.count < 2)
                .accessibilityLabel("发送线路，\(slots.first(where: { $0.id == model.selectedSMSSlotID(for: agentID, recipient: recipient) })?.label ?? "安卓默认短信卡")")
                .accessibilityIdentifier("sms.simSelector")
            } else {
                Label("安卓默认短信卡", systemImage: "simcard").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum SMSSendFailurePolicy {
    static func isUncertain(writeStarted: Bool, error: Error) -> Bool {
        guard writeStarted else { return false }
        if case let APIError.http(status, _) = error, (400..<500).contains(status), status != 408 { return false }
        if case APIError.unsupportedFeature = error { return false }
        return true
    }
}

enum SMSDraftCompletionPolicy {
    static func draft(sent: String, current: String, succeeded: Bool) -> String {
        succeeded && current == sent ? "" : current
    }
}

struct MessageThreadView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    let sender: String
    @State private var reply = ""
    @State private var sendingReply = false
    @State private var pendingDeletion: Set<String> = []
    @State private var showingDeleteConfirmation = false
    @State private var selection = SMSMessageSelection()
    @FocusState private var composerFocused: Bool

    private var dateLocale: Locale {
        let language = settings.language == .system ? L10n.effectiveLanguage : settings.language
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents.languageCode = language == .zh ? "zh" : "en"
        components.languageComponents.script = language == .zh ? "Hans" : nil
        return Locale(components: components)
    }

    private var messages: [SMSMessage] {
        model.messages
            .filter { $0.sender == sender }
            .sorted { $0.timestamp < $1.timestamp }
    }


    private var trimmedReply: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var replyBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(L10n.t("短信"), text: $reply, axis: .vertical)
                .accessibilityIdentifier("sms.reply")
                .focused($composerFocused)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.leading, 14)
                .padding(.trailing, 2)
                .padding(.vertical, 8)
                Button(action: sendReply) {
                    Group {
                        if sendingReply { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)) }
                    }
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(uiColor: trimmedReply.isEmpty ? .systemGray3 : .systemGreen)))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5)
                .padding(.bottom, 3)
                .accessibilityLabel(L10n.t("发送"))
                .disabled(trimmedReply.isEmpty || sendingReply)
        }
        .smsComposerGlass()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private func sendReply() {
        let body = trimmedReply
        guard !body.isEmpty, !sendingReply else { return }
        let draft = reply
        sendingReply = true
        Task {
            let succeeded = await model.sendSMS(to: sender, content: body)
            reply = SMSDraftCompletionPolicy.draft(sent: draft, current: reply, succeeded: succeeded)
            sendingReply = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SMSConversationTimelineView(
                messages: messages,
                selection: selection,
                locale: dateLocale,
                onBeginSelection: { id in
                    composerFocused = false
                    selection.begin(with: id)
                },
                onToggleSelection: { selection.toggle($0) },
                onBeginTextSelection: { composerFocused = false }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhoneBackdrop(grouped: false))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.isSelecting { selectionBar } else { replyBar }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SMSAccountPicker(recipient: sender)
                .padding(.vertical, 6).frame(maxWidth: .infinity)
                .background(.bar)
        }
        .onChange(of: messages) { selection.reconcile(with: $0); acknowledgeVisibleMessages() }
        .onAppear { isVisible = true; acknowledgeVisibleMessages() }
        .onDisappear { isVisible = false }
        .onChange(of: scenePhase) { _ in acknowledgeVisibleMessages() }
        .onChange(of: model.inAppPresentedCall?.id) { _ in acknowledgeVisibleMessages() }
        .navigationTitle(model.contacts.displayName(for: sender))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    InitialAvatar(name: model.contacts.displayName(for: sender),
                        photoData: model.contacts.contact(for: sender)?.photoData,
                        fallbackContent: RecentAvatarPolicy.content(contactName: model.contacts.contact(for: sender)?.name), size: 30, serviceNumber: sender)
                    Text(model.contacts.displayName(for: sender)).font(.headline).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selection.isSelecting {
                    Button {
                        selection.cancel()
                        composerFocused = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.t("取消选择"))
                } else {
                    Menu {
                        Button("选择短信", systemImage: "checkmark.circle") {
                            if let message = messages.last {
                                composerFocused = false
                                selection.begin(with: message.id)
                            }
                        }.disabled(messages.isEmpty)
                        Button("复制号码", systemImage: "doc.on.doc") { UIPasteboard.general.string = sender }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("会话操作")
                }
            }
        }
        .confirmationDialog(
            String(format: L10n.t("删除所选 %d 条短信？"), pendingDeletion.count),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("删除"), role: .destructive) {
                let ids = pendingDeletion
                model.deleteMessages(ids: ids)
                // Persistence failure leaves the records and selection intact.
                if !model.messages.contains(where: { ids.contains($0.id) }) {
                    selection.cancel()
                }
                pendingDeletion = []
            }
            Button(L10n.t("取消"), role: .cancel) { pendingDeletion = [] }
        } message: { Text(L10n.t("仅删除此 iPhone 上 AirSIM 内的记录，不删除安卓系统短信。")) }
    }

    private func acknowledgeVisibleMessages() {
        guard isVisible, scenePhase == .active, model.inAppPresentedCall == nil else { return }
        model.markMessagesRead(messages)
    }

    private var selectionBar: some View {
        HStack {
            Button(role: .destructive) {
                pendingDeletion = selection.selectedIDs
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.t("删除所选短信"))
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .phoneGlassSurface(cornerRadius: 22, interactive: true)
            .disabled(selection.selectedIDs.isEmpty)
            Spacer()
            Text(String(format: L10n.t("已选 %d 条"), selection.selectedIDs.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            SMSMessageShareButton(texts: selection.selectedMessages(in: messages).map(\.content))
                .frame(width: 44, height: 44)
                .phoneGlassSurface(cornerRadius: 22, interactive: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Anchor iPad's native activity popover to the tapped sharing button.
private struct SMSMessageShareButton: UIViewRepresentable {
    let texts: [String]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22), forImageIn: .normal
        )
        button.tintColor = .label
        button.addAction(UIAction { [weak button, weak coordinator = context.coordinator] _ in
            guard let button else { return }
            coordinator?.share(from: button)
        }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.texts = texts
        button.isEnabled = !texts.isEmpty
        button.accessibilityLabel = L10n.t("共享所选短信")
    }

    final class Coordinator {
        var texts: [String] = []

        func share(from button: UIButton) {
            guard !texts.isEmpty else { return }
            var responder: UIResponder? = button
            while let current = responder {
                if let presenter = current as? UIViewController {
                    guard presenter.presentedViewController == nil else { return }
                    let title = texts.count == 1 ? L10n.t("1 条短信")
                        : String(format: L10n.t("%d 条短信"), texts.count)
                    let activity = UIActivityViewController(
                        activityItems: texts.map { SMSMessageShareItem(text: $0, title: title) },
                        applicationActivities: nil
                    )
                    if let popover = activity.popoverPresentationController {
                        popover.sourceView = button
                        popover.sourceRect = button.bounds
                    }
                    presenter.present(activity, animated: true)
                    return
                }
                responder = current.next
            }
        }
    }
}

private final class SMSMessageShareItem: NSObject, UIActivityItemSource {
    private let text: String
    private let title: String

    init(text: String, title: String) {
        self.text = text
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { text }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.plainText.identifier
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        return metadata
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
                HStack(spacing: 8) {
                    Text("发件线路：").font(.subheadline).foregroundStyle(.secondary)
                    SMSAccountPicker(recipient: recipient).disabled(sending)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)

                if !suggestions.isEmpty {
                    Divider()
                    contactSuggestions
                }

                Divider()
                Spacer(minLength: 0)
                Divider()
                messageInputBar
            }
            .background(PhoneBackdrop(grouped: false))
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
            .task { await model.contacts.loadIfAuthorized(force: true) }
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
            .task { await model.contacts.loadIfAuthorized(force: true) }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.contacts.isLimitedAccess {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("通讯录为受限访问，只显示已授权联系人；点此选择更多联系人", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.thinMaterial)
                    }
                    .buttonStyle(.plain)
                }
            }
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
            .background(PhoneBackdrop(grouped: false))
            .navigationTitle(L10n.t("通讯录"))
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.t("搜索姓名或号码")
            )
            .refreshable { await model.contacts.requestAccessAndLoad() }
            .task { await model.contacts.loadIfAuthorized(force: true) }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.contacts.isLimitedAccess {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("通讯录为受限访问，只显示已授权联系人；点此选择更多联系人", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.thinMaterial)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private extension View {
    /// iOS 26 起短信输入框使用原生 Liquid Glass；旧系统回退为系统填充色。
    @ViewBuilder
    func smsComposerGlass() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            background(
                Capsule(style: .continuous).fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    func dialCallSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(.green).interactive(), in: Circle())
        } else {
            background(.green, in: Circle())
        }
    }

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
    var glassFallback = false
    var serviceNumber: String? = nil

    private var resolvedFallback: AvatarFallbackContent {
        fallbackContent
            ?? .initial(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
    }

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let serviceNumber, let brand = SMSCarrierBrand.match(serviceNumber) {
                Image(brand.rawValue).resizable().scaledToFit().padding(size * 0.16)
                    .frame(width: size, height: size).background(.white)
            } else {
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    @ViewBuilder private var fallbackBackground: some View {
        if glassFallback {
            if #available(iOS 26.0, *) {
                Circle().fill(.clear)
                    .glassEffect(.regular.tint(Color.indigo.opacity(0.04)), in: Circle())
            } else {
                Circle().fill(.thinMaterial)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.7))
            }
        } else {
            Circle().fill(LinearGradient(colors: [Color(uiColor: .systemGray3), Color(uiColor: .systemGray)],
                startPoint: .top, endPoint: .bottom))
        }
    }

    private var avatarFallback: some View {
        fallbackBackground
            .overlay {
                if glassFallback {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.46), .clear,
                            .black.opacity(0.20), .clear, .white.opacity(0.42)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: size * 0.045
                    )
                    .blur(radius: size * 0.014)
                }
            }
            .overlay {
                switch resolvedFallback {
                case .person:
                    if glassFallback {
                        VStack(spacing: size * 0.07) {
                            Circle().frame(width: size * 0.33, height: size * 0.33)
                            Ellipse().frame(width: size * 0.59, height: size * 0.23)
                        }
                        .foregroundStyle(.white)
                        .offset(y: size * 0.04)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.52, weight: .medium))
                            .foregroundStyle(.white)
                            .offset(y: size * 0.08)
                    }
                case let .initial(initial):
                    Text(initial)
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(.white)
                }
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
    case outgoing
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
        } else if ["active", "held"].contains(state) {
            phase = .connected
            primaryActions = [.end]
            secondaryActions = [.mute, .keypad, .speaker]
            showsDuration = true
        } else {
            phase = .outgoing
            primaryActions = [.end]
            secondaryActions = [.speaker]
            showsDuration = false
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let call: CallRecord
    var isPresented = true
    var onMinimize: (() -> Void)? = nil
    @State private var showingKeypad = false
    @State private var showingAudioRoutes = false
    @State private var enteredDigits = ""

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var content: CallSurfaceContent { CallSurfaceContent(state: call.state) }
    private var formattedNumber: String? {
        guard let raw = call.number else { return nil }
        let digits = raw.filter(\.isNumber)
        let mobile = digits.count == 13 && digits.hasPrefix("86") ? String(digits.dropFirst(2)) : digits
        guard mobile.count == 11, mobile.hasPrefix("1") else { return raw }
        let prefix = digits.count == 13 ? "+86 " : ""
        return prefix + String(mobile.prefix(3)) + " " + String(mobile.dropFirst(3).prefix(4)) + " " + String(mobile.suffix(4))
    }
    private var displayName: String {
        let name = model.contacts.displayName(for: call.number)
        return name == call.number ? formattedNumber ?? name : name
    }
    private var resolvedSlotIndex: Int? {
        if let slot = call.slotIndex, slot >= 0 { return slot }
        // A native/push presentation may not have copied the latest slot yet.
        // Only use a matching active system UUID and presentation identity.
        guard let key = model.deviceCalls.active,
              let route = model.deviceCallRouter.route(for: key),
              model.callLifecycleSnapshot.callID == call.id,
              model.callLifecycleSnapshot.callUUID == route.systemUUID,
              route.presentationCallID == call.id || model.ownedCallUUID(for: call.id) == route.systemUUID,
              let slot = model.deviceCalls.latestEvent(for: key)?.slotIndex, slot >= 0 else { return nil }
        return slot
    }
    private var callSIMLabel: String? {
        guard let slot = resolvedSlotIndex else { return nil }
        let agentID = call.sourceAgentID ?? model.currentAndroidAgent?.id
        if let agentID {
            let live = model.simSlots(for: agentID)
            let slots = live.isEmpty ? model.smsSIMSlots(for: agentID) : live
            if let info = slots.first(where: { $0.slotIndex == slot }) {
                let carrier = info.carrierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return carrier.isEmpty ? "SIM \(slot + 1)" : "SIM \(slot + 1) · \(carrier)"
            }
        }
        return "SIM \(slot + 1)"
    }
    private var contactPhotoData: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }

    var body: some View {
        ZStack {
            CallBackdrop()
            GeometryReader { proxy in
                let wide = PhoneWindowLayout.usesTwoColumns(proxy.size,
                    accessibilitySize: dynamicTypeSize.isAccessibilitySize)
                // The reference uses 88pt circles and 132pt column pitches on
                // a 440pt display. Contact metadata never changes this geometry.
                let size = min(88, proxy.size.width * 0.2)
                if wide {
                    ScrollView {
                        HStack(spacing: 32) {
                            callIdentity.frame(maxWidth: .infinity)
                            controlSurface(size: min(80, size)).frame(maxWidth: .infinity)
                        }
                        .padding(24)
                        .frame(minHeight: proxy.size.height)
                    }
                } else if proxy.size.height >= 760 && !dynamicTypeSize.isAccessibilitySize {
                    phoneSurface(size: size)
                } else {
                    ScrollView {
                        phoneSurface(size: size).frame(minHeight: proxy.size.height)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .overlayPreferenceValue(CallRouteAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if showingAudioRoutes, let anchor {
                    let rect = proxy[anchor]
                    let width = min(CGFloat(250), proxy.size.width - 24)
                    let height = CGFloat(model.audio.callRouteChoices.count) * 36 + 16
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { showingAudioRoutes = false }
                            .accessibilityIdentifier("call.dismissAudioRoutes")
                        CompactCallRouteMenu(audio: model.audio) { showingAudioRoutes = false }
                            .frame(width: width)
                            .offset(x: min(max(12, rect.minX), proxy.size.width - width - 12),
                                    y: max(12, rect.maxY - height))
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
        .onAppear { updateProximityMonitoring() }
        .onChange(of: call.state) { _ in updateProximityMonitoring() }
        .onChange(of: isPresented) { _ in updateProximityMonitoring() }
        .onChange(of: call.id) { _ in showingKeypad = false; showingAudioRoutes = false; enteredDigits = "" }
        .onChange(of: model.audio.speakerEnabled) { _ in updateProximityMonitoring() }
        .onDisappear { UIDevice.current.isProximityMonitoringEnabled = false }
    }

    private func phoneSurface(size: CGFloat) -> some View {
        VStack(spacing: 0) {
            callIdentity.padding(.top, showingKeypad ? 12 : 56)
            Spacer(minLength: 16)
            controlSurface(size: size)
                .padding(.bottom, showingKeypad ? 50 : 32)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var callIdentity: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.50, blue: 0.93))
                    .frame(width: 16, height: 16)
                    .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                Text("AirSIM 音频")
                Text("–")
                if content.showsDuration {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(at: context.date)).monospacedDigit()
                    }
                } else {
                    Text(content.phase == .incoming ? "等待接听" : "正在呼叫")
                }
            }
            .font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            if model.contacts.contact(for: call.number ?? "") != nil {
                HStack(spacing: 12) {
                    InitialAvatar(name: displayName, photoData: contactPhotoData, size: 32)
                    Text(displayName).font(.system(size: 30, weight: .semibold))
                        .lineLimit(2).minimumScaleFactor(0.7)
                }
                if let number = formattedNumber {
                    Text(number).font(.title3.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                }
            } else {
                Text(formattedNumber ?? displayName)
                    .font(.system(size: 32, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.65)
            }
            let details = [callSIMLabel, PhoneRegionLookup.resolvedRegion(number: call.number, androidRegion: call.numberRegion)].compactMap { $0 }.joined(separator: " · ")
            if !details.isEmpty {
                Text(details).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            if showingKeypad, !enteredDigits.isEmpty {
                Text(enteredDigits).font(.title2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("call.enteredDTMF")
            }
            if model.audio.audioHealthWarning != nil { audioStatusBadge }
            if let error = model.audio.errorMessage, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func controlSurface(size: CGFloat) -> some View {
        if content.phase == .incoming {
            HStack(spacing: 48) {
                CallDecisionButton(title: "拒接", icon: "phone.down.fill", color: .red) {
                    Task { await model.reject() }
                }
                CallDecisionButton(title: "接听", icon: "phone.fill", color: .green) {
                    Task { await model.answer() }
                }
            }
        } else if showingKeypad {
            VStack(spacing: 52) {
                VStack(spacing: 19) {
                    ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]], id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(row, id: \.self) { digit in
                                Button {
                                    enteredDigits = String((enteredDigits + digit).suffix(24))
                                    Task { await model.sendDTMF(digit) }
                                } label: {
                                    VStack(spacing: -2) {
                                        Text(digit).font(.system(size: size * 0.455, weight: .regular))
                                        if let letters = ["2":"ABC", "3":"DEF", "4":"GHI", "5":"JKL", "6":"MNO", "7":"PQRS", "8":"TUV", "9":"WXYZ", "0":"+"][digit] {
                                            Text(letters).font(.system(size: 12, weight: .semibold)).tracking(2)
                                        }
                                        if digit == "1" { Color.clear.frame(height: 14) }
                                    }
                                    .frame(width: size, height: size)
                                }
                                .buttonStyle(DTMFGlassButtonStyle())
                                .accessibilityLabel("发送 DTMF \(digit)")
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                HStack(spacing: 0) {
                    if let onMinimize {
                        Button(action: onMinimize) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: size, height: size)
                                .callControlGlass(tint: .white.opacity(0.06), shape: .circle)
                        }
                        .buttonStyle(.plain).accessibilityLabel("收起通话")
                        .accessibilityIdentifier("call.minimize").frame(maxWidth: .infinity)
                    } else {
                        Color.clear.frame(width: size, height: size).frame(maxWidth: .infinity).accessibilityHidden(true)
                    }
                    CallDecisionButton(title: "", icon: "xmark", color: .red, size: size) {
                        Task { await model.hangup() }
                    }.accessibilityLabel("挂断").frame(maxWidth: .infinity)
                    Button("隐藏拨号键盘") { showingKeypad = false }
                        .font(.subheadline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("call.hideKeypad")
                }
            }
        } else {
            VStack(spacing: 24) {
                HStack(spacing: 0) {
                    SpeakerRouteButton(audio: model.audio, size: size, showingRoutes: $showingAudioRoutes)
                        .frame(maxWidth: .infinity)
                    if let onMinimize {
                        CallCircleButton(title: "收起", icon: "arrow.down.right.and.arrow.up.left", color: nil, size: size,
                                         hideFace: showingAudioRoutes, action: onMinimize)
                            .accessibilityLabel("收起通话").accessibilityIdentifier("call.minimize")
                            .frame(maxWidth: .infinity)
                    } else {
                        Color.clear.frame(width: size, height: size + 24).frame(maxWidth: .infinity).accessibilityHidden(true)
                    }
                    CallCircleButton(title: "静音", icon: "mic.slash.fill",
                        color: model.isMuted ? .white : nil, size: size) {
                        Task { await model.toggleMute() }
                    }.disabled(content.phase != .connected)
                        .accessibilityValue(model.isMuted ? "已开启" : "已关闭")
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 0) {
                    Menu {
                        Button(model.isRecording ? "停止录音" : "录音",
                               systemImage: model.isRecording ? "stop.circle" : "record.circle") {
                            Task { await model.toggleRecording() }
                        }.disabled(content.phase != .connected)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: "ellipsis").font(.title2.weight(.semibold))
                                .frame(width: size, height: size)
                                .callControlGlass(tint: .white.opacity(0.06), shape: .circle)
                            Text("更多").font(.system(size: 17))
                        }.foregroundStyle(.white)
                    }.frame(maxWidth: .infinity)
                    CallDecisionButton(title: "结束", icon: "phone.down.fill", color: .red, size: size) {
                        Task { await model.hangup() }
                    }.accessibilityLabel("挂断").frame(maxWidth: .infinity)
                    CallCircleButton(title: "拨号键盘", icon: "circle.grid.3x3.fill", color: nil, size: size) {
                        showingKeypad = true
                    }.disabled(content.phase != .connected).frame(maxWidth: .infinity)
                }
            }
        }
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
        let statusColor = model.audio.receiveOnly ? Color.blue : (model.callAudioIsActive ? Color.green : audioStatusColor)
        return HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.callAudioStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
            if model.audio.audioHealthWarning != nil {
                Button("恢复播放") { model.audio.recoverLocalPlayback() }.font(.caption)
            }
            if model.audio.active, !model.audio.routeDescription.isEmpty {
                Text("· \(model.audio.routeDescription)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 38)
        .callControlGlass(tint: statusColor.opacity(0.10))
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
        let total = max(0, Int(date.timeIntervalSince(model.callConnectedAt ?? date)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func updateProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = isPresented && CallProximityPolicy.shouldMonitor(
            state: call.state,
            speakerEnabled: model.audio.speakerEnabled
        )
    }
}

private struct CallRouteAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct CallRouteMenuGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.04)),
                in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        } else {
            content.background(.ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
    }
}

private struct CompactCallRouteMenu: View {
    @ObservedObject var audio: AudioSessionController
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(audio.callRouteChoices) { route in
                Button {
                    audio.selectCallRoute(route.id)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold))
                            .opacity(route.selected ? 1 : 0).frame(width: 18)
                        Image(systemName: route.icon).font(.system(size: 19)).frame(width: 22)
                        Text(route.title).font(.system(size: 17)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(route.title)
                .accessibilityAddTraits(route.selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .modifier(CallRouteMenuGlass())
    }
}

private struct SpeakerRouteButton: View {
    @ObservedObject var audio: AudioSessionController
    let size: CGFloat
    @Binding var showingRoutes: Bool
    private var icon: String {
        if !audio.hasExternalCallRoutes { return "speaker.wave.2.fill" }
        if audio.callOutputName == "iPhone" { return "iphone" }
        if audio.callOutputName == "扬声器" { return "speaker.wave.2.fill" }
        return audio.callOutputIcon
    }
    private var selected: Bool { audio.speakerEnabled || audio.hasExternalCallRoutes && !["iPhone", "扬声器"].contains(audio.callOutputName) }
    private var face: some View {
        Image(systemName: icon).font(.system(size: 26, weight: .semibold))
            .foregroundStyle(selected ? .black : .white).frame(width: size, height: size)
            .background(Circle().fill(selected ? .white : .clear))
            .callControlGlass(tint: selected ? .white : .white.opacity(0.06), shape: .circle)
    }
    var body: some View {
        VStack(spacing: 7) {
            if audio.hasExternalCallRoutes {
                Button { showingRoutes.toggle() } label: { face.opacity(showingRoutes ? 0 : 1) }
                    .buttonStyle(.plain)
                    .anchorPreference(key: CallRouteAnchorKey.self, value: .bounds) { $0 }
                    .accessibilityLabel("音频输出")
                    .accessibilityIdentifier("call.systemAudioRoute")
            } else {
                Button { audio.toggleSpeakerRoute() } label: { face }
                    .buttonStyle(.plain).accessibilityLabel("音频输出")
                    .accessibilityIdentifier("call.audioRoute")
            }
            Text(audio.changingCallRoute ? "正在切换" : (audio.hasExternalCallRoutes ? "音频" : (audio.callOutputName == "iPhone" ? "听筒" : audio.callOutputName)))
                .font(.system(size: 17)).foregroundStyle(.white)
        }
    }
}

private struct CallDecisionButton: View {
    let title: String
    let icon: String
    let color: Color
    var size: CGFloat = 76
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: title.isEmpty ? 0 : 10) {
                Circle()
                    .fill((color == .red ? Color(red: 0.72, green: 0.12, blue: 0.09) : color).opacity(0.90))
                    .frame(width: size, height: size)
                    .callControlGlass(tint: color.opacity(0.22), shape: .circle)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: icon == "xmark" ? 40 : 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                if !title.isEmpty {
                    Text(title).font(.system(size: 17)).foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: size, height: title.isEmpty ? size : size + 30, alignment: .top)
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
    var hideFace: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Circle().fill(color == nil ? Color.clear : .white)
                    .frame(width: size, height: size)
                    .callControlGlass(tint: color == nil ? .white.opacity(0.06) : .white, shape: .circle)
                    .overlay {
                        Image(systemName: icon).font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(color == nil ? foregroundColor : .black)
                    }
                    .opacity(hideFace ? 0 : 1)
                Text(title)
                    .font(.system(size: 17))
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
            LinearGradient(stops: [
                .init(color: Color(red: 0.13, green: 0.25, blue: 0.40), location: 0),
                .init(color: Color(red: 0.18, green: 0.31, blue: 0.48), location: 0.28),
                .init(color: Color(red: 0.18, green: 0.24, blue: 0.34), location: 0.68),
                .init(color: Color(red: 0.18, green: 0.19, blue: 0.19), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.41, green: 0.28, blue: 0.35).opacity(0.38), .clear],
                center: UnitPoint(x: 0.9, y: 0.48), startRadius: 0, endRadius: 440)
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
                content.glassEffect(.clear.tint(tint).interactive(), in: Circle())
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

private struct DTMFGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.20 : 0.04)))
            .callControlGlass(tint: .white.opacity(0.06), shape: .circle)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


/// Shared presentation only. Callers retain their existing SIM actions.
struct CompactSIMPicker<LabelContent: View>: View {
    let slots: [AndroidSIMSlot]
    let selectedID: String?
    let select: (AndroidSIMSlot) -> Void
    @ViewBuilder let label: () -> LabelContent
    @State private var isPresented = false
    var body: some View {
        Button { isPresented = true } label: { label() }
            .popover(isPresented: $isPresented) {
                CompactSIMSelectionPanel(slots: slots, selectedID: selectedID) { slot in
                    isPresented = false
                    select(slot)
                }.compactSIMPopoverPresentation()
            }
    }
}

struct CompactSIMSelectionPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let slots: [AndroidSIMSlot]
    let selectedID: String?
    var title: String? = nil
    let select: (AndroidSIMSlot) -> Void

    static func title(for slot: AndroidSIMSlot) -> String {
        let card = slot.slotIndex.map { "SIM \($0 + 1)" } ?? slot.label
        if let carrier = slot.carrierName?.trimmingCharacters(in: .whitespacesAndNewlines), !carrier.isEmpty {
            return "\(card) · \(carrier)"
        }
        // The legacy label may already contain its carrier. Never append the
        // full subscriber number or build a second oversized description row.
        return slot.label.isEmpty ? card : slot.label
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            }
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                Button {
                    select(slot)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "simcard").font(.system(size: 16)).foregroundStyle(.tint).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slot.slotIndex.map { "SIM \($0 + 1)" } ?? slot.label)
                                .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            if let carrier = slot.carrierName, !carrier.isEmpty {
                                Text(carrier).font(.caption).foregroundStyle(.secondary)
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tint).opacity(selectedID == slot.id ? 1 : 0)
                    }.padding(.horizontal, 12).padding(.vertical, 4).frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.title(for: slot))
                .accessibilityAddTraits(selectedID == slot.id ? .isSelected : [])
                if index < slots.count - 1 { Divider().padding(.leading, 42).padding(.trailing, 12) }
            }
        }.padding(.vertical, title == nil ? 4 : 0)
            .padding(.bottom, title == nil ? 0 : 4)
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 300 : 232)
    }
    var body: some View {
        if #available(iOS 26.0, *) {
            rows.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            rows.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

extension View {
    @ViewBuilder func compactSIMPopoverPresentation() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover).presentationBackground(.clear)
        } else { self }
    }
}


/// Mainland-China number allocation labels, loaded locally. Never a live location.
enum PhoneRegionLookup {
    struct Table: Sendable {
        let data: Data
        let regions: [String]
        let count: Int
        let recordsOffset: Int
        init?(data: Data) {
            guard data.count >= 16, data.prefix(8) == Data("ASREG001".utf8) else { return nil }
            func u32(_ offset: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) } }
            let count = u32(8), regionCount = u32(12)
            guard count > 0, count <= 800_000, regionCount > 0, regionCount < 10_000 else { return nil }
            var offset = 16
            var names: [String] = []
            for _ in 0..<regionCount {
                guard offset + 2 <= data.count else { return nil }
                let length = data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
                offset += 2
                guard offset + length <= data.count,
                      let name = String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf8) else { return nil }
                names.append(name); offset += length
            }
            guard offset + count * 10 == data.count else { return nil }
            self.data = data; self.regions = names; self.count = count; self.recordsOffset = offset
        }
        func region(for prefix: UInt64) -> String? {
            data.withUnsafeBytes { bytes in
                var low = 0, high = count
                while low < high {
                    let mid = (low + high) / 2, offset = recordsOffset + mid * 10
                    let value = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    if value < prefix { low = mid + 1 } else { high = mid }
                }
                guard low < count else { return nil }
                let offset = recordsOffset + low * 10
                guard UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) == prefix else { return nil }
                let index = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self)))
                return regions.indices.contains(index) ? regions[index] : nil
            }
        }
    }
    static let table: Table? = {
        let url = Bundle.main.url(forResource: "PhoneRegionCN", withExtension: "dat")
            ?? Bundle.main.url(forResource: "PhoneRegionCN", withExtension: "dat", subdirectory: "PhoneRegionResources")
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Table(data: data)
    }()
    static func normalizedCN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+0123456789 -().\u{00a0}")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !trimmed.dropFirst().contains("+") else { return nil }
        var digits = trimmed.filter { $0.isASCII && $0.isNumber }
        let international = trimmed.hasPrefix("+86") || trimmed.hasPrefix("0086")
        if trimmed.hasPrefix("+"), !trimmed.hasPrefix("+86") { return nil }
        if trimmed.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if trimmed.hasPrefix("+86") { digits = String(digits.dropFirst(2)) }
        else if digits.count == 13 && digits.hasPrefix("86") { digits = String(digits.dropFirst(2)) }
        if digits.hasPrefix("400") || digits.hasPrefix("800") { return nil }
        if digits.count == 11, digits.first == "1", let second = digits.dropFirst().first, "3456789".contains(second) { return "86" + digits }
        if digits.hasPrefix("0") { digits.removeFirst() }
        else if !international { return nil }
        guard (9...11).contains(digits.count), digits.hasPrefix("10") || digits.first.map({ "23456789".contains($0) }) == true else { return nil }
        return "86" + digits
    }
    static func region(for raw: String?) -> String? {
        guard let number = normalizedCN(raw), let table else { return nil }
        for length in (4...min(15, number.count)).reversed() {
            if let prefix = UInt64(number.prefix(length)), let region = table.region(for: prefix), region != "中国" { return region }
        }
        return nil
    }
    private static let customerServiceNames = [
        "10000": "中国电信客服",
        "10010": "中国联通客服",
        "10086": "中国移动客服",
        "96789": "中国广电客服",
    ]

    private static func serviceNumber(for raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+0123456789 -().").contains($0) }),
              !value.dropFirst().contains("+") else { return nil }
        var digits = value.filter { $0.isASCII && $0.isNumber }
        if value.hasPrefix("+") {
            guard value.hasPrefix("+86") else { return nil }
            digits = String(digits.dropFirst(2))
        } else if value.hasPrefix("00") {
            guard value.hasPrefix("0086") else { return nil }
            digits = String(digits.dropFirst(4))
        }
        return (5...8).contains(digits.count) ? digits : nil
    }

    static func serviceDescription(for raw: String?) -> String? {
        guard let digits = serviceNumber(for: raw) else { return nil }
        if let name = customerServiceNames[digits] { return name }
        if digits.hasPrefix("95") { return "国内 95 服务号码" }
        if digits.hasPrefix("96") { return "国内 96 服务号码" }
        return nil
    }

    static func systemIncomingTitle(number: String?, callerName: String?) -> String? {
        guard let number = number?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let name = callerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.flatMap { $0.isEmpty || $0 == number ? nil : $0 }
        if let digits = serviceNumber(for: number), let service = customerServiceNames[digits] {
            if let displayName, serviceNumber(for: displayName) != digits { return nil }
            return "\(service) · \(number)"
        }
        guard let region = region(for: number) else { return nil }
        let title = displayName.flatMap { normalizedCN($0) == normalizedCN(number) ? nil : $0 } ?? number
        return "\(title) · \(region)"
    }
    static func systemIncomingTitle(number: String?, callerName: String?, slotIndex: Int?, numberRegion: String? = nil) -> String? {
        let region = resolvedRegion(number: number, androidRegion: numberRegion)
        let name = callerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameNumber = name == number || (normalizedCN(number) != nil && normalizedCN(name) == normalizedCN(number))
        let title = name?.isEmpty == false && !sameNumber ? name! : number
        let sim = slotIndex.flatMap { (0...7).contains($0) ? "SIM \($0 + 1)" : nil }
        if region == nil && sim == nil { return nil }
        return [title, sim, region].compactMap { $0 }.joined(separator: " · ")
    }
    static func resolvedRegion(number: String?, androidRegion: String?) -> String? {
        if let text = androidRegion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, text.count <= 80, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return text }
        return serviceDescription(for: number) ?? region(for: number)
    }
    static func infoLine(number: String?, slotIndex: Int?, fallbackSIM: String? = nil, androidRegion: String? = nil) -> String? {
        let region = resolvedRegion(number: number, androidRegion: androidRegion)
        let slot = slotIndex.flatMap { $0 >= 0 ? "SIM \($0 + 1)" : nil }
        if let region { return [slot, region].compactMap { $0 }.joined(separator: " · ") }
        return slot ?? fallbackSIM
    }
}

/// Push checks describe prerequisites, never claim an APNs delivery was proven.
private struct AgentPushSMSPills: View {
    let agentID: String
    let vowlanOnline: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CloudSignalingPreference.key) private var pushEnabled = true
    @State private var pushText = "推送未检查"
    @State private var pushColor: Color = .secondary
    @State private var encryptionText = "短信未检查"
    @State private var encryptionColor: Color = .secondary
    private struct Query: Equatable {
        let agentID: String
        let online: Bool
        let active: Bool
        let pushEnabled: Bool
    }

    var body: some View {
        HStack(spacing: 6) {
            pill(pushText, color: pushColor)
            pill(encryptionText, color: encryptionColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("通过 VoWLAN 查询已配对安卓保存的推送配置。完整推送自检见设置中的「帮助与诊断 → 诊断与修复」。")
        .task(id: Query(agentID: agentID, online: vowlanOnline, active: scenePhase == .active, pushEnabled: pushEnabled)) {
            guard scenePhase == .active else { return }
            await refresh()
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    @MainActor private func refresh() async {
        do {
            if let record = try KeychainE2EKeyStore.shared.record(agentID: agentID) {
                let valid = record.key.count == 32 && !record.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                encryptionText = valid ? "短信已加密" : "短信密钥异常"
                encryptionColor = valid ? .green : .orange
            } else {
                encryptionText = "短信未协商"; encryptionColor = .secondary
            }
        } catch E2EKeyStoreError.locked {
            encryptionText = "加密待解锁"; encryptionColor = .secondary
        } catch {
            encryptionText = "短信密钥不可用"; encryptionColor = .orange
        }
        guard CloudSignalingPreference.isEnabled(), !RelayEgressGate.shared.isBlocked else {
            pushText = "推送已关闭"; pushColor = .secondary; return
        }
        pushText = "正在查询推送配置"; pushColor = .secondary
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard !Task.isCancelled else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral else {
            pushText = "推送未授权"; pushColor = .orange; return
        }
        guard PairedAndroidDeviceStore.records().contains(where: { $0.id == agentID }),
              let api = model.localDevices.api(for: agentID) else {
            pushText = "推送配置待查询"; pushColor = .secondary; return
        }
        do {
            let status = try await api.pushStatus()
            guard !Task.isCancelled else { return }
            if !status.configured || status.localMode == true || status.cloudModeEnabled == false {
                pushText = "安卓推送未配置"; pushColor = .orange
            } else if status.callPushReady && status.messagePushReady {
                pushText = "安卓推送已配置"; pushColor = .green
            } else {
                pushText = "安卓推送配置不全"; pushColor = .orange
            }
        } catch {
            guard !Task.isCancelled else { return }
            pushText = "推送配置查询失败"; pushColor = .orange
            PushDiagnostics.record("设置页直连查询推送配置失败", error: error)
        }
    }
}
