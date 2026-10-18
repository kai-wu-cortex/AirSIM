import SwiftUI

/// AirSIM 只引导三星配对；不检查旧模块 USB ECM、AT 或 QDC507 固件。
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
                    Text("连接三星手机")
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
                .pickerStyle(.segmented)
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

struct AirSIMSettingsView: View {
    private enum SelfTestPhase {
        case idle
        case running
        case completed
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                    Text(selectedMode.detail)
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

                Section("三星连接") {
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    NavigationLink {
                        SamsungPairingView()
                    } label: {
                        Label("配对安卓手机", systemImage: "personalhotspot")
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
                        model.voble.stop()
                        model.voble.start()
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
                                    Text(step.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if selfTestPhase == .completed {
                            Text(report.allPassed ? "云端模式自检通过" : "自检未通过，请按失败步骤修复后重试")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(report.allPassed ? .green : .orange)
                        }
                    }
                } header: {
                    Text("云端模式自检")
                } footer: {
                    Text(!runtimePolicy.startsCloud
                        ? "当前连接模式不运行云端自检。"
                        : "依次验证本机 Push 凭据、AirSIM Relay 身份、设备注册和 Agent 最近 90 秒心跳；不会拨号或发送短信。")
                }

                Section("关于") {
                    LabeledContent("项目", value: "AirSIM")
                    LabeledContent("版本", value: AppInformation.version)
                        .textSelection(.enabled)
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
                selfTestTask?.cancel()
                selfTestTask = nil
                if selfTestPhase == .running { selfTestPhase = .idle }
            }
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

    private var voBLEStatus: String {
        switch model.voble.state {
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
