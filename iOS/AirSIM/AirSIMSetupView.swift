import SwiftUI
import UIKit

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
    Form { Section("三星连接") { PairedAndroidDeviceRows(devices: [], onDelete: { _ in }) } }
}

#Preview("已配对设备 · 在线与离线") {
    Form {
        Section("三星连接") {
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
                Picker("已配对设备", selection: $agentID) {
                    Text("选择安卓手机").tag("")
                    ForEach(model.pairedDeviceHistory) { device in
                        Text(device.deviceName).tag(device.id)
                    }
                }
                Toggle("启用自建域名直连", isOn: $enabled)
                    .disabled(agentID.isEmpty)
            } footer: {
                Text("先在局域网完成 VoWLAN 配对，再为这台手机配置 NAS 或软路由的加密入口。默认关闭，保存后生效。")
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
        .navigationTitle("自建域名直连")
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
    @AppStorage(LiveActivityVisibilityPreference.key) private var liveActivityEnabled = true
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
    @State private var networkPrefixesText = NetworkRoutePreferences.storedText()
    @State private var networkPrefixError: String?
    @FocusState private var networkPrefixesFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { !runtimePolicy.startsCloud },
                        set: { enabled in
                            connectionModeRaw = ConnectionModePreference.selectingLocalOnly(
                                enabled, from: selectedMode).rawValue
                        }
                    )) {
                        Label("仅本地模式", systemImage: "network.slash")
                    }
                    .accessibilityIdentifier("localOnlyMode")
                    Picker("连接模式", selection: $connectionModeRaw) {
                        ForEach(AirSIMConnectionMode.allCases) { mode in
                            Label(mode.title, systemImage: modeIcon(mode)).tag(mode.rawValue)
                        }
                    }
                    .onChange(of: connectionModeRaw) { rawValue in
                        guard let mode = AirSIMConnectionMode(rawValue: rawValue) else { return }
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        model.setConnectionMode(mode)
                    }
                } header: {
                    Text("运行模式")
                } footer: {
                    Text(selectedMode.detail + "\n仅本地模式与连接模式同步；关闭表示允许云端，安卓仍需完成云端配对。")
                }

                Section("当前连接") {
                    LabeledContent("当前模式", value: model.connectionModePresentation.title)
                    LabeledContent("连接状态", value: model.connectionModePresentation.status)
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    LabeledContent(
                        "云端 Relay",
                        value: runtimePolicy.startsCloud
                            ? (model.cloudAgentStatus?.cloudOnline == true ? "Agent 在线" : "不可达")
                            : "当前模式已关闭"
                    )
                    Text(model.connectionModePresentation.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let connectionMessage = model.connectionMessage, !connectionMessage.isEmpty {
                        Text(connectionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

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

                Section("三星连接") {
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    NavigationLink {
                        SamsungPairingView()
                    } label: {
                        Label("配对安卓手机", systemImage: "personalhotspot")
                    }
                    NavigationLink {
                        RemoteDirectSettingsView()
                    } label: {
                        Label("自建域名直连（可选）", systemImage: "network.badge.shield.half.filled")
                    }
                    PairedAndroidDeviceRows(devices: model.pairedDeviceHistory, onDelete: { deletingDevice = $0 })
                        .disabled(deviceDeletionInProgress)
                    Button("重新发现", systemImage: "arrow.clockwise") {
                        model.vowlan.restartBrowsing()
                        Task { await model.vowlan.probeNow() }
                    }
                }

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

                if runtimePolicy.startsBluetooth {
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

                Section {
                    LabeledContent("远程通话与短信", value: runtimePolicy.startsCloud ? "已启用" : "已关闭")

                    TextField("https://relay.example.com", text: $relayURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!runtimePolicy.startsCloud)
                    Button("保存 Relay 地址") {
                        VoIPPushController.shared.updateRelayURL(relayURL)
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
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
                    .disabled(!runtimePolicy.startsCloud || selfTestPhase == .running)

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
                                        .font(.caption)
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
                                message = "自检结果已复制"
                            } label: {
                                Label("复制自检结果", systemImage: "doc.on.doc")
                            }
                            .font(.footnote)
                        }
                    }
                } header: {
                    Text("云端模式自检")
                } footer: {
                    Text(!runtimePolicy.startsCloud
                        ? "当前连接模式不运行云端自检。"
                        : "依次验证本机 Push 凭据、Relay 身份、设备注册、Agent 记录、90 秒心跳和命令路由；失败步骤会给出具体卡点，不会拨号或发送短信。")
                }

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

                Section("调试") {
                    NavigationLink {
                        AgentVerboseTraceView(api: model.verboseDiagnosticsAPI)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Verbose 日志调试")
                                Text("开启详细记录、查看链路事件、导出 TXT")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "waveform.path.ecg") }
                    }
                }

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
                    Picker("外观", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                }
            }
            .task { await model.refreshPairedDeviceInformation() }
            .sheet(item: $appUpdatePresentation, onDismiss: presentManualAppUpdateIfIdle) { presentation in
                AppUpdateSheet(presentation: presentation, updates: appUpdates)
            }
            .onAppear { updateViewVisible = true; presentManualAppUpdateIfIdle() }
            .onChange(of: model.activeCall?.id) { _ in handleUpdateCallChange() }
            .onChange(of: model.remoteCall?.id) { _ in handleUpdateCallChange() }
            .onChange(of: model.pendingOutgoingCall?.id) { _ in handleUpdateCallChange() }
            .onChange(of: updateScenePhase) { _ in presentManualAppUpdateIfIdle() }
            .onChange(of: model.errorMessage) { _ in presentManualAppUpdateIfIdle() }
            .confirmationDialog("删除这个设备的本机配对记录？",
                isPresented: Binding(get: { deletingDevice != nil }, set: { if !$0 { deletingDevice = nil } }),
                titleVisibility: .visible, presenting: deletingDevice) { device in
                Button("删除 \(device.deviceName)", role: .destructive) {
                    deviceDeletionInProgress = true
                    Task {
                        defer { deviceDeletionInProgress = false }
                        do { try await model.forgetAndroidDevice(device.id) }
                        catch { message = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("清除本机记录、绑定和缓存；不会删除通话或短信。此设备需要重新配对才能自动连接，其他设备不受影响。离线设备的远端凭据不会因此自动撤销。")
            }
            .navigationTitle("设置")
            .onDisappear {
                updateViewVisible = false
                selfTestTask?.cancel()
                selfTestTask = nil
                if selfTestPhase == .running { selfTestPhase = .idle }
            }
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
        selfTestTask?.cancel()
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
            await model.refreshCloudStatusForDiagnostics()
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
