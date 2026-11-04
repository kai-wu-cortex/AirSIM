import SwiftUI
import UIKit
import UserNotifications

/// AirSIM 只引导 Android 配对；不检查旧模块固件或网络。
struct AirSIMFirstConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("airsim.first-connection-complete") private var completed = false
    @AppStorage(ConnectionModePreference.key) private var connectionModeRaw = ConnectionModePreference.selected().rawValue
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 76, height: 76)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))

                VStack(alignment: .leading, spacing: 8) {
                    Text("连接安卓手机")
                        .font(.largeTitle.bold())
                    Text("AirSIM 可通过 VoWLAN、蓝牙或云端 Relay 独立连接 Android 手机。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Label("在 Android 手机启动 AirSIM 和音频桥", systemImage: "1.circle.fill")
                    Label(selectedMode == .bluetooth ? "打开两台设备的蓝牙" : "按所选模式准备网络或蓝牙", systemImage: "2.circle.fill")
                    Label("核对配对安全码并完成认证", systemImage: "3.circle.fill")
                }
                .font(.body.weight(.medium))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

                Picker("连接模式", selection: $connectionModeRaw) {
                    ForEach(AirSIMConnectionMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: connectionModeRaw) { rawValue in
                    guard let mode = AirSIMConnectionMode(rawValue: rawValue) else { return }
                    model.setConnectionMode(mode)
                }
                Text(selectedMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("开始配对", systemImage: "lock.shield") {
                    showingPairing = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                if selectedMode == .localDual {
                    NavigationLink("添加蓝牙设备") { VoBLEPairingView().environmentObject(model) }
                        .frame(maxWidth: .infinity)
                }

                Button("稍后在设置中配对") { completed = true }
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("AirSIM")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPairing, onDismiss: {
                if model.vowlan.availability.isOnlineForDisplay || model.voble.state == .ready { completed = true }
            }) {
                NavigationStack {
                    Group {
                        if selectedMode == .bluetooth {
                            VoBLEPairingView()
                        } else {
                            SamsungPairingView()
                        }
                    }
                        .environmentObject(model)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showingPairing = false }
                            }
                        }
                }
            }
        }
    }

    private var selectedMode: AirSIMConnectionMode {
        AirSIMConnectionMode(rawValue: connectionModeRaw) ?? .automatic
    }
}

#Preview("已配对设备 · 空列表") {
    Form { Section("安卓连接") { PairedAndroidDeviceRows(devices: [], onDelete: { _ in }) } }
}

#Preview("已配对设备 · 在线与离线") {
    Form {
        Section("安卓连接") {
            PairedAndroidDeviceRows(devices: [
                .init(id: "preview-flip", deviceName: "Samsung Flip7", phoneNumber: "+10000000001",
                      agentKind: "standalone", cloudOnline: false, vowlanOnline: false,
                      bluetoothOnline: true, isCurrent: true),
                .init(id: "preview-vivo", deviceName: "vivo X60", phoneNumber: nil,
                      agentKind: "standalone", cloudOnline: false, vowlanOnline: false, isCurrent: false)
            ], onDelete: { _ in })
        }
    }
}

private struct PairedAndroidDeviceRows: View {
    let devices: [AndroidAgentPresentation]
    let onDelete: (AndroidAgentPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已配对设备").font(.subheadline.weight(.semibold))
            if devices.isEmpty {
                Text("暂无配对记录").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.deviceName).font(.subheadline.weight(.medium))
                        Text(device.phoneNumber ?? "号码未提供").font(.caption).foregroundStyle(.secondary)
                        Text(connectionText(device)).font(.caption2).foregroundStyle(.secondary)
                        if let pairing = VoWLANPairingRecordStore.records()
                            .first(where: { $0.agentID == device.id }) {
                            Text("本机配对记录 · \(pairing.id.prefix(8)) · \(pairing.endpoints.count) 个地址")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(role: .destructive) { onDelete(device) } label: {
                        Image(systemName: "trash").padding(10)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("删除 \(device.deviceName) 配对记录")
                }
            }
            Text("重连时重新读取当前信息，离线记录不保存号码。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func connectionText(_ device: AndroidAgentPresentation) -> String {
        let routes = [device.vowlanOnline ? "VoWLAN 在线" : nil,
                      device.bluetoothOnline ? "VoBLE 在线" : nil,
                      device.cloudOnline ? "云端在线" : nil].compactMap { $0 }
        return routes.isEmpty ? "离线 · 下次连接重新读取" : routes.joined(separator: " · ")
    }
}

private struct PureLocalSlideControl: View {
    let enabled: Bool
    let busy: Bool
    let blockedByCall: Bool
    let action: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @GestureState private var dragTranslation: CGFloat = 0
    @Namespace private var glassNamespace

    private var isInteractive: Bool { !busy && !blockedByCall }
    private var title: String {
        if busy { return "正在切换连接策略" }
        if blockedByCall { return "通话中不可切换" }
        return enabled ? "纯本地模式已开启" : "滑动开启纯本地模式"
    }

    private var statusText: String { enabled ? "仅本地连接 · 云端已停用" : "按连接偏好运行" }
    private var tint: Color { enabled ? .green : .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: enabled ? "network.badge.shield.half.filled" : "network")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                else {
                    Text(enabled ? "已开启" : "已关闭")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(enabled ? Color.green : Color.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background((enabled ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
                }
            }

            // Keep instructions above the glass surface so material blending
            // and the moving thumb cannot obscure them in either appearance.
            slideInstruction

            GeometryReader { proxy in
                let knob: CGFloat = 48
                let inset: CGFloat = 4
                let travel = max(1, proxy.size.width - knob - inset * 2)
                let directionalDrag = enabled ? -dragTranslation : dragTranslation
                let progress = min(1, max(0, directionalDrag / travel))
                let restingOffset = enabled ? travel : 0
                let movingOffset = enabled ? restingOffset - progress * travel : progress * travel

                Group {
                    if #available(iOS 26.0, *), !reduceTransparency {
                        GlassEffectContainer(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(.clear)
                                    .glassEffect(
                                        .regular.tint(tint.opacity(0.12)),
                                        in: .capsule
                                    )
                                    .glassEffectID("pure-local-track", in: glassNamespace)

                                sliderThumb(knob: knob)
                                    .glassEffect(
                                        .regular.tint(tint.opacity(enabled ? 0.72 : 0.58)).interactive(),
                                        in: .circle
                                    )
                                    .glassEffectID("pure-local-thumb", in: glassNamespace)
                                    .offset(x: inset + movingOffset)
                            }
                        }
                    } else {
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(reduceTransparency ? AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)) : AnyShapeStyle(.ultraThinMaterial))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .fill(tint.opacity(0.12))
                                }
                            sliderThumb(knob: knob)
                                .background(tint, in: Circle())
                                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                                .offset(x: inset + movingOffset)
                        }
                    }
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .updating($dragTranslation) { value, state, _ in
                            guard isInteractive else { return }
                            state = value.translation.width
                        }
                        .onEnded { value in
                            guard isInteractive else { return }
                            let distance = enabled ? -value.translation.width : value.translation.width
                            guard distance >= travel * 0.78 else { return }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            action(enabled)
                        }
                )
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.32, dampingFraction: 0.82), value: dragTranslation)
            }
            .frame(height: 56)
        }
        .padding(.vertical, 4)
        .opacity(isInteractive ? 1 : 0.62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("纯本地模式")
        .accessibilityValue("\(enabled ? "已开启" : "已关闭")，\(statusText)")
        .accessibilityHint(blockedByCall ? "结束通话后可以切换" : (enabled ? "双击关闭纯本地模式" : "双击开启纯本地模式"))
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .accessibilityAction {
            guard isInteractive else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action(enabled)
        }
        .accessibilityIdentifier("pureLocalModeSlider")
    }

    private var slideInstruction: some View {
        Text(busy ? "正在切换，请稍候" : blockedByCall ? "请先结束当前通话" : (enabled ? "向左滑动关闭" : "向右滑动开启"))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
    }

    private func sliderThumb(knob: CGFloat) -> some View {
        Circle()
            .fill(.clear)
            .frame(width: knob, height: knob)
            .overlay {
                if busy { ProgressView().tint(.white) }
                else {
                    Image(systemName: enabled ? "chevron.left.2" : "chevron.right.2")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }
}

private struct RemoteDirectSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var agentID = ""
    @State private var enabled = false
    @State private var host = ""
    @State private var controlPort = "443"
    @State private var pcmPort = "7593"
    @State private var message = ""
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                RemoteDirectGuideEntry(context: .existingDevice)
            }

            Section {
                Picker("已配对设备", selection: $agentID) {
                    Text("选择安卓手机").tag("")
                    ForEach(model.pairedDeviceHistory) { device in
                        Text(device.deviceName).tag(device.id)
                    }
                }
                Toggle("启用自建域名直连", isOn: $enabled)
                    .disabled(agentID.isEmpty)
            } footer: {
                Text("试验性功能，真实公网配对与双向音频仍待真机验收。为已通过私网或公网域名配对的手机配置 NAS 或软路由加密入口。验证后保存，不会自动开启 Relay。")
            }
            .disabled(saving || model.vowlan.callInProgress() || model.activeCall != nil || model.remoteCall != nil || model.pendingOutgoingCall != nil)
            if enabled {
                Section("远程入口") {
                    TextField("DDNS 域名，例如 phone.example.com", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("HTTPS 控制端口", text: $controlPort).keyboardType(.numberPad)
                    TextField("TLS 音频端口", text: $pcmPort).keyboardType(.numberPad)
                }
                .disabled(saving || model.vowlan.callInProgress() || model.activeCall != nil || model.remoteCall != nil || model.pendingOutgoingCall != nil)
            }
            Section {
                Button(enabled ? "验证并保存" : "保存关闭") {
                    saving = true
                    let target = agentID
                    saveTask = Task { @MainActor in
                        defer { saving = false }
                        do {
                            let route = enabled ? try RemoteDirectConfiguration.route(agentID: target,
                                host: host, controlPort: controlPort, pcmPort: pcmPort) : nil
                            try await model.configureRemoteDirect(agentID: target, route: route)
                            message = route == nil ? "已关闭此设备的自建域名直连。" :
                                "控制入口与设备身份验证通过，已保存。音频入口需在实际通话时验证。"
                        } catch is CancellationError {
                            message = "配置已取消，请重新验证。"
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(agentID.isEmpty || saving || model.vowlan.callInProgress() || model.activeCall != nil || model.remoteCall != nil || model.pendingOutgoingCall != nil)
                if saving { ProgressView("正在验证远程设备…") }
                if !message.isEmpty { Text(message).font(.footnote) }
            } footer: {
                Text("选择 VoWLAN 或自动模式后，局域网优先，不可达时尝试自建域名。NAS 需为控制与音频分别提供有效证书的 TLS 转发；只有网页反向代理不足以传输音频。此选项不提供后台来电推送，通话中不能更改。")
            }
        }
        .navigationTitle("自建域名直连（试验性）")
        .onAppear {
            if agentID.isEmpty { agentID = model.pairedDeviceHistory.first?.id ?? "" }
            load()
        }
        .onChange(of: agentID) { _ in load() }
        .onDisappear { saveTask?.cancel() }
    }

    private func load() {
        let route = VoWLANManualRouteStore.routes().first { $0.agentID == agentID && $0.isRemote }
        enabled = route != nil
        host = route?.host ?? ""
        controlPort = route.map { String($0.controlPort) } ?? "443"
        pcmPort = route.map { String($0.pcmPort) } ?? "7593"
        message = ""
    }
}

/// Typed navigation keeps drafts in the settings owner while details come and go.
enum AirSIMSettingsPage: Hashable, Identifiable {
    case home, local, connections, mode, add, pairAuto, pairManual, pairDomain
    case device(String), deviceInfo(String)
    case status, network, prefixes, bluetooth, bluetoothPair, bluetoothStatus, relay, tls, tlsGuide
    case calls, background, forwarding, widgets, order, widgetGuide, islandGuide
    case preferences, accessibility, help, diagnostics, localCheck, cloudCheck, permissions
    case logs, feedback, feedbackPreview, guide, networkGuide, about

    var id: String {
        switch self {
        case .device(let id): return "device-\(id)"
        case .deviceInfo(let id): return "deviceInfo-\(id)"
        default: return String(describing: self)
        }
    }
    var title: String {
        switch self {
        case .home: return "设置"
        case .local: return "纯本地模式"
        case .connections: return "连接与设备"
        case .mode: return "通话连接方式"
        case .add: return "添加设备"
        case .pairAuto: return "自动发现配对"
        case .pairManual: return "手动地址配对"
        case .pairDomain: return "公网域名配对"
        case .device: return "设备详情"
        case .deviceInfo: return "地址与配对信息"
        case .status: return "当前连接详情"
        case .network: return "局域网与 VPN"
        case .prefixes: return "自定义私有网段"
        case .bluetooth: return "蓝牙连接"
        case .bluetoothPair: return "蓝牙配对"
        case .bluetoothStatus: return "蓝牙链路状态"
        case .relay: return "云端 Relay"
        case .tls: return "公网域名直连"
        case .tlsGuide: return "域名直连教程"
        case .calls: return "来电与短信"
        case .background: return "后台运行"
        case .forwarding: return "通知转发"
        case .widgets: return "灵动岛与小组件"
        case .order: return "设备显示顺序"
        case .widgetGuide: return "桌面小组件"
        case .islandGuide: return "锁屏与灵动岛"
        case .preferences: return "外观与偏好"
        case .accessibility: return "语言与辅助功能"
        case .help: return "帮助与诊断"
        case .diagnostics: return "检查连接"
        case .localCheck: return "本地连接检查"
        case .cloudCheck: return "云端连接自检"
        case .permissions: return "系统权限"
        case .logs: return "详细日志与技术信息"
        case .feedback: return "提交反馈"
        case .feedbackPreview: return "上传内容范围"
        case .guide: return "使用指南"
        case .networkGuide: return "连接准备与排障"
        case .about: return "关于 AirSIM"
        }
    }
}

enum AirSIMSettingsPolicy {
    static func canSelect(_ mode: AirSIMConnectionMode, pureLocal: Bool, callBusy: Bool) -> Bool {
        !callBusy && !(pureLocal && mode == .cloud)
    }

    /// Accept existing self-hosted HTTP deployments as well as HTTPS. Never
    /// silently replace invalid input with the maintainer's default Relay.
    static func validRelayURL(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return value
    }
}


/// Only visible home values participate in diffing. PCM counters, history updates
/// and unrelated AppModel publications do not invalidate the scrolling sections.
struct AirSIMSettingsHomeSnapshot: Equatable {
    let deviceID: String?
    let deviceName: String
    let connectionDetail: String
    let modeTitle: String
    let version: String
    let pureLocalEnabled: Bool
    let pureLocalBusy: Bool
    let callBusy: Bool
    let pureLocalError: String?
    let language: String
}

private struct AirSIMSettingsLink: View {
    let page: AirSIMSettingsPage
    let icon: String
    var detail: String? = nil

    var body: some View {
        NavigationLink(value: page) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(.blue).frame(width: 26)
            }
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("settings.link.\(page.id)")
    }
}

// Keep the Form inside the equality boundary so its Sections retain native
// row identity, hit testing and value-based navigation registration.
private struct AirSIMSettingsHomeContent: View, Equatable {
    let snapshot: AirSIMSettingsHomeSnapshot
    // This binding addresses stable owner state, not a closure capturing an old
    // model snapshot. The owner rechecks live call/busy state before any action.
    @Binding var requestedPureLocalMode: Bool?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }

    private func link(_ page: AirSIMSettingsPage, _ icon: String, detail: String? = nil) -> some View {
        AirSIMSettingsLink(page: page, icon: icon, detail: detail)
    }

    var body: some View {
        Form {
            Section {
                PureLocalSlideControl(enabled: snapshot.pureLocalEnabled,
                    busy: snapshot.pureLocalBusy, blockedByCall: snapshot.callBusy) { current in
                    requestedPureLocalMode = !current
                }
                NavigationLink("了解纯本地模式", value: AirSIMSettingsPage.local)
                    .font(.footnote)
                if let error = snapshot.pureLocalError { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                if let deviceID = snapshot.deviceID {
                    NavigationLink(value: AirSIMSettingsPage.device(deviceID)) {
                        Label {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(snapshot.deviceName).font(.headline)
                                Text(snapshot.connectionDetail)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.blue) }
                        .padding(.vertical, 6)
                    }
                } else {
                    link(.add, "iphone.badge.plus", detail: "连接你的安卓手机或 U30 Air")
                }
            }
            Section {
                link(.connections, "antenna.radiowaves.left.and.right", detail: snapshot.modeTitle)
                link(.calls, "phone", detail: "来电通知、短信与转发")
                link(.widgets, "rectangle.on.rectangle", detail: "桌面与锁屏展示")
                link(.preferences, "paintpalette")
            }
            Section {
                link(.help, "questionmark.circle")
                link(.about, "info.circle", detail: snapshot.version)
            }
        }
    }
}

struct AirSIMSettingsView: View {
    private enum SelfTestPhase {
        case idle
        case running
        case completed
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appUpdates: AppUpdateController
    @Environment(\.scenePhase) private var updateScenePhase
    @State private var appUpdatePresentation: AppUpdatePresentation?
    @State private var appUpdateInbox = AppUpdateResultInbox()
    @State private var updateViewVisible = false
    @AppStorage(ConnectionModePreference.key) private var connectionModeRaw = ConnectionModePreference.selected().rawValue
    @AppStorage(CloudSignalingPreference.key) private var cloudSignalingEnabled = CloudSignalingPreference.isEnabled()
    @AppStorage(BackgroundStandbyPreference.key) private var backgroundStandbyEnabled = false
    @AppStorage(LiveActivityVisibilityPreference.key) private var liveActivityEnabled = true
    @AppStorage(SMSVerificationCodeClipboard.enabledKey) private var autoCopySMSCode = true
    @AppStorage(FeedbackUploader.descriptionKey) private var feedbackDescription = ""
    @AppStorage(FeedbackUploader.remarkKey) private var feedbackRemark = ""
    @State private var feedbackUploadStatus = ""
    @State private var feedbackUploading = false
    @State private var relayURL = RelayConfiguration.effectiveURL(
        stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"),
        buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
        bundleID: Bundle.main.bundleIdentifier
    )
    @State private var message: String?
    @State private var selfTestPhase: SelfTestPhase = .idle
    @State private var selfTestReport: CloudSelfTestReport?
    @State private var selfTestTask: Task<Void, Never>?
    @State private var deletingDevice: AndroidAgentPresentation?
    @State private var deviceDeletionInProgress = false
    @State private var deviceDeletionError: String?
    @State private var networkPrefixesText = NetworkRoutePreferences.storedText()
    @State private var networkPrefixError: String?
    @AppStorage(RelayEgressGate.persistenceKey) private var pureLocalEnabled = false
    @State private var pureLocalBusy = false
    @State private var pureLocalError: String?
    @State private var requestedPureLocalMode: Bool?
    @State private var diagnosticCloudOnline: Bool?
    @FocusState private var networkPrefixesFocused: Bool
    @FocusState private var feedbackFocusedField: FeedbackFocusedField?

    private enum FeedbackFocusedField: Hashable {
        case description
        case remark
    }

    @State private var path: [AirSIMSettingsPage] = []
    @State private var localCheckRunning = false
    @State private var localCheckDate: Date?
    @State private var localCheckStatus: String?
    @State private var notificationPermission = "正在读取"
    @State private var relaySaving = false
    @State private var selfTestCopied = false

    var body: some View {
        NavigationStack(path: $path) {
            settingsForm(.home)
                .navigationDestination(for: AirSIMSettingsPage.self) { page in
                    destination(page)
                }
        }
        // Keep lifecycle ownership outside the root Form: pushing a detail must
        // not cancel a diagnostic or discard the user's pending update result.
        .task { await model.refreshPairedDeviceInformation() }
        .fullScreenCover(item: $appUpdatePresentation, onDismiss: presentManualAppUpdateIfIdle) { presentation in
            AppUpdateSheet(presentation: presentation, updates: appUpdates)
        }
        .onAppear { updateViewVisible = true; presentManualAppUpdateIfIdle() }
        .onChange(of: requestedPureLocalMode) { requested in
            guard let requested else { return }
            requestedPureLocalMode = nil
            Task { @MainActor in await setPureLocalMode(requested) }
        }
        .onChange(of: model.activeCall?.id) { _ in handleUpdateCallChange() }
        .onChange(of: model.remoteCall?.id) { _ in handleUpdateCallChange() }
        .onChange(of: model.pendingOutgoingCall?.id) { _ in handleUpdateCallChange() }
        .onChange(of: updateScenePhase) { phase in
            presentManualAppUpdateIfIdle()
            if phase == .active { Task { await readNotificationPermission() } }
        }
        .onChange(of: model.errorMessage) { _ in presentManualAppUpdateIfIdle() }
        .confirmationDialog("忘记这个设备？",
            isPresented: Binding(get: { deletingDevice != nil }, set: { if !$0 { deletingDevice = nil } }),
            titleVisibility: .visible, presenting: deletingDevice) { device in
            Button("忘记 \(device.deviceName)", role: .destructive) {
                deviceDeletionInProgress = true
                Task {
                    defer { deviceDeletionInProgress = false }
                    do {
                        try await model.forgetAndroidDevice(device.id)
                        if case .device = path.last { path.removeLast() }
                    } catch { deviceDeletionError = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("清除本机配对和缓存，不删除手机系统短信与通话记录。重新使用需要配对；离线设备上的远端凭据不会自动撤销。")
        }
        .onDisappear {
            updateViewVisible = false
            selfTestTask?.cancel()
            selfTestTask = nil
            if selfTestPhase == .running { selfTestPhase = .idle }
        }
    }

    @ViewBuilder
    private func destination(_ page: AirSIMSettingsPage) -> some View {
        switch page {
        case .pairAuto: SamsungPairingView(initialMethod: .automatic)
        case .pairManual: SamsungPairingView(initialMethod: .privateIP)
        case .pairDomain: SamsungPairingView(initialMethod: .publicDomain)
        case .bluetoothPair: VoBLEPairingView()
        case .tls: RemoteDirectSettingsView()
        case .tlsGuide: RemoteDirectGuideView(context: .firstPairing, embedded: true)
        case .forwarding: NotificationForwardingView()
        case .logs: AgentVerboseTraceView(api: model.verboseDiagnosticsAPI)
        default: settingsForm(page)
        }
    }

    private func settingsForm(_ page: AirSIMSettingsPage) -> some View {
        Group {
            if page == .home {
                AirSIMSettingsHomeContent(snapshot: homeSnapshot,
                    requestedPureLocalMode: $requestedPureLocalMode).equatable()
            } else {
                Form { pageContent(page) }
            }
        }
            .formStyle(.grouped)
            .settingsSoftScrollEdge()
            .scrollDismissesKeyboard(.interactively)

            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(page == .home ? .large : .inline)
            .accessibilityIdentifier("settings.page.\(page.id)")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { feedbackFocusedField = nil; networkPrefixesFocused = false }
                }
            }
    }

    private func link(_ page: AirSIMSettingsPage, _ icon: String, detail: String? = nil) -> some View {
        AirSIMSettingsLink(page: page, icon: icon, detail: detail)
    }

    @ViewBuilder
    private func pageContent(_ page: AirSIMSettingsPage) -> some View {
        switch page {
        case .home:
            EmptyView() // The home Form owns its value-based update boundary.
        case .local:
            Section { pureLocalControl }
            Section("开启后") {
                Label("仅通过 VoWLAN、蓝牙或 VPN 直连", systemImage: "checkmark.shield")
                Label("阻止 AirSIM 云端通知、Relay 与反馈上传", systemImage: "cloud.slash")
                Text("本地链路不可用时不会回退到 Relay。GitHub 版本检查不受影响，安卓第三方通知转发仍由其独立设置控制。")
                Text("安卓离线时不能确认跨端策略已同步，重连后请核对安卓状态。")
            }
        case .connections:
            Section { link(.mode, "arrow.triangle.branch", detail: selectedMode.title) }
            deviceListSection
            Section { link(.status, "waveform.path.ecg") }
        case .mode:
            Section {
                ForEach(AirSIMConnectionMode.allCases) { mode in
                    Button { selectMode(mode) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: modeIcon(mode)).frame(width: 24).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title).foregroundStyle(.primary)
                                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if selectedMode == mode { Image(systemName: "checkmark").foregroundStyle(.blue) }
                        }.padding(.vertical, 6)
                    }
                    .disabled(!AirSIMSettingsPolicy.canSelect(mode, pureLocal: pureLocalEnabled, callBusy: updateCallBusy))
                    .accessibilityIdentifier("settings.mode.\(mode.rawValue)")
                    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                }
            } footer: {
                Text(updateCallBusy ? "通话结束后可切换。" : pureLocalEnabled
                    ? "纯本地已开启，自动模式只尝试本地链路。" : "这是连接偏好，实际链路以设备状态为准；不影响手动云端自检。")
            }
        case .add:
            Section {
                Text("先在安卓 AirSIM 打开一次性配对窗口，再选择连接方式。")
                link(.pairAuto, "wifi", detail: "同一 Wi-Fi 或安卓热点")
                link(.pairManual, "network", detail: "手动 IP、Tailscale 或其他 VPN")
                link(.bluetoothPair, "wave.3.right", detail: "在两端核对安全码")
                link(.pairDomain, "lock.shield", detail: "试验性 · 需要可信 TLS 证书")
            }
        case .device(let id): deviceSections(id)
        case .deviceInfo(let id): deviceInformation(id)
        case .status: connectionStatusSection
        case .network:
            Section {
                LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                Button("重新发现与验证", systemImage: "arrow.clockwise") { checkLocalConnection() }
                    .disabled(localCheckRunning || updateCallBusy)
                if localCheckRunning { ProgressView("正在检查直连网关…") }
                if let localCheckStatus { Text(localCheckStatus).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                link(.pairManual, "network")
                link(.prefixes, "slider.horizontal.3", detail: "特殊内网才需要修改")
                link(.networkGuide, "book")
            }
        case .prefixes: networkPrefixesSection
        case .bluetooth:
            bluetoothSection
            Section { link(.bluetoothStatus, "waveform.path.ecg") }
        case .bluetoothStatus:
            Section { LabeledContent("连接状态", value: voBLEStatus) }
            bluetoothDiagnosticsSection
            Section {
                Text("这些是当前蓝牙状态，不是一次完整通话测试。控制认证通过不代表音频已经实测。")
                link(.bluetoothPair, "wave.3.right")
                link(.permissions, "hand.raised")
            }
        case .relay: relaySections
        case .calls:
            Section {
                Toggle(isOn: Binding(get: { !pureLocalEnabled && cloudSignalingEnabled }, set: {
                    cloudSignalingEnabled = $0
                    model.setCloudSignalingEnabled($0)
                })) { Label("云端通知", systemImage: "bell") }
                    .disabled(pureLocalEnabled || pureLocalBusy)
                    .accessibilityIdentifier("cloudSignaling")
            } footer: {
                Text(pureLocalEnabled ? "纯本地模式已阻止云端通知，关闭后恢复原偏好。" : "用于后台来电通知，不改变通话的音频连接方式。")
            }
            smsSection
            Section {
                link(.background, "moon")
                link(.permissions, "hand.raised")
                link(.forwarding, "paperplane", detail: "安卓向第三方发送通知")
            }
        case .background: backgroundSection
        case .widgets:
            liveActivitySection
            Section {
                link(.order, "arrow.up.arrow.down")
                link(.widgetGuide, "rectangle.on.rectangle")
                link(.islandGuide, "platter.filled.top.iphone")
            }
        case .order:
            if model.liveActivityOrderedAgents.isEmpty {
                Section { Text("配对设备后可以调整显示顺序。").foregroundStyle(.secondary); link(.add, "plus.circle") }
            } else { deviceOrderSection }
        case .preferences:
            Section {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
            }
            Section { link(.accessibility, "accessibility") }
        case .help:
            Section { link(.diagnostics, "stethoscope", detail: "本地、蓝牙与云端状态"); link(.permissions, "hand.raised") }
            Section { link(.logs, "doc.text.magnifyingglass"); link(.feedback, "bubble.left.and.bubble.right") }
            Section { link(.guide, "book") }
        case .diagnostics:
            Section {
                link(.localCheck, "wifi")
                link(.bluetoothStatus, "wave.3.right")
                link(.cloudCheck, "cloud", detail: pureLocalEnabled ? "纯本地模式下不可运行" : nil)
            }
        case .localCheck:
            Section {
                Button("检查本地连接", systemImage: "stethoscope") { checkLocalConnection() }
                    .disabled(localCheckRunning || updateCallBusy)
                if localCheckRunning { ProgressView("正在验证网关…") }
                if let localCheckStatus {
                    Text(localCheckStatus)
                    if let localCheckDate { Text(localCheckDate, style: .time).font(.caption).foregroundStyle(.secondary) }
                } else { Text("点击后验证已配对网关，不拨号或读取音频。").foregroundStyle(.secondary) }
            }
            Section {
                Text(updateCallBusy ? "通话结束后可重新检查连接。" : "网关验证仅确认控制链路，PCM 双向音频需要通话实测。")
                link(.network, "wifi"); link(.permissions, "hand.raised"); link(.logs, "doc.text")
            }
        case .cloudCheck:
            cloudSelfTestSection
            if selfTestPhase == .completed, selfTestReport?.allPassed == false {
                Section("接下来") {
                    link(.relay, "cloud")
                    link(.permissions, "hand.raised")
                    link(.logs, "doc.text.magnifyingglass")
                }
            }
        case .permissions: permissionSections
        case .feedback:
            feedbackSection
            Section { link(.feedbackPreview, "hand.raised") }
        case .feedbackPreview:
            Section("手动上传的范围") {
                Text("上传应用与系统版本、设备型号、连接状态、诊断记录及可读取的安卓日志。")
                Text("不会录制或上传通话音频。请勿在描述和备注中粘贴密码、验证码、配对密钥或其他个人信息。")
                Text("日志处理与原始 TXT 导出是不同流程；原始导出请先检查内容，再分享。")
            }
            Section("你的文字") {
                Text(feedbackDescription.isEmpty ? "未填写描述" : feedbackDescription).textSelection(.enabled)
                Text(feedbackRemark.isEmpty ? "未填写备注" : feedbackRemark).textSelection(.enabled)
            }
            Section { Text("只有点按“上传反馈”才会提交；失败保留草稿。本页只展示上传范围，不是服务器实际接收内容的完整预览。").font(.footnote) }
        case .about: aboutSection
        case .guide:
            Section {
                link(.add, "iphone.badge.plus")
                link(.networkGuide, "network")
                link(.tlsGuide, "lock.shield")
                link(.background, "moon")
                link(.widgetGuide, "rectangle.on.rectangle")
            }
        case .networkGuide:
            guideSection("局域网与热点", steps: ["两台设备连接同一 Wi-Fi，或让 iPhone 连接安卓热点。", "安卓开启一次性配对窗口；自动发现不可用时，使用安卓的 IP 与当前配对端口。", "配对身份验证与音频准备是不同步骤。网关已认证后仍需实测通话。"])
            guideSection("Tailscale 与其他 VPN", steps: ["两端加入同一隧道，并允许相互访问。", "填写安卓在 VPN 内的地址，不是 iPhone 的地址。配对端口和控制、音频端口均需可达。", "Tailscale 的 100.64/10 已内置支持，无需打开 AirSIM 云端通话。"])
            Section { link(.pairManual, "network"); link(.localCheck, "stethoscope") }
        case .widgetGuide:
            guideSection("添加小组件", steps: ["长按主屏幕空白处，选择编辑 → 添加小组件。", "搜索 AirSIM，选取尺寸并添加。", "大尺寸的最近通话和短信每栏最多显示 5 条；中尺寸按空间显示摘要。", "设备与模式按钮可在小组件内切换；记录入口打开对应内容。"])
            Section { Text("小组件展示最近同步的信息，更新频率由系统调度。配对数据与未读角标需要打开 App 同步。"); link(.order, "arrow.up.arrow.down") }
        case .islandGuide:
            guideSection("灵动岛与锁屏", steps: ["开启“显示灵动岛”后展示设备状态。", "系统会限制实时活动持续时间，到期不代表设备离线。", "回到 AirSIM 前台会恢复展示；来电 PushKit／CallKit 链路独立于实时活动。"])
            Section { Text("不要把后台保活或实时活动当作强制退出 App 后必定收到来电的保证。") }
        case .accessibility:
            Section {
                Picker("语言", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
            guideSection("跟随 iPhone 设置", steps: ["在系统设置 → 辅助功能中调整文字大小、减少动态效果或减少透明度。", "AirSIM 的列表和表单跟随系统文字大小，重要状态同时使用文字与图标。", "滑块也支持 VoiceOver 的开启／关闭操作，无需精确拖动。"])
        default: EmptyView()
        }
    }

    private var homeSnapshot: AirSIMSettingsHomeSnapshot {
        let devices = model.pairedDeviceHistory
        let device = devices.first(where: \.isCurrent) ?? devices.first
        let connection = model.connectionModePresentation
        return AirSIMSettingsHomeSnapshot(deviceID: device?.id,
            deviceName: device?.deviceName ?? "", connectionDetail: connection.status + " · " + connection.title,
            modeTitle: selectedMode.title, version: AppInformation.version,
            pureLocalEnabled: pureLocalEnabled, pureLocalBusy: pureLocalBusy,
            callBusy: updateCallBusy, pureLocalError: pureLocalError,
            language: settings.language.rawValue)
    }

    private var pureLocalControl: some View {
        PureLocalSlideControl(enabled: pureLocalEnabled, busy: pureLocalBusy, blockedByCall: updateCallBusy) { current in
            Task { @MainActor in await setPureLocalMode(!current) }
        }
    }

    private var deviceListSection: some View {
        Section("已配对设备") {
            ForEach(model.pairedDeviceHistory) { device in
                NavigationLink(value: AirSIMSettingsPage.device(device.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.deviceName)
                        Text(device.isCurrent ? "当前设备" : "已保存配对").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            link(.add, "plus.circle")
        }
    }

    @ViewBuilder
    private func deviceSections(_ id: String) -> some View {
        if let device = model.pairedDeviceHistory.first(where: { $0.id == id }) {
            Section {
                Text(device.deviceName).font(.title2.bold())
                LabeledContent("号码", value: device.phoneNumber ?? "运营商未提供号码")
                LabeledContent("VoWLAN", value: device.vowlanOnline ? "在线" : "未连接")
                LabeledContent("蓝牙", value: device.bluetoothOnline ? "在线" : "未连接")
                LabeledContent("云端", value: device.cloudOnline ? "在线" : "尚未确认在线")
            }
            Section { link(.deviceInfo(id), "info.circle"); link(.diagnostics, "stethoscope") }
            Section {
                Button("忘记此设备", role: .destructive) { deviceDeletionError = nil; deletingDevice = device }
                    .disabled(deviceDeletionInProgress || updateCallBusy)
                if let deviceDeletionError { Text(deviceDeletionError).font(.footnote).foregroundStyle(.red) }
            } footer: { Text("仅清除本机配对；不会删除手机系统短信或通话记录。") }
        } else {
            Section { Text("此设备的本机配对记录已移除。"); link(.add, "plus.circle") }
        }
    }

    @ViewBuilder
    private func deviceInformation(_ id: String) -> some View {
        Section("设备身份") { Text("身份 …\(id.suffix(8))").font(.body.monospaced()).textSelection(.enabled) }
        if let record = VoWLANPairingRecordStore.records().first(where: { $0.agentID == id }) {
            Section {
                LabeledContent("本机记录", value: String(record.id.prefix(8)))
                LabeledContent("已保存端点", value: "\(record.endpoints.count)")
                ForEach(Array(record.endpoints.enumerated()), id: \.offset) { _, endpoint in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(endpoint.host).textSelection(.enabled)
                        Text("控制 \(endpoint.controlPort) · 音频 \(endpoint.pcmPort) · \(endpoint.tls == true ? "TLS" : "私网直连")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("配对密钥保存在本机安全存储，不在页面显示。").font(.footnote)
            }
        }
    }

    private var relaySections: some View {
        Group {
            Section {
                LabeledContent("云端通话", value: pureLocalEnabled ? "纯本地已阻止" : runtimePolicy.startsCloud ? "当前模式启用" : "当前未使用")
                TextField("https://relay.example.com", text: $relayURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings.relayURL")
                Button(relaySaving ? "正在保存…" : "保存 Relay 地址") { saveRelay() }
                    .disabled(pureLocalEnabled || updateCallBusy || relaySaving)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text(pureLocalEnabled ? "纯本地模式已阻止 Relay，请先关闭纯本地模式。" : "保存地址与设备注册是不同步骤。当前未使用云端通话，也可手动自检。")
            }
            Section { link(.cloudCheck, "stethoscope") }
        }
    }

    private var permissionSections: some View {
        Group {
            Section {
                LabeledContent("通知权限", value: notificationPermission)
                Text("本地网络与蓝牙权限请在系统设置中核对。iOS 不提供统一的查询接口，未连接不一定是权限被拒绝。")
                Button("打开 AirSIM 系统设置", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section {
                Text("安卓端还需检查电话、短信及 Shizuku／Root 音频桥授权。通话时才验证 PCM 双向音频。")
                link(.diagnostics, "stethoscope")
            }
        }.task { await readNotificationPermission() }
    }

    private func guideSection(_ title: String, steps: [String]) -> some View {
        Section(title) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                Label(text, systemImage: "\(index + 1).circle").padding(.vertical, 6)
            }
        }
    }

    private func selectMode(_ mode: AirSIMConnectionMode) {
        guard AirSIMSettingsPolicy.canSelect(mode, pureLocal: pureLocalEnabled, callBusy: updateCallBusy) else { return }
        connectionModeRaw = mode.rawValue
        model.setConnectionMode(mode)
        // Mode changes do not invalidate read-only cloud diagnostic results.
    }

    private func checkLocalConnection() {
        guard !localCheckRunning, !updateCallBusy else { return }
        localCheckRunning = true
        Task { @MainActor in
            defer { localCheckRunning = false }
            model.vowlan.restartBrowsing()
            await model.vowlan.probeNow()
            localCheckDate = Date()
            localCheckStatus = VoWLANStatusCopy.text(for: model.vowlan.availability)
        }
    }

    private func saveRelay() {
        guard !pureLocalEnabled, !updateCallBusy, !relaySaving else { return }
        guard let value = AirSIMSettingsPolicy.validRelayURL(relayURL) else {
            message = "请输入完整的 http:// 或 https:// 地址，不包含账号、密码、查询参数或片段。"
            return
        }
        relaySaving = true
        VoIPPushController.shared.updateRelayURL(value)
        relayURL = VoIPPushController.shared.configuredRelayURL()
        selfTestTask?.cancel(); selfTestReport = nil; selfTestPhase = .idle
        diagnosticCloudOnline = nil
        message = "地址已保存；设备注册状态请运行自检确认。"
        Task { @MainActor in
            defer { relaySaving = false }
            if let (api, _) = await model.readyVoWLANRoute() {
                await VoIPPushController.shared.syncRegistration(with: api)
            }
            if !pureLocalEnabled { await model.refreshCloudStatusForDiagnostics() }
        }
    }

    private func readNotificationPermission() async {
        let value = await UNUserNotificationCenter.current().notificationSettings()
        switch value.authorizationStatus {
        case .authorized: notificationPermission = "已允许"
        case .provisional, .ephemeral: notificationPermission = "临时允许"
        case .denied: notificationPermission = "未允许"
        case .notDetermined: notificationPermission = "尚未请求"
        @unknown default: notificationPermission = "请在系统设置中确认"
        }
    }

    private var backgroundSection: some View {
        Section {
            Toggle("后台静音音频保活", isOn: $backgroundStandbyEnabled)
                .onChange(of: backgroundStandbyEnabled) { enabled in
                    model.setBackgroundStandbyEnabled(enabled)
                }
                .accessibilityIdentifier("backgroundStandby")
            Text(backgroundStandbyEnabled
                 ? "已开启：App 退到后台时播放静音音频，尽量维持轮询、CallKit 与 Push 处理；会明显增加耗电。"
                 : "已关闭：不播放后台静音音频，降低耗电；iOS 仍可通过 PushKit 唤醒，但后台轮询可能被挂起。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("后台保活")
        } footer: {
            Text("这是全局开关，关闭后所有后台静音音频保活路径都会停止；不会关闭 VoWLAN、蓝牙或云端 Push 功能。")
        }
    }

    private var connectionStatusSection: some View {
        Section("当前连接") {
            LabeledContent("当前模式", value: model.connectionModePresentation.title)
            LabeledContent("连接状态", value: model.connectionModePresentation.status)
            LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
            LabeledContent(
                "云端 Relay",
                value: CloudRelayStatusCopy.text(pureLocal: pureLocalEnabled,
                    cloudOnline: runtimePolicy.startsCloud ? model.cloudAgentStatus?.cloudOnline : diagnosticCloudOnline,
                    usesCloudCalls: runtimePolicy.startsCloud)
            )
            if !pureLocalEnabled && !runtimePolicy.startsCloud {
                Text("当前通话使用本地链路；云端通话未启用，但仍可手动检查 Relay、注册与 Agent 心跳。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(model.connectionModePresentation.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let connectionMessage = model.connectionMessage, !connectionMessage.isEmpty {
                Text(connectionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var networkPrefixesSection: some View {
        Section {
            // 单行输入 + 默认回车键：按“返回”直接收起键盘，多行输入会让回车变成换行。
            TextField("例如 30.0.0.0/8, 100.64.0.0/10", text: $networkPrefixesText)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($networkPrefixesFocused)
                .onSubmit {
                    networkPrefixesFocused = false
                    saveNetworkPrefixes()
                }
                .accessibilityIdentifier("privateNetworkPrefixes")
            if let networkPrefixError {
                Text(networkPrefixError).font(.footnote).foregroundStyle(.red)
            } else {
                Text("用逗号分隔多个网段，例如 30.0.0.0/8, 100.64.0.0/10。保存后重新配对或重新发现即可使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("保存私有网段") {
                networkPrefixesFocused = false
                saveNetworkPrefixes()
            }
            .accessibilityIdentifier("savePrivateNetworkPrefixes")
        } header: {
            Text("私有网络")
        } footer: {
            Text("内置支持 10/8、172.16/12、192.168/16、169.254/16 与 100.64/10（Tailscale）。"
                + "公网地址始终不会被视为私有网段。")
        }
    }

    private var bluetoothSection: some View {
        Section("蓝牙连接") {
            LabeledContent("VoBLE", value: voBLEStatus)
            link(.bluetoothPair, "wave.3.right")
            Button("重新扫描蓝牙 Agent", systemImage: "arrow.clockwise") {
                model.vobleHub.radio.rescan()
            }
            .disabled(!runtimePolicy.startsBluetooth)
        }
    }

    private var bluetoothDiagnosticsSection: some View {
        Section("蓝牙诊断（已脱敏）") {
            let diagnostics = model.vobleDiagnostics
            LabeledContent("认证", value: diagnostics.peerAuthenticated ? "通过" : "未完成")
            LabeledContent("PCM", value: diagnostics.pcmReady ? "运行中" : "待启动")
            LabeledContent("编码", value: diagnostics.codec)
            LabeledContent("发送队列", value: "\(diagnostics.queuedFrames) / 8 帧")
            LabeledContent("丢帧", value: "\(diagnostics.droppedFrames)")
            LabeledContent("抖动缓冲", value: "\(diagnostics.jitterFrames) 帧")
            LabeledContent("最近错误", value: diagnostics.lastError.rawValue)
            Text("诊断不会显示号码、密钥、nonce、认证标签或音频内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var liveActivitySection: some View {
        Section {
            Toggle(isOn: $liveActivityEnabled) {
                Label("显示灵动岛", systemImage: "platter.filled.top.iphone")
            }
            .onChange(of: liveActivityEnabled) { enabled in
                model.setLiveActivityEnabled(enabled)
            }
        } header: {
            Text("灵动岛与实时活动")
        } footer: {
            Text("关闭后结束 AirSIM 的灵动岛与锁屏实时活动；通话和短信仍可正常使用。")
        }
    }

    private var deviceOrderSection: some View {
        Section {
            ForEach(model.liveActivityOrderedAgents) { agent in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.deviceName)
                            .fixedSize(horizontal: false, vertical: true)
                        if let number = agent.phoneNumber, !number.isEmpty {
                            Text(number)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        model.toggleLiveActivityAgentPin(agent.id)
                    } label: {
                        Image(systemName: LiveActivityAgentOrder.isPinned(agent.id)
                            ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(LiveActivityAgentOrder.isPinned(agent.id)
                        ? "取消置顶 \(agent.deviceName)" : "置顶 \(agent.deviceName)")
                    Button {
                        model.moveLiveActivityAgent(agent.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("上移 \(agent.deviceName)")
                    Button {
                        model.moveLiveActivityAgent(agent.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("下移 \(agent.deviceName)")
                }
            }
        } header: {
            Text("设备显示顺序")
        } footer: {
            Text("置顶设备固定在前；其余按这里排序。灵动岛每页最多显示 5 台，右上角按钮翻到下一页。")
        }
    }

    private var cloudSelfTestSection: some View {
        Section {
            Button {
                startCloudSelfTest()
            } label: {
                HStack {
                    Label("运行云端模式自检", systemImage: "stethoscope")
                    Spacer()
                    if selfTestPhase == .running {
                        ProgressView()
                    }
                }
            }
            .disabled(pureLocalEnabled || selfTestPhase == .running)

            if let report = selfTestReport {
                ForEach(report.steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selfTestSymbol(for: step.state))
                            .foregroundStyle(selfTestColor(for: step.state))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .textSelection(.enabled)
                            Text(step.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if selfTestPhase == .completed {
                    Text(report.allPassed ? "云端模式自检通过" : "自检未通过，请按失败步骤修复后重试")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(report.allPassed ? .green : .orange)
                    Button {
                        UIPasteboard.general.string = report.copyText
                        selfTestCopied = true
                    } label: {
                        Label(selfTestCopied ? "已复制自检结果" : "复制自检结果", systemImage: "doc.on.doc")
                    }
                    .font(.footnote)
                }
            }
        } header: {
            Text("云端连接自检")
        } footer: {
            Text(pureLocalEnabled
                ? "纯本地模式已开启，禁止访问 Relay；关闭后可手动自检。"
                : "依次验证本机 Push 凭据、Relay 身份、设备注册、Agent 记录、150 秒心跳和命令路由；失败步骤会给出具体卡点，不会拨号或发送短信。")
        }
    }

    private var smsSection: some View {
        Section("短信") {
            Toggle("自动复制验证码到剪贴板", isOn: $autoCopySMSCode)
            Text("收到新验证码短信后自动复制，便于系统键盘显示粘贴建议。会覆盖当前剪贴板内容，可随时关闭。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("项目", value: "AirSIM")
            LabeledContent("版本", value: AppInformation.version)
                .textSelection(.enabled)
            Button("当前版本更新内容") { appUpdatePresentation = .notes }
            Button(appUpdates.checking ? "正在检查应用更新…" : "检查应用更新") {
                Task {
                    if let result = await appUpdates.check(manual: true) {
                        appUpdateInbox.receive(result)
                        presentManualAppUpdateIfIdle()
                    }
                }
            }
            .disabled(appUpdates.checking)
            Text(appUpdates.status).font(.footnote).foregroundStyle(.secondary)
            LabeledContent("更新渠道", value: AppUpdateChannel.title)
            Link("GitHub 仓库", destination: AppInformation.repositoryURL)
            Link("版本发布与下载", destination: AppInformation.releasesURL)
        }
    }

    private var feedbackSection: some View {
        Section("反馈") {
            TextField("用户描述（可选）", text: $feedbackDescription, axis: .vertical)
                .accessibilityIdentifier("settings.feedbackDescription")
                .lineLimit(2...4)
                .focused($feedbackFocusedField, equals: .description)
                .submitLabel(.done)
                .onSubmit { feedbackFocusedField = nil }
            TextField("备注（可选）", text: $feedbackRemark, axis: .vertical)
                .lineLimit(2...4)
                .focused($feedbackFocusedField, equals: .remark)
                .submitLabel(.done)
                .onSubmit { feedbackFocusedField = nil }
            Button {
                guard !pureLocalEnabled else { return }
                feedbackFocusedField = nil
                feedbackUploading = true
                feedbackUploadStatus = "正在收集并上传…"
                Task {
                    defer { feedbackUploading = false }
                    let result = await FeedbackUploader.shared.upload(
                        trigger: "manual",
                        eventID: UUID().uuidString,
                        api: model.verboseDiagnosticsAPI,
                        model: model
                    )
                    feedbackUploadStatus = result
                }
            } label: {
                Label(feedbackUploading ? "正在上传…" : "上传反馈", systemImage: "paperplane")
            }
            .disabled(feedbackUploading || pureLocalEnabled)
            if pureLocalEnabled { Text("纯本地模式已阻止上传，草稿仍会保留。").font(.footnote) }
            if !feedbackUploadStatus.isEmpty {
                Text(feedbackUploadStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("仅手动上传诊断信息。请先检查上传范围，避免在文字中包含个人信息。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func setPureLocalMode(_ enabled: Bool) async {
        guard !pureLocalBusy else { return }
        selfTestTask?.cancel()
        selfTestPhase = .idle
        selfTestReport = nil
        diagnosticCloudOnline = nil
        guard !updateCallBusy else { pureLocalError = "通话中不能切换纯本地模式"; return }
        pureLocalBusy = true; pureLocalError = nil
        defer { pureLocalBusy = false }
        if enabled {
            UserDefaults.standard.set(connectionModeRaw, forKey: "airsim.pure-local.prior-mode")
            UserDefaults.standard.set(cloudSignalingEnabled, forKey: "airsim.pure-local.prior-cloud")
            RelayEgressGate.shared.setPersistentBlocked(true)
            pureLocalEnabled = true
            guard await RelayEgressGate.shared.disableAndDrain() else {
                pureLocalError = "云端连接尚未完全排空，请稍后重试"
                return
            }
            cloudSignalingEnabled = false
            model.setCloudSignalingEnabled(false)
            connectionModeRaw = AirSIMConnectionMode.localDual.rawValue
            model.setConnectionMode(.localDual)
        } else {
            do {
                try RelayEgressGate.shared.enableAfterRestore()
                RelayEgressGate.shared.setPersistentBlocked(false)
                pureLocalEnabled = false
                let raw = UserDefaults.standard.string(forKey: "airsim.pure-local.prior-mode") ?? AirSIMConnectionMode.automatic.rawValue
                let cloud = UserDefaults.standard.object(forKey: "airsim.pure-local.prior-cloud") as? Bool ?? true
                connectionModeRaw = raw
                cloudSignalingEnabled = cloud
                model.setCloudSignalingEnabled(cloud)
                model.setConnectionMode(AirSIMConnectionMode(rawValue: raw) ?? .automatic)
            } catch { pureLocalError = "本地退出尚未完成：\(error.localizedDescription)" }
        }
    }

    private var updateCallBusy: Bool {
        model.activeCall != nil || model.remoteCall != nil || model.pendingOutgoingCall != nil
    }

    private func handleUpdateCallChange() {
        if updateCallBusy { appUpdatePresentation = nil }
        else { presentManualAppUpdateIfIdle() }
    }

    private func presentManualAppUpdateIfIdle() {
        if let result = appUpdateInbox.takeIfIdle(isActive: updateViewVisible && updateScenePhase == .active,
            callBusy: updateCallBusy, hasModal: appUpdatePresentation != nil || model.errorMessage != nil) {
            appUpdatePresentation = .result(result)
        }
    }

    private func startCloudSelfTest() {
        guard !pureLocalEnabled, !RelayEgressGate.shared.isBlocked else { return }
        selfTestTask?.cancel()
        selfTestCopied = false
        selfTestPhase = .running
        selfTestReport = .initial
        selfTestTask = Task { @MainActor in
            let report = await VoIPPushController.shared.runCloudSelfTest { update in
                guard !Task.isCancelled else { return }
                selfTestReport = update
            }
            guard !Task.isCancelled else { return }
            selfTestReport = report
            selfTestPhase = .completed
            if runtimePolicy.startsCloud {
                await model.refreshCloudStatusForDiagnostics()
            } else {
                // Explicit diagnostics must not use the automatic cloud-mode fetch guard.
                let status = try? await VoIPPushController.shared.fetchCloudAgentStatusForDiagnostics(allowLocalMode: true)
                guard !Task.isCancelled, !pureLocalEnabled else { return }
                diagnosticCloudOnline = status?.cloudOnline
            }
        }
    }

    private var selectedMode: AirSIMConnectionMode {
        AirSIMConnectionMode(rawValue: connectionModeRaw) ?? .automatic
    }

    private var runtimePolicy: ConnectionModeRuntimePolicy {
        ConnectionModeRuntimePolicy(mode: selectedMode)
    }

    private func saveNetworkPrefixes() {
        // 单行输入可能包含粘贴进来的换行，统一视为分隔符。
        let invalid = networkPrefixesText
            .split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
            .filter { NetworkRoutePreferences.parse($0) == nil }
        guard invalid.isEmpty else {
            networkPrefixError = "网段格式无效：\(invalid.joined(separator: "、"))"
            return
        }
        NetworkRoutePreferences.save(networkPrefixesText)
        networkPrefixError = nil
        // 端点白名单在建立连接时重新读取，发现流程需要重新开始才能生效。
        model.vowlan.restartBrowsing()
    }

    private var voBLEStatus: String {
        switch model.vobleHub.pairingState {
        case .stopped: return runtimePolicy.startsBluetooth ? "待启动" : "当前模式已关闭"
        case .bluetoothUnavailable: return "蓝牙不可用"
        case .scanning: return "正在发现"
        case .connecting, .connected: return "正在连接"
        case .authenticating: return "正在认证"
        case .ready: return "已认证"
        case .failed(let message): return "失败：\(message)"
        }
    }

    private func modeIcon(_ mode: AirSIMConnectionMode) -> String {
        switch mode {
        case .localDual: return "wifi.circle"
        case .vowlan: return "wifi"
        case .bluetooth: return "wave.3.right"
        case .cloud: return "cloud"
        case .automatic: return "arrow.triangle.branch"
        }
    }

    private func selfTestSymbol(for state: CloudSelfTestStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func selfTestColor(for state: CloudSelfTestStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        }
    }
}

import Foundation
import SwiftUI

enum NotificationForwardingChannel: String, CaseIterable, Codable, Identifiable, Sendable {
    case bark, discord, slack, wecom, feishu, telegram, qq, webhook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bark: return "Bark"
        case .discord: return "Discord"
        case .slack: return "Slack"
        case .wecom: return "企业微信"
        case .feishu: return "飞书自定义机器人"
        case .telegram: return "Telegram Bot"
        case .qq: return "QQ 官方 Bot"
        case .webhook: return "通用 Webhook"
        }
    }
}

struct NotificationForwardingDestination: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var enabled = true
    var name = ""
    var channel: NotificationForwardingChannel = .webhook
    var webhookURL = ""
    var token = ""
    var chatID = ""
    var deviceKey: String? = nil
    var secret = ""
    var sendSMS = true
    var sendIncomingCall = true
    var sendMissedCall = true
    var includeBody = true
    var includeNumber = true
    var template = """
    {event}
    设备：{device}
    号码：{number}
    发件人：{sender}
    内容：{content}
    时间：{time}
    """
    var missedTemplate: String? = nil


    /// Match the Android forwarder's required inputs without contacting a service.
    var validationMessage: String? {
        guard enabled else { return nil }
        let value = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = URLComponents(string: value)
        if !value.isEmpty {
            guard let parts, ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
                  parts.user == nil, parts.password == nil, parts.fragment == nil else {
                return "请输入有效的 Webhook 地址。"
            }
        }
        switch channel {
        case .bark:
            if !value.isEmpty && parts?.scheme?.lowercased() != "https" { return "Bark 地址需要 HTTPS。" }
            let pathKey = parts?.path.split(separator: "/").last.map(String.init) ?? ""
            if (deviceKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               value.isEmpty || pathKey.isEmpty || pathKey == "push" { return "请填写 Bark Device Key。" }
        case .telegram, .qq:
            if chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 Chat ID 或 OpenID。" }
            if (value.isEmpty || channel == .qq), token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "请填写 Bot Token。"
            }
        default:
            if value.isEmpty { return "请填写 Webhook 地址。" }
        }
        return nil
    }
}

struct NotificationForwardingConfig: Codable, Equatable, Sendable {
    var enabled = false
    var destinations: [NotificationForwardingDestination] = []
}

enum NotificationForwardingStore {
    static let key = "airsim.notification-forwarding"

    static func load(defaults: UserDefaults = .standard) -> NotificationForwardingConfig {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(NotificationForwardingConfig.self, from: data) else {
            return NotificationForwardingConfig()
        }
        return value
    }

    static func save(_ value: NotificationForwardingConfig, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

struct NotificationForwardingView: View {
    @State private var config = NotificationForwardingStore.load()
    @State private var editing: NotificationForwardingDestination?
    @State private var showingAdd = false

    var body: some View {
        Form {
            Section {
                Toggle("启用通知转发", isOn: $config.enabled)
                Text("配置随下一次配对发送给 Android。Android 直接发送 Webhook，不依赖 Relay、APNs 或 iPhone 是否运行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("转发目标") {
                ForEach(config.destinations) { destination in
                    Button {
                        editing = destination
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.name.isEmpty ? destination.channel.title : destination.name)
                                Text(destination.channel.title + (destination.enabled ? "" : " · 已停用"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in
                    config.destinations.remove(atOffsets: offsets)
                    save()
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("添加转发目标", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("通知转发")
        .onChange(of: config) { _ in save() }
        .sheet(isPresented: $showingAdd) {
            NotificationForwardingEditor(destination: NotificationForwardingDestination()) { value in
                config.destinations.append(value)
                save()
            }
        }
        .sheet(item: $editing) { destination in
            NotificationForwardingEditor(destination: destination) { value in
                if let index = config.destinations.firstIndex(where: { $0.id == value.id }) {
                    config.destinations[index] = value
                }
                save()
            }
        }
    }

    private func save() {
        // Delivered only inside the next encrypted pairing registration; never
        // upload webhook URLs/tokens to Relay or APNs.
        NotificationForwardingStore.save(config)
    }
}

private struct NotificationForwardingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var destination: NotificationForwardingDestination
    @State private var confirmingDiscard = false
    let onSave: (NotificationForwardingDestination) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("目标") {
                    TextField("备注名称", text: $destination.name)
                    Picker("渠道", selection: $destination.channel) {
                        ForEach(NotificationForwardingChannel.allCases) { channel in
                            Text(channel.title).tag(channel)
                        }
                    }
                    Toggle("启用", isOn: $destination.enabled)
                }
                Section("连接") {
                    TextField("Webhook URL", text: $destination.webhookURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if destination.channel == .bark {
                        TextField("Bark Device Key（URL 不含 key 时填写）", text: Binding(
                            get: { destination.deviceKey ?? "" },
                            set: { destination.deviceKey = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                    }
                    if destination.channel == .telegram || destination.channel == .qq {
                        SecureField("Bot Token", text: $destination.token)
                            .textInputAutocapitalization(.never)
                    }
                    if destination.channel == .telegram || destination.channel == .qq {
                        TextField("Chat ID / OpenID", text: $destination.chatID)
                    }
                    if destination.channel == .feishu {
                        SecureField("签名 Secret（可选）", text: $destination.secret)
                            .textInputAutocapitalization(.never)
                    }
                }
                if let validation = destination.validationMessage {
                    Section { Text(validation).font(.footnote).foregroundStyle(.red) }
                }
                Section("事件") {
                    Toggle("短信", isOn: $destination.sendSMS)
                    Toggle("来电", isOn: $destination.sendIncomingCall)
                    Toggle("未接来电", isOn: $destination.sendMissedCall)
                    Toggle("包含短信正文", isOn: $destination.includeBody)
                    Toggle("包含号码", isOn: $destination.includeNumber)
                }
                Section {
                    NavigationLink("消息模板") {
                        Form {
                Section {
                    TextEditor(text: $destination.template)
                        .frame(minHeight: 150)
                        .font(.system(.footnote, design: .monospaced))
                    Text("可用占位符：{event} {device} {number} {sender} {content} {time}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("短信 / 来电格式")
                }
                Section {
                    TextEditor(text: Binding(
                        get: { destination.missedTemplate ?? "{event}\n设备：{device}\n号码：{number}\n时间：{time}" },
                        set: { destination.missedTemplate = $0 }
                    ))
                        .frame(minHeight: 100)
                        .font(.system(.footnote, design: .monospaced))
                } header: {
                    Text("未接来电格式")
                }
                        }.navigationTitle("消息模板")
                    }
                }

            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("转发目标")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .confirmationDialog("放弃本次编辑？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃编辑", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { confirmingDiscard = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard destination.validationMessage == nil else { return }
                        onSave(destination)
                        dismiss()
                    }
                    .disabled(destination.validationMessage != nil)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

@MainActor
final class FeedbackUploader {
    static let shared = FeedbackUploader()
    static let descriptionKey = "airsim.feedback-description"
    static let remarkKey = "airsim.feedback-remark"
    private static let endpoint = URL(string: "https://airsim-push.remotepilot.site/v1/feedback")!

    private init() {}

    static func permitsUpload(trigger: String) -> Bool { trigger == "manual" }

    func upload(trigger: String, eventID: String, api: AirSIMAPI?, model: AppModel?) async -> String {
        // Reject before collecting Android logs or contacting either endpoint.
        guard Self.permitsUpload(trigger: trigger) else { return "自动反馈上传已关闭，请手动上传" }
        guard !RelayEgressGate.shared.isBlocked else { return "纯本地模式已开启，反馈上传已关闭" }

        let snapshot: AgentFeedbackSnapshot?
        if let api {
            snapshot = try? await api.feedbackSnapshot()
        } else {
            snapshot = nil
        }
        let trace = await AgentVerboseTraceRecorder.shared.exportText(agentEvents: [])
        // Keep the newest Android rows; a prefix loses the call/crash window that
        // triggered this feedback.
        let androidLog = String((snapshot?.bridgeLog ?? "").suffix(400_000))
        let pcm = Self.pcm(from: androidLog)
        let audio = Self.audioDiagnostics(trace: trace, snapshot: snapshot)
        let mode = ConnectionModePreference.selected()
        let modeValue: String
        switch mode {
        case .vowlan, .localDual: modeValue = "vowlan"
        case .bluetooth: modeValue = "voble"
        case .cloud: modeValue = "cloud"
        case .automatic: modeValue = "auto"
        }
        let device = UIDevice.current
        let body: [String: Any] = [
            "feedback_id": UUID().uuidString,
            "trigger": trigger,
            "platform": snapshot == nil ? "iOS" : "Both",
            "app_version": AppInformation.version,
            "ios_version": device.systemVersion,
            "iphone_model": device.model,
            "android_model": snapshot?.model ?? "",
            "android_sdk": snapshot?.sdk ?? 0,
            "connection_mode": modeValue,
            "route": mode.title,
            "relay_status": "unknown",
            "pcm": pcm,
            "audio": audio,
            "crash": CrashDiagnosticsStore.shared.recent(),
            "error_summary": "",
            "description": UserDefaults.standard.string(forKey: Self.descriptionKey) ?? "",
            "remark": UserDefaults.standard.string(forKey: Self.remarkKey) ?? "",
            "ios_trace": String(trace.prefix(250_000)),
            "android_log": androidLog,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return "反馈数据生成失败"
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (responseData, response) = try await RelayEgressGate.shared.send(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return "上传失败（HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0)）"
            }
            if let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let url = object["url"] as? String, !url.isEmpty {
                return "已上传：\(url)"
            }
            return "已上传到 Notion"
        } catch {
            return "上传失败：\(error.localizedDescription)"
        }
    }

    private static func audioDiagnostics(trace: String, snapshot: AgentFeedbackSnapshot?) -> [String: Any] {
        let lines = trace.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = lines.lastIndex { $0.contains("phase=answer_observed") } ?? 0
        let relevant = lines[start...]
        var stages: [String] = []
        var startupMilliseconds = 0
        for line in relevant {
            // Trace lines are formatted as "[APP] ... AUDIO 通话音频启动".
            guard line.contains("AUDIO 通话音频启动") else { continue }
            if let phase = Self.value(after: "phase=", in: line), !phase.isEmpty,
               !stages.contains(phase) { stages.append(phase) }
            let phase = Self.value(after: "phase=", in: line) ?? ""
            if phase != "stopped", phase != "failed",
               let duration = Int(Self.value(after: "duration_ms=", in: line) ?? "") {
                startupMilliseconds = max(startupMilliseconds, duration)
            }
        }
        let expected = ["answer_observed", "phone_start", "engine_ready", "agent_register",
                        "pcm_ready", "first_downlink", "agent_ready", "stopped"]
        let missing = expected.filter { !stages.contains($0) }
        let telecom = snapshot?.audio?.telecomState ?? ""
        let clientClosed = snapshot?.audio?.pcmClientClosed ?? false
        let pcmHealth = String((snapshot?.audio?.pcmHealth ?? "").prefix(500))
        let summary = "stages=\(stages.joined(separator: ",")); missing=\(missing.joined(separator: ",")); "
            + "telecom=\(telecom); pcm_client_closed=\(clientClosed); pcm=\(pcmHealth)"
        return [
            "stages": stages,
            "missing": missing,
            "startup_ms": startupMilliseconds,
            "pcm_client_closed": clientClosed,
            "telecom_state": telecom,
            "summary": summary,
        ]
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    private static func pcm(from log: String) -> [String: Any] {
        let route = value("pcm_route", in: log)
        let capture = value("pcm_capture", in: log)
        let initialized = value("pcm_initialized", in: log) == "true"
        let verified = route == "verified"
        let down = Int(value("pcm_down_peak", in: log)) ?? 0
        let up = Int(value("pcm_up_peak", in: log)) ?? 0
        let downBytes = Int(value("pcm_down_bytes", in: log)) ?? 0
        let upBytes = Int(value("pcm_up_bytes", in: log)) ?? 0
        let mode: String
        if !initialized || route.isEmpty {
            mode = "not_connected"
        } else if route == "verified" && down > 0 && up > 0 {
            mode = "vowlan_direct_full_duplex"
        } else if route == "verified" && down > 0 {
            mode = "vowlan_direct_downlink_only"
        } else if route == "verified" && up > 0 {
            mode = "vowlan_direct_uplink_only"
        } else {
            mode = "vowlan_direct_silent"
        }
        return [
            "mode": mode,
            "route": route,
            "capture_source": capture.isEmpty ? "" : "voice_downlink",
            "initialized": initialized,
            "route_verified": verified,
            "capture": capture.isEmpty ? "unverified" : capture,
            "down_peak": down,
            "up_peak": up,
            "down_bytes": downBytes,
            "up_bytes": upBytes,
            "failure": value("pcm_failure", in: log),
        ]
    }

    private static func value(_ key: String, in log: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: key) + "=([^\\s]+)") else { return "" }
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        guard let match = expression.firstMatch(in: log, range: range),
              let valueRange = Range(match.range(at: 1), in: log) else { return "" }
        return String(log[valueRange])
    }
}


private extension View {
    @ViewBuilder
    func settingsSoftScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            // Let the system blend scrolling content into the navigation chrome,
            // including Duo's changing safe area and accessibility settings.
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
