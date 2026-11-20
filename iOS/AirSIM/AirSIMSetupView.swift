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
                    Text(DedicatedCallPolicy.vowlanOnly ? "通话通过 VoWLAN 直连 Android 手机，Relay 仅用于推送通知。" : "AirSIM 可通过 VoWLAN、蓝牙或云端 Relay 独立连接 Android 手机。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Label("在 Android 手机启动 AirSIM 和音频桥", systemImage: "1.circle.fill")
                    Label(DedicatedCallPolicy.vowlanOnly ? "让两台设备连接同一 Wi‑Fi"
                          : selectedMode == .bluetooth ? "打开两台设备的蓝牙" : "按所选模式准备网络或蓝牙",
                          systemImage: "2.circle.fill")
                    Label("核对配对安全码并完成认证", systemImage: "3.circle.fill")
                }
                .font(.body.weight(.medium))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

                if !DedicatedCallPolicy.vowlanOnly {
                    Picker("连接模式", selection: Binding(get: { selectedMode.rawValue }, set: { connectionModeRaw = $0 })) {
                        ForEach(DedicatedCallPolicy.selectableModes) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: connectionModeRaw) { rawValue in
                        guard let mode = AirSIMConnectionMode(rawValue: rawValue) else { return }
                        model.setConnectionMode(mode)
                    }
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
        DedicatedCallPolicy.vowlanOnly ? .vowlan : (AirSIMConnectionMode(rawValue: connectionModeRaw) ?? .automatic)
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var statusRevision = 0
    let devices: [AndroidAgentPresentation]
    let onDelete: (AndroidAgentPresentation) -> Void

    var body: some View {
        let _ = statusRevision
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
                        Label(smsEncryptionStatus(device.id), systemImage: "lock.shield")
                            .font(.caption2).foregroundStyle(.secondary)
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
            Text("加密状态来自本机已保存的配对密钥，仅适用于云端接收短信。需两端配对一致；收到并成功解密短信后才能验证实际链路。")
                .font(.caption2).foregroundStyle(.secondary)
            Text("重连时重新读取当前信息，离线记录不保存号码。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .onChange(of: scenePhase) { phase in
            if phase == .active { statusRevision += 1 }
        }
    }

    private func smsEncryptionStatus(_ agentID: String) -> String {
        do {
            guard let record = try KeychainE2EKeyStore.shared.record(agentID: agentID) else {
                return "云端短信：未协商加密"
            }
            guard record.key.count == 32, !record.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "云端短信：密钥异常，请重新配对"
            }
            return "云端短信：已协商端到端加密"
        } catch E2EKeyStoreError.locked {
            return "云端短信：解锁后查看加密状态"
        } catch E2EKeyStoreError.unconfigured {
            return "云端短信：此构建无法读取加密状态"
        } catch {
            return "云端短信：密钥不可用，请重新配对"
        }
    }

    private func connectionText(_ device: AndroidAgentPresentation) -> String {
        let dedicated = DedicatedCallPolicy.vowlanOnly
        let routes = [device.vowlanOnline ? "VoWLAN 在线" : nil,
                      !dedicated && device.bluetoothOnline ? "VoBLE 在线" : nil,
                      device.cloudOnline ? (dedicated ? "推送在线" : "云端在线") : nil].compactMap { $0 }
        return routes.isEmpty ? "离线 · 下次连接重新读取" : routes.joined(separator: " · ")
    }
}

private struct PureLocalSlideControl: View {
    let enabled: Bool
    let busy: Bool
    let blockedByCall: Bool
    let action: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragTranslation: CGFloat = 0
    @Namespace private var glassNamespace

    private var isInteractive: Bool { !busy && !blockedByCall }
    private var title: String {
        if busy { return "正在切换连接策略" }
        if blockedByCall { return "通话中不可切换" }
        return enabled ? "纯本地模式已开启" : "滑动开启纯本地模式"
    }

    private var statusText: String { enabled ? "本地优先 · Relay 已阻断" : "标准连接" }
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
                    if #available(iOS 26.0, *) {
                        GlassEffectContainer(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(.clear)
                                    .glassEffect(
                                        .regular.tint(tint.opacity(0.12 + progress * 0.12)).interactive(),
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
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Capsule(style: .continuous)
                                        .fill(tint.opacity(0.12 + progress * 0.12))
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
            .disabled(saving)
            if enabled {
                Section("远程入口") {
                    TextField("DDNS 域名，例如 phone.example.com", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("HTTPS 控制端口", text: $controlPort).keyboardType(.numberPad)
                    TextField("TLS 音频端口", text: $pcmPort).keyboardType(.numberPad)
                }
                .disabled(saving)
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
                .disabled(agentID.isEmpty || saving || model.vowlan.callInProgress())
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

struct AirSIMSettingsView: View {
    var category: String? = nil
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
    @AppStorage(LiveActivityRemoteStatusPreference.key) private var liveActivityRemoteStatus = false
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
    @State private var deletingDevice: AndroidAgentPresentation?
    @State private var deviceDeletionInProgress = false
    @State private var deviceDeletionError: String?
    @State private var networkPrefixesText = NetworkRoutePreferences.storedText()
    @State private var networkPrefixError: String?
    @AppStorage(RelayEgressGate.persistenceKey) private var pureLocalEnabled = false
    @State private var pureLocalBusy = false
    @State private var pureLocalError: String?
    @State private var diagnosticCloudOnline: Bool?
    @FocusState private var networkPrefixesFocused: Bool
    @FocusState private var feedbackFocusedField: FeedbackFocusedField?

    private enum FeedbackFocusedField: Hashable {
        case description
        case remark
    }

    private var statusDevices: [AndroidAgentPresentation] {
        var devices = model.pairedAndroidAgents
        for saved in model.pairedDeviceHistory where !devices.contains(where: { $0.id == saved.id }) {
            devices.append(AndroidAgentPresentation(id: saved.id, deviceName: saved.deviceName,
                phoneNumber: nil, agentKind: saved.agentKind, cloudOnline: false, vowlanOnline: false,
                isCurrent: AndroidAgentBindingPreference.selected() == saved.id))
        }
        return devices
    }

    private var carrierRingbackSection: some View {
        Section {
            Toggle(isOn: $settings.carrierRingbackEnabled) {
                Text(L10n.t("运营商原始等待音"))
            }
            .accessibilityIdentifier("carrierRingback")
            .onChange(of: settings.carrierRingbackEnabled) { enabled in
                model.carrierRingbackPreferenceDidChange(enabled: enabled)
            }
            Text(L10n.t("呼出接通前优先播放运营商回铃音，设备不支持时用本地等待音"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.t("呼出等待音"))
        } footer: {
            Text(L10n.t("仅 VoWLAN 呼出支持接通前运营商语音；关闭后呼出等待音恢复为本地合成音。"))
        }
    }

    var body: some View {
        SettingsNavigationContainer(isRoot: category == nil) {
            Form {
                if category == nil {
                    Section("已配对设备") {
                        if statusDevices.isEmpty {
                            NavigationLink("连接安卓设备") { AirSIMSettingsView(category: "连接与设备") }
                        } else {
                            ForEach(statusDevices) { agent in
                                AndroidDeviceStatusCard(agent: agent)
                            }
                        }
                    }
                }
                if category == "外观与偏好" {
                    Section("外观") {
                    Picker("主题", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme) }
                    }
                    Picker("外观", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    }
                }
                if category == "纯本地模式" || category == nil {
                Section {
                    PureLocalSlideControl(
                        enabled: pureLocalEnabled,
                        busy: pureLocalBusy,
                        blockedByCall: model.activeCall != nil,
                        action: { currentValue in
                            let requestedValue = !currentValue
                            Task { @MainActor in await setPureLocalMode(requestedValue) }
                        }
                    )
                    if let pureLocalError { Text(pureLocalError).font(.footnote).foregroundStyle(.red) }
                    if category != nil {
                    Text(DedicatedCallPolicy.vowlanOnly
                         ? "滑到底启用。纯本地模式会暂停 Relay 推送和心跳，仍可使用 VoWLAN 通话及本地短信。"
                         : pureLocalEnabled
                            ? "已硬阻断 AirSIM Relay、云端注册、心跳、命令、媒体与反馈；VoWLAN、VoBLE、Tailscale 和本地短信继续可用。"
                            : "滑到底启用。启用后不会因本地链路失败回退到 Relay；GitHub 版本检查不受影响。")
                        .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        NavigationLink("了解纯本地模式") { AirSIMSettingsView(category: "纯本地模式") }
                    }
                } header: { if category != nil { Text("纯本地模式") } }
                }

                if category == nil {
                    Section {
                        ForEach(["连接与设备", "来电与短信", "灵动岛与小组件", "外观与偏好", "帮助与诊断"], id: \.self) { title in
                            NavigationLink { AirSIMSettingsView(category: title) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: title == "连接与设备" ? "antenna.radiowaves.left.and.right" : title == "来电与短信" ? "phone" : title == "灵动岛与小组件" ? "rectangle.on.rectangle" : title == "外观与偏好" ? "paintpalette" : "questionmark.circle")
                                        .font(.system(size: 20)).foregroundStyle(Color.accentColor)
                                        .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                    Text(title).font(.body).padding(.vertical, 8)
                                }
                            }
                        }
                    }
                }

                if category == "连接与设备" {
                Section {
                    Toggle(isOn: $cloudSignalingEnabled) {
                        Label("云端通知（APNs）", systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("cloudSignaling")
                    .onChange(of: cloudSignalingEnabled) { enabled in
                        model.setCloudSignalingEnabled(enabled)
                    }
                    if !DedicatedCallPolicy.vowlanOnly {
                        Picker("连接模式", selection: Binding(get: { selectedMode.rawValue }, set: { connectionModeRaw = $0 })) {
                            ForEach(DedicatedCallPolicy.selectableModes) { mode in
                                Label(mode.title, systemImage: modeIcon(mode)).tag(mode.rawValue)
                            }
                        }
                        .onChange(of: connectionModeRaw) { rawValue in
                            guard let mode = AirSIMConnectionMode(rawValue: rawValue) else { return }
                            model.setConnectionMode(mode)
                        }
                    }
                } header: {
                    Text(DedicatedCallPolicy.vowlanOnly ? "推送" : "运行模式")
                } footer: {
                    Text(DedicatedCallPolicy.vowlanOnly
                         ? "通话使用 VoWLAN。Relay 用于来电、未接来电和短信推送，以及灵动岛后台更新。"
                         : selectedMode.detail + "\n云端通知只负责 APNs/PushKit 与 Relay 注册，不会改变当前媒体模式；VoWLAN 模式下通话仍只走局域网。")
                }
                }

                if category == "来电与短信" {
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

                if category == "来电与短信" {
                    carrierRingbackSection
                }

                if category == "连接与设备" {
                Section("当前连接") {
                    if !DedicatedCallPolicy.vowlanOnly {
                        LabeledContent("当前模式", value: model.connectionModePresentation.title)
                    }
                    LabeledContent("连接状态", value: DedicatedCallPolicy.vowlanOnly ? model.vowlan.connectionProgressText : model.connectionModePresentation.status)
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    if !DedicatedCallPolicy.vowlanOnly {
                        LabeledContent(
                            "云端 Relay",
                            value: CloudRelayStatusCopy.text(pureLocal: pureLocalEnabled,
                                cloudOnline: runtimePolicy.startsCloud ? model.cloudAgentStatus?.cloudOnline : diagnosticCloudOnline,
                                usesCloudCalls: runtimePolicy.startsCloud)
                        )
                    }
                    if !DedicatedCallPolicy.vowlanOnly && !pureLocalEnabled && !runtimePolicy.startsCloud {
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

                if category == "连接与设备" && !DedicatedCallPolicy.vowlanOnly {
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

                if category == "连接与设备" {
                Section("安卓连接") {
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    if model.pairedDeviceHistory.isEmpty {
                    NavigationLink {
                        SamsungPairingView()
                    } label: {
                        Label("配对安卓手机", systemImage: "personalhotspot")
                    }
                    } else {
                        Text("配对新安卓前，请先删除当前已配对设备。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        RemoteDirectSettingsView()
                    } label: {
                        Label("自建域名直连（试验性）", systemImage: "network.badge.shield.half.filled")
                    }
                    PairedAndroidDeviceRows(devices: model.pairedDeviceHistory, onDelete: { deletingDevice = $0 })
                        .disabled(deviceDeletionInProgress)
                    if let deviceDeletionError {
                        Text(deviceDeletionError).font(.footnote).foregroundStyle(.red)
                    }
                    Button("重新发现", systemImage: "arrow.clockwise") {
                        model.vowlan.restartBrowsing()
                        Task { await model.vowlan.probeNow() }
                    }
                }
                }

                if category == "连接与设备" && !DedicatedCallPolicy.vowlanOnly {
                Section("蓝牙连接") {
                    LabeledContent("VoBLE", value: voBLEStatus)
                    NavigationLink {
                        VoBLEPairingView()
                    } label: {
                        Label("配对蓝牙 Agent", systemImage: "wave.3.right")
                    }
                    Button("重新扫描蓝牙 Agent", systemImage: "arrow.clockwise") {
                        model.vobleHub.radio.rescan()
                    }
                    .disabled(!runtimePolicy.startsBluetooth)
                }
                }

                if category == "帮助与诊断" && runtimePolicy.startsBluetooth {
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

                if category == "灵动岛与小组件" {
                Section {
                    Toggle(isOn: $liveActivityEnabled) {
                        Label("显示灵动岛", systemImage: "platter.filled.top.iphone")
                    }
                    .onChange(of: liveActivityEnabled) { enabled in
                        model.setLiveActivityEnabled(enabled)
                    }
                    if DedicatedCallPolicy.vowlanOnly {
                        Toggle("后台更新设备状态", isOn: $liveActivityRemoteStatus)
                            .disabled(!liveActivityEnabled || !cloudSignalingEnabled)
                            .onChange(of: liveActivityRemoteStatus) { _ in
                                model.recreateLiveActivityForRemoteStatus()
                            }
                    }
                } header: {
                    Text("灵动岛与实时活动")
                } footer: {
                    if DedicatedCallPolicy.vowlanOnly && liveActivityRemoteStatus {
                        Text("后台更新通过推送显示安卓上报的设备状态。VoWLAN 状态以 iPhone 实际检测为准。")
                    } else {
                        Text("关闭后结束 AirSIM 的灵动岛与锁屏实时活动；通话和短信仍可正常使用。")
                    }
                }
                }

                if category == "灵动岛与小组件" && !DedicatedCallPolicy.vowlanOnly {
                Section {
                    ForEach(model.liveActivityOrderedAgents) { agent in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.deviceName)
                                    .lineLimit(1)
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
                            .accessibilityLabel(LiveActivityAgentOrder.isPinned(agent.id)
                                ? "取消置顶 \(agent.deviceName)" : "置顶 \(agent.deviceName)")
                            Button {
                                model.moveLiveActivityAgent(agent.id, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("上移 \(agent.deviceName)")
                            Button {
                                model.moveLiveActivityAgent(agent.id, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("下移 \(agent.deviceName)")
                        }
                    }
                } header: {
                    Text("灵动岛设备排序")
                } footer: {
                    Text("置顶设备固定在前；其余按这里排序。灵动岛每页最多显示 5 台，右上角按钮翻到下一页。")
                }
                }

                if category == "连接与设备" && DedicatedCallPolicy.vowlanOnly {
                    Section("推送 Relay") {
                        LabeledContent("当前地址", value: relayURL)
                            .textSelection(.enabled)
                    }
                }

                if category == "连接与设备" && !DedicatedCallPolicy.vowlanOnly {
                Section {
                    LabeledContent("远程通话与短信", value: runtimePolicy.startsCloud ? "已启用" : "已关闭")

                    TextField("https://relay.example.com", text: $relayURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!runtimePolicy.startsCloud)
                    Button("保存 Relay 地址") {
                        VoIPPushController.shared.updateRelayURL(relayURL)
                        Task {
                            if let (api, _) = await model.readyVoWLANRoute() {
                                await VoIPPushController.shared.syncRegistration(with: api)
                            }
                            await model.refreshCloudStatusForDiagnostics()
                        }
                        message = "地址已保存；配对后自动注册。"
                    }
                    .disabled(!runtimePolicy.startsCloud)
                    if let message { Text(message).foregroundStyle(.secondary) }
                } header: {
                    Text("云端 Relay")
                } footer: {
                    Text("云端关闭后，局域网内的三星 VoWLAN 仍可使用；公网拨打、接听和短信需要云端 Relay 与有效设备注册。")
                }
                }

                if category == "来电与短信" {
                Section("短信") {
                    Toggle("自动复制验证码到剪贴板", isOn: $autoCopySMSCode)
                    Text("收到新验证码短信后自动复制，便于系统键盘显示粘贴建议。会覆盖当前剪贴板内容，可随时关闭。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                }

                if category == "来电与短信" {
                Section("通知转发") {
                    NavigationLink {
                        NotificationForwardingView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("通知转发")
                                Text("短信与来电转发到 Bark、Discord、Slack、企业微信、飞书、Telegram、QQ 或 Webhook")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "paperplane") }
                    }
                }
                }

                if category == "帮助与诊断" {
                    Section {
                        NavigationLink {
                            AirSIMDiagnosticsView().environmentObject(model)
                        } label: {
                            Label("诊断与修复", systemImage: "stethoscope")
                        }
                        .accessibilityIdentifier("diagnostics.entry")
                    } footer: {
                        Text("检查连接、推送、通话音频与短信同步，查看修复结果和详细日志。")
                    }
                }

                if category == "外观与偏好" {
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

                if category == "帮助与诊断" {
                Section("反馈") {
                    TextField("用户描述（可选）", text: $feedbackDescription, axis: .vertical)
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
                        Label(feedbackUploading ? "正在上传…" : "立即上传反馈", systemImage: "paperplane")
                    }
                    .disabled(feedbackUploading)
                    if !feedbackUploadStatus.isEmpty {
                        Text(feedbackUploadStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("仅手动上传脱敏后的连接状态、Verbose 日志和 Android 日志；不上传短信内容、号码或密钥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { feedbackFocusedField = nil }
                }
            }
            .task { await model.refreshPairedDeviceInformation() }
            .fullScreenCover(item: $appUpdatePresentation, onDismiss: presentManualAppUpdateIfIdle) { presentation in
                AppUpdateSheet(presentation: presentation, updates: appUpdates)
            }
            .onAppear { updateViewVisible = true; presentManualAppUpdateIfIdle() }
            .onChange(of: model.activeCall?.id) { _ in handleUpdateCallChange() }
            .onChange(of: model.remoteCall?.id) { _ in handleUpdateCallChange() }
            .onChange(of: model.pendingOutgoingCall?.id) { _ in handleUpdateCallChange() }
            .onChange(of: updateScenePhase) { _ in presentManualAppUpdateIfIdle() }
            .onChange(of: model.errorMessage) { _ in presentManualAppUpdateIfIdle() }
            .confirmationDialog("删除已配对设备的信息？",
                isPresented: Binding(get: { deletingDevice != nil }, set: { if !$0 { deletingDevice = nil } }),
                titleVisibility: .visible, presenting: deletingDevice) { device in
                Button("删除 \(device.deviceName)", role: .destructive) {
                    deviceDeletionInProgress = true
                    deviceDeletionError = nil
                    Task {
                        defer { deviceDeletionInProgress = false }
                        do { try await model.forgetAndroidDevice(device.id) }
                        catch { deviceDeletionError = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("删除设备配置、连接地址和本机配对密钥，保留已有的通话记录和短信。删除后可以配对新设备。")
            }
            .navigationTitle(category ?? "设置")
            .onDisappear {
                updateViewVisible = false
            }
        }
    }

    @MainActor
    private func setPureLocalMode(_ enabled: Bool) async {
        guard !pureLocalBusy else { return }
        guard model.activeCall == nil else { pureLocalError = "通话中不能切换纯本地模式"; return }
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

    private var selectedMode: AirSIMConnectionMode {
        DedicatedCallPolicy.vowlanOnly ? .vowlan : (AirSIMConnectionMode(rawValue: connectionModeRaw) ?? .automatic)
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
                        TextField("Bot Token", text: $destination.token)
                            .textInputAutocapitalization(.never)
                    }
                    if destination.channel == .telegram || destination.channel == .qq {
                        TextField("Chat ID / OpenID", text: $destination.chatID)
                    }
                    if destination.channel == .feishu {
                        TextField("签名 Secret（可选）", text: $destination.secret)
                            .textInputAutocapitalization(.never)
                    }
                }
                Section("事件") {
                    Toggle("短信", isOn: $destination.sendSMS)
                    Toggle("来电", isOn: $destination.sendIncomingCall)
                    Toggle("未接来电", isOn: $destination.sendMissedCall)
                    Toggle("包含短信正文", isOn: $destination.includeBody)
                    Toggle("包含号码", isOn: $destination.includeNumber)
                }
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
            }
            .navigationTitle("转发目标")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(destination)
                        dismiss()
                    }
                }
            }
        }
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


private struct SettingsNavigationContainer<Content: View>: View {
    let isRoot: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        if isRoot { NavigationStack { content() } } else { content() }
    }
}

struct AirSIMDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var metadata = AirSIMHealthStore.load()
    @State private var permission = "尚未检查"
    @State private var soundPermission = "尚未检查"
    @State private var alertPermission = "尚未检查"
    @State private var relay = "尚未检查"
    @State private var agents: [CloudAndroidAgent] = []
    @State private var readiness: [String: AndroidReadiness] = [:]
    @State private var readinessErrors: [String: String] = [:]
    @State private var heartbeatResult = "尚未检查"
    @State private var checkedAt: Date?
    @State private var busy = false
    @State private var isolation: AndroidAudioIsolationEvidence?
    @State private var isolationDeviceID: String?
    @State private var isolationMessage = "尚未读取"
    @State private var readingIsolation = false
    @State private var selfTestReport: CloudSelfTestReport?
    @State private var selfTestRequest = 0
    @State private var selfTestRunning = false
    var body: some View {
        Form {
            AirSIMQuickRepairSections().environmentObject(model)
            Section("VoWLAN 通话") {
                LabeledContent("局域网直连", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                LabeledContent("Wi-Fi 路径", value: model.vowlan.wifiPathAvailable.map { $0 ? "可用" : "当前不可用" } ?? "尚未检查")
                LabeledContent("最近认证成功", value: time(model.vowlan.lastConnectionSuccess))
                if let reason = model.vowlan.lastConnectionFailure {
                    LabeledContent("最近连接失败", value: time(model.vowlan.lastConnectionFailureAt))
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("安卓麦克风与扬声器") {
                if let isolation, model.pairedDeviceHistory.contains(where: { $0.id == isolationDeviceID }) {
                    LabeledContent("最近静音验证", value: time(isolation.checkedAt))
                    if isolation.verificationFailed {
                        Label("最近一次静音验证未通过", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    LabeledContent("扬声器", value: isolationLabel(isolation.speakerMuted))
                    LabeledContent("麦克风", value: isolationLabel(isolation.microphoneMuted))
                    if let restoredAt = isolation.restoredAt {
                        LabeledContent("挂断后恢复本机音频", value: time(restoredAt))
                    }
                } else { Text(isolationMessage).foregroundStyle(.secondary) }
                Button(readingIsolation ? "正在读取…" : "读取安卓静音验证") {
                    Task { await refreshIsolation() }
                }.disabled(readingIsolation)
                Text("显示安卓最近一次可读取的系统静音检查。实际扬声器和拾音效果以通话实测为准。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Relay 推送") {
                LabeledContent("通知权限", value: permission)
                LabeledContent("通知声音权限", value: soundPermission)
                LabeledContent("通知提醒权限", value: alertPermission)
                LabeledContent("Relay 推送", value: CloudSignalingPreference.isEnabled() ? "已开启" : "已关闭")
                LabeledContent("Relay", value: relay)
                LabeledContent("安卓心跳查询", value: heartbeatResult)
                ForEach(model.pairedDeviceHistory) { device in
                    LabeledContent(device.deviceName, value: heartbeat(device.id))
                }
                if let checkedAt { LabeledContent("最近检查", value: time(checkedAt)) }
                Button(busy ? "正在检查…" : "立即检查") { Task { await refresh() } }.disabled(busy)
                Text("Relay 心跳检查最近约 150 秒的在线记录。通知送达时间见「最近推送接收」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("完整连接与推送自检") {
                Button(selfTestRunning ? "正在分步自检…" : "运行完整自检") {
                    selfTestReport = .initial(pushOnly: DedicatedCallPolicy.vowlanOnly); selfTestRunning = true; selfTestRequest += 1
                }
                .disabled(selfTestRunning || RelayEgressGate.shared.isBlocked
                    || !CloudSignalingPreference.isEnabled() || model.callLifecycleSnapshot.state.representsCall)
                if let report = selfTestReport {
                    ForEach(report.steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Group {
                                if step.state == .running { ProgressView() }
                                else { Image(systemName: step.state == .passed ? "checkmark.circle.fill" : step.state == .failed ? "exclamationmark.triangle.fill" : "circle") }
                            }.frame(width: 20)
                                .foregroundStyle(step.state == .passed ? Color.green : step.state == .failed ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title)
                                Text(step.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    if !selfTestRunning {
                        Text(report.allPassed ? "连接与推送自检通过" : "自检未通过，请查看具体失败步骤")
                            .foregroundStyle(report.allPassed ? .green : .orange)
                        Button("复制完整自检结果") { UIPasteboard.general.string = report.copyText }
                    }
                }
                Text(DedicatedCallPolicy.vowlanOnly
                     ? "读取本机推送凭据、Relay 身份、设备注册和安卓心跳。"
                     : "读取本机推送凭据、Relay 身份、设备注册、安卓心跳和定向命令能力。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("安卓启动就绪检查") {
                ForEach(model.pairedDeviceHistory) { device in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.deviceName).font(.headline)
                        if let value = readiness[device.id] {
                            Text("本次开机已运行 \(Int(value.uptimeSeconds / 60)) 分钟").font(.caption)
                            Label(value.defaultDialer ? "默认电话：已设置" : "默认电话：未设置", systemImage: value.defaultDialer ? "checkmark.circle" : "exclamationmark.triangle")
                            Text("拨号权限：\(value.phonePermission ? "已允许" : "未允许") · 通话状态权限：\(value.statePermission ? "已允许" : "未允许")")
                            Text("Shizuku／Root 通道：\(value.permissionChannel ? "已连接" : "尚未就绪，请检查安卓授权")")
                            Text("音频桥进程：\(value.bridgeProcess ? "运行中" : "尚未运行，请检查安卓")")
                            Text("直连配对：\(value.paired ? "存在" : "缺失，请重新配对")")
                        } else { Text(readinessErrors[device.id] ?? "尚未检查").foregroundStyle(.secondary) }
                    }.font(.subheadline)
                }
                Text("进程运行不等于端口或真实音频可用；重启后请保持安卓 AirSIM 与 Shizuku 授权正常。旧版本没有此接口时显示未知，不会误报就绪。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("挂断确认与音频自检") {
                if let value = model.remoteEndFeedback { Text(value) } else { Text("尚无本次运行期间的挂断确认记录") }
                Text(model.audio.audioHealthText)
                Button("恢复本机音频播放") { model.audio.recoverLocalPlayback() }
                    .disabled(!model.audio.active)
                Text("只恢复本机播放引擎，不重拨、不切换通话、不关闭安卓 PCM 会话。网络数据中断仍需恢复网络。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("最近推送接收") {
                LabeledContent("普通推送／通知扩展", value: time(metadata.lastAlert))
                LabeledContent("PushKit 来电推送", value: time(metadata.lastVoIP))
                Text("从此版本开始记录；没有记录不等于推送失败。系统是否唤醒 App 或通知扩展会影响记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("短信解密异常记录") {
                if metadata.failures.isEmpty { Text("暂无异常记录") }
                ForEach(metadata.failures) { failure in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(deviceName(failure.agentID)).font(.headline)
                        Text(failure.reason)
                        Text("\(time(failure.date)) · \(failure.resolved ? "此条已重新解密成功" : "待处理")")
                            .font(.caption).foregroundStyle(.secondary)
                        if !failure.resolved, let id = failure.agentID,
                           model.pairedDeviceHistory.contains(where: { $0.id == id }) {
                            NavigationLink("重新配对此设备（\(deviceName(id))）") {
                                SamsungPairingView().environmentObject(model)
                            }
                        }
                    }
                }
                if !metadata.failures.isEmpty {
                    Button("清除异常记录", role: .destructive) {
                        AirSIMHealthStore.clearHistory(); metadata = AirSIMHealthStore.load()
                    }
                }
                Text("只保留设备、时间和错误类别，不保存短信正文或密钥。重新配对成功后旧异常记录仍保留；旧密文不一定能用新密钥解密，可连接安卓同步本地短信。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("详细日志") {
                NavigationLink {
                    AgentVerboseTraceView(api: model.verboseDiagnosticsAPI)
                } label: {
                    Label("链路事件与日志导出", systemImage: "waveform.path.ecg")
                }
                Text("需要进一步排查时，再开启详细记录或导出脱敏日志。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("诊断与修复")
        .task(id: selfTestRequest) {
            guard selfTestRequest > 0 else { return }
            defer { selfTestRunning = false }
            selfTestReport = await VoIPPushController.shared.runCloudSelfTest { report in
                guard !Task.isCancelled else { return }
                selfTestReport = report
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            metadata = AirSIMHealthStore.load()
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { metadata = AirSIMHealthStore.load() }
        }
    }
    private func deviceName(_ id: String?) -> String {
        guard let id else { return "来源设备信息缺失" }
        return model.pairedDeviceHistory.first(where: { $0.id == id })?.deviceName ?? "历史设备 …\(id.suffix(6))"
    }
    private func time(_ date: Date?) -> String {
        date?.formatted(.dateTime.month().day().hour().minute().second()) ?? "暂无记录"
    }
    private func heartbeat(_ id: String) -> String {
        guard let agent = agents.first(where: { $0.agentID == id }) else { return "未获得此设备的心跳" }
        return agent.cloudOnline ? "Relay 心跳在线" : "Relay 心跳已过期"
    }
    private func isolationLabel(_ muted: Bool?) -> String {
        muted.map { $0 ? "静音已验证" : "静音验证未通过" } ?? "暂无验证记录"
    }

    @MainActor private func refreshIsolation() async {
        guard !readingIsolation else { return }
        guard let device = model.pairedDeviceHistory.first(where: { model.localDevices.api(for: $0.id) != nil }),
              let api = model.localDevices.api(for: device.id),
              case .vowlan = api.route else {
            isolation = nil
            isolationMessage = "请先恢复安卓 VoWLAN 直连"
            return
        }
        readingIsolation = true
        defer { readingIsolation = false }
        do {
            let snapshot = try await api.feedbackSnapshot()
            guard !Task.isCancelled, model.pairedDeviceHistory.contains(where: { $0.id == device.id }) else { return }
            let result = snapshot.bridgeLog.flatMap(AndroidAudioIsolationEvidence.init(bridgeLog:))
            if let result, isolation != result || isolationDeviceID != device.id {
                await AgentVerboseTraceRecorder.shared.recordEvent(source: "ANDROID", category: "call-audio",
                    phase: "android_audio_isolation", title: "安卓双静音验证",
                    fields: ["扬声器": isolationLabel(result.speakerMuted), "麦克风": isolationLabel(result.microphoneMuted),
                             "验证时间": time(result.checkedAt), "恢复时间": time(result.restoredAt)])
            }
            isolationDeviceID = device.id
            isolation = result
            isolationMessage = "安卓暂无静音验证记录"
        } catch {
            isolation = nil
            isolationMessage = "安卓静音记录读取失败：\(error.localizedDescription)"
        }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }; busy = true
        defer { busy = false; metadata = AirSIMHealthStore.load() }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: permission = "已允许"
        case .provisional: permission = "临时授权，通知可能静默显示"
        case .ephemeral: permission = "临时会话授权"
        case .denied: permission = "已拒绝，请到系统设置开启"
        case .notDetermined: permission = "尚未授权"
        @unknown default: permission = "未知授权状态"
        }
        soundPermission = settings.soundSetting == .enabled ? "已开启" : "未开启"
        alertPermission = settings.alertSetting == .enabled ? "已开启" : "未开启"
        guard !Task.isCancelled else { return }
        checkedAt = Date()
        readiness = [:]; readinessErrors = [:]
        for device in model.pairedDeviceHistory {
            guard !Task.isCancelled else { return }
            guard let api = model.localDevices.api(for: device.id) else {
                readinessErrors[device.id] = "尚未连接此安卓，请恢复直连后检查"; continue
            }
            do {
                if let result = try await api.androidReadiness().readiness { readiness[device.id] = result }
                else { readinessErrors[device.id] = "此安卓版本未提供启动检查，请更新安卓" }
            } catch { readinessErrors[device.id] = "启动检查未完成：\(error.localizedDescription)" }
        }
        guard CloudSignalingPreference.isEnabled(), !RelayEgressGate.shared.isBlocked else {
            relay = "未检查：云端通知关闭或纯本地模式"; agents = []; heartbeatResult = "未检查"; return
        }
        relay = "正在检查…"; heartbeatResult = "正在查询…"
        do { let version = try await VoIPPushController.shared.checkRelayForDiagnostics(); relay = "可达 · \(version)" }
        catch { relay = "检查失败：\(error.localizedDescription)" }
        guard !Task.isCancelled else { return }
        do {
            let status = try await VoIPPushController.shared.fetchCloudAgentStatusForDiagnostics(allowLocalMode: true)
            agents = status.agents; heartbeatResult = "查询成功"
        } catch { agents = []; heartbeatResult = "查询失败：\(error.localizedDescription)" }
    }
}

private struct AirSIMQuickRepairSections: View {
    @EnvironmentObject private var model: AppModel
    @State private var busy = false
    @State private var lanHost = ""
    @State private var report = "尚未检查"
    private var inCall: Bool { model.callLifecycleSnapshot.state.representsCall }
    var body: some View {
        Group {
            Section("快速检查与修复") {
                Button("一键检查") { run(repair: false) }.disabled(busy)
                Button("修复连接与短信同步") { run(repair: true) }.disabled(busy || inCall)
                if busy { ProgressView() }
                Text(inCall ? "正在通话，仅检查状态，不重启服务或重建连接。" : "修复会重新查询已配对安卓并刷新短信，不删除配对或历史记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !model.pairedDeviceHistory.isEmpty {
                Section("恢复局域网直连") {
                    TextField("安卓当前 Wi-Fi IPv4 地址", text: $lanHost)
                        .keyboardType(.decimalPad).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("diagnostics.lanHost")
                    Button("验证并恢复局域网连接") { repairLAN() }
                        .disabled(busy || inCall || lanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("diagnostics.repairLAN")
                    Text("自动发现不可用时，填写安卓当前 Wi-Fi 地址。使用原配对密钥验证设备，只更新连接地址，不删除短信、通话记录或配对。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("网络连接详情") {
                Text(model.networkConnectionReport).font(.footnote).textSelection(.enabled)
                Text("正在恢复表示近期连接曾通过认证，事件通道正在重新核验；不代表请求一定成功。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("归属地与推送耗时") {
                Button("补全历史通话归属地") {
                    busy = true
                    Task { @MainActor in
                        let count = await model.backfillHistoryRegions(force: true)
                        report = "已补全 \(count) 条通话归属地；安卓尚无归属地的记录继续使用离线库。"
                        busy = false
                    }
                }.disabled(busy || inCall)
                Text(AirSIMHealthStore.deliveryReport()).font(.footnote).textSelection(.enabled)
                Text("缺少的时间不会估算；显示的跨设备时间差可能包含时钟偏差。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if report != "尚未检查" {
                Section("快速检查结果") {
                    Text(report).textSelection(.enabled)
                    ShareLink(item: report) { Label("导出快速检查结果", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }
    private func repairLAN() {
        guard !busy, !inCall,
              let id = AndroidAgentBindingPreference.selected() ?? model.pairedDeviceHistory.first?.id else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let host = lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
                guard VoWLANEndpoint.permitsDirectIPv4(host) else {
                    report = "未更新连接地址：请填写有效的私网 IPv4 地址，例如 192.168.200.24（四段数字，每段 0–255，以英文句点分隔）。"
                    return
                }
                let previous = VoWLANManualRouteStore.routes().first { $0.agentID == id && !$0.isRemote }
                let route = VoWLANManualRoute(agentID: id,
                    host: host,
                    controlPort: previous?.controlPort ?? 7592, pcmPort: previous?.pcmPort ?? 7593)
                try await model.vowlan.repairLocalRoute(route)
                report = "局域网地址已通过原配对密钥和设备身份验证，连接地址已保存。"
                await model.refreshPairedDeviceInformation()
            } catch { report = "未更新连接地址：\(error.localizedDescription)" }
        }
    }
    private func run(repair: Bool) {
        guard !busy else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            if repair && !inCall {
                await model.refreshPairedDeviceInformation()
                if !inCall { await model.refreshMessages(silently: true) }
                WatchCallCoordinator.shared.start()
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            report = "已配对安卓：\(PairedAndroidDeviceStore.records().count) 台\n连接：\(model.isOnline ? "在线" : "尚未连接")\n通知：\(settings.authorizationStatus == .authorized ? "已允许" : "请检查系统授权")\n通话保护：\(inCall ? "已启用" : "当前无通话")\n音频输出：\(model.audio.callOutputName)"
            if repair { report += "\n已执行：连接信息重新查询、短信刷新、Watch 通道检查。请根据上述结果确认是否恢复。" }
        }
    }
}
