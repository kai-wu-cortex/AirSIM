import SwiftUI

struct SamsungPairingView: View {
    /// This toggle only controls whether Relay/APNs registration is written.
    /// It never changes the media connection mode.
    static var defaultLocalPairingOnly: Bool { !CloudSignalingPreference.isEnabled() }
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var localPairingOnly = SamsungPairingView.defaultLocalPairingOnly
    @StateObject private var browser = SamsungPairingBrowser()
    @State private var code = ""
    @State private var pairingServiceID: String?
    @State private var message = ""
    @State private var manual = false
    @State private var host = ""
    @State private var port = ""
    @State private var pairingTask: Task<Void, Never>?
    @State private var isVisible = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $localPairingOnly) {
                    Label("仅本次配对不写入云端", systemImage: "wifi")
                }
                .disabled(pairingServiceID != nil)
                .accessibilityIdentifier("localPairingOnly")
                Text(localPairingOnly
                     ? "本次配对只写入 VoWLAN 密钥，不写入 Relay/APNs。不会改变当前通话媒体模式。"
                     : "本次配对额外写入 Relay/APNs；仅用于通知，不会改变当前通话媒体模式。VoWLAN 仍只走局域网。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("连接步骤") {
                Label("让安卓与本机连接同一 Wi-Fi", systemImage: "wifi")
                Label("也可让本机连接安卓移动热点", systemImage: "personalhotspot")
                Label("在安卓 App 点击“开始一次性配对”", systemImage: "key")
            }

            Section("配对方式") {
                Picker("配对方式", selection: $manual) {
                    Text("自动发现").tag(false)
                    Text("手动地址").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(pairingServiceID != nil)
            }

            if manual {
                Section {
                    TextField("安卓 IPv4，例如 192.168.1.2、100.64.1.2 或 30.0.0.2", text: $host)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("manualPairingHost")
                    TextField("安卓本次配对端口", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("manualPairingPort")
                    codeField
                    Button("连接并加密配对", systemImage: "lock.shield") {
                        pairingTask = Task { await pairManually() }
                    }
                    .disabled(code.count != 6 || host.isEmpty || port.isEmpty || pairingServiceID != nil)
                    if pairingServiceID != nil { ProgressView("正在连接与认证…") }
                } header: { Text("手动地址配对") } footer: {
                    Text("先在安卓打开一次性配对窗口，填写该页的配对端口，不是 ADB 或通话端口。使用 Tailscale 时填安卓的 Tailscale IPv4，两端须已接入且允许互访；无需开启 AirSIM 云端模式。"
                        + "若局域网使用特殊网段（如 30.0.0.0/8），先在设置 → 私有网络中添加该网段。配对后选择 VoWLAN 或自动连接模式。")
                }
                .disabled(pairingServiceID != nil)
            } else {
              Section("发现的设备") {
                if browser.services.isEmpty {
                    HStack {
                        ProgressView()
                        Text(browser.stateText).foregroundStyle(.secondary)
                    }
                }
                ForEach(browser.services) { service in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(service.displayName, systemImage: "iphone.radiowaves.left.and.right")
                            .font(.headline)
                        codeField
                        Button("加密配对", systemImage: "lock.shield") {
                            pairingTask = Task { await pair(service) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.count != 6 || pairingServiceID != nil)
                    }
                    .padding(.vertical, 4)
                }
                Button("重新扫描", systemImage: "arrow.clockwise") {
                    browser.restart()
                }
                .disabled(pairingServiceID != nil)
                Text("请在安卓打开一次性配对窗口，并允许 iPhone 的本地网络访问。回到 App 或切回自动发现时会重新扫描；路由器隔离或不支持广播的 VPN 可使用手动地址。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
              }
            }

            if !message.isEmpty {
                Section("结果") { Text(message) }
            }
        }
        .navigationTitle("配对安卓手机")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isVisible = true
            if !manual { browser.start() }
        }
        .onChange(of: manual) { value in
            if value { browser.stop() } else { browser.start() }
            code = ""
            message = ""
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                browser.stop()
            } else if isVisible, phase == .active, !manual, pairingServiceID == nil {
                browser.restart()
            }
        }
        .onDisappear {
            isVisible = false
            browser.stop()
            pairingTask?.cancel()
        }
    }

    private var codeField: some View {
        TextField("安卓显示的 6 位验证码", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .onChange(of: code) { value in
                code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            }
    }

    @MainActor
    private func pairManually() async {
        pairingServiceID = "manual"
        message = "正在连接安卓配对窗口…"
        defer { pairingServiceID = nil }
        do {
            let address = try SamsungManualPairingAddress(host: host, port: port)
            message = try await VoIPPushController.shared.performAndroidPairing(localOnly: localPairingOnly) { registration, offerE2E in
                let result = try await SamsungPairingClient.pairManually(address: address, code: code,
                    registration: registration, offerE2E: offerE2E)
                try Task.checkCancellation()
                let e2e = E2EPairingKeyChange.after(localOnly: localPairingOnly, sentKey: result.e2eKey,
                                                    deviceID: registration.deviceID)
                try await model.completeLocalPairing(agentID: result.route.agentID,
                    registration: registration, endpoint: result.route.endpoint,
                    clockOffset: result.clockOffset, e2e: e2e)
                try await model.vowlan.installManualRoute(result.route)
                if !localPairingOnly { model.setCloudSignalingEnabled(true) }
                let paired = "配对成功" + (e2e?.successSuffix(agentID: result.route.agentID) ?? "")
                // Tailscale/5G can need a moment before the control port is
                // reachable after the pairing window closes.
                for attempt in 0..<3 {
                    if model.vowlan.availability.isOnlineForDisplay {
                        return "\(paired)，直连网关已通过认证。选择 VoWLAN 或自动连接模式后可用于通话与短信。"
                    }
                    guard attempt < 2 else { break }
                    try? await Task.sleep(for: .milliseconds(400))
                    await model.vowlan.probeNow()
                }
                return "\(paired)，地址已保存，但直连网关暂不可达。请检查网络、Tailscale 访问规则与安卓 PCM 桥；不会回退写入 Relay。"
            }
        } catch is CancellationError {
            message = "已取消连接"
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func pair(_ service: SamsungPairingService) async {
        pairingServiceID = service.id
        message = localPairingOnly
            ? "正在加密并写入 VoWLAN 本地密钥…"
            : "正在加密并写入 Android Agent…"
#if DEBUG
        print("[AirSIM Pair] claim_started session=\(service.sessionID)")
#endif
        defer { pairingServiceID = nil }
        do {
            message = try await VoIPPushController.shared.performAndroidPairing(
                localOnly: localPairingOnly
            ) { registration, offerE2E in
                let paired = try await SamsungPairingClient.pairDevice(
                        service: service,
                        code: code,
                        registration: registration,
                        offerE2E: offerE2E
                    )
                let e2e = E2EPairingKeyChange.after(localOnly: localPairingOnly, sentKey: paired.e2eKey,
                                                    deviceID: registration.deviceID)
                try await model.completeLocalPairing(agentID: paired.agentID, registration: registration, e2e: e2e)
                if !localPairingOnly { model.setCloudSignalingEnabled(true) }
                return model.localDevices.api(for: paired.agentID) == nil
                    ? "加密配对已写入安卓，正在等待通话网关身份验证；暂未建立可用路由。"
                    : paired.message + (e2e?.successSuffix(agentID: paired.agentID) ?? "")
            }
#if DEBUG
            print("[AirSIM Pair] claim_completed session=\(service.sessionID)")
#endif
        } catch is CancellationError {
            message = "已取消连接"
        } catch {
            message = "配对失败：\(error.localizedDescription)"
#if DEBUG
            print("[AirSIM Pair] claim_failed session=\(service.sessionID) error=\(String(describing: type(of: error)))")
#endif
        }
    }
}
