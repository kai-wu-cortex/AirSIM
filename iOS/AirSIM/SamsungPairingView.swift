import SwiftUI

struct SamsungPairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var localPairingOnly = LocalModePreference.isEnabled()
    @StateObject private var browser = SamsungPairingBrowser()
    @State private var code = ""
    @State private var pairingServiceID: String?
    @State private var message = ""
    @State private var manual = false
    @State private var host = ""
    @State private var port = ""
    @State private var pairingTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $localPairingOnly) {
                    Label("本地模式配对", systemImage: "wifi")
                }
                .disabled(pairingServiceID != nil)
                .accessibilityIdentifier("localPairingOnly")
                Text(localPairingOnly
                     ? "本次配对只写入 VoWLAN 密钥，不检查或写入 Relay 和推送参数。不会改变全局通话模式。"
                     : "本次配对写入 VoWLAN 密钥及 Relay／推送配置；需要云端凭据就绪。不会改变全局通话模式。")
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
                    TextField("安卓 IPv4，例如 192.168.1.2 或 100.64.1.2", text: $host)
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
                    Text("先在安卓打开一次性配对窗口，填写该页的配对端口，不是 ADB 或通话端口。使用 Tailscale 时填安卓的 Tailscale IPv4，两端须已接入且允许互访；无需开启 AirSIM 云端模式。配对后选择 VoWLAN 或自动连接模式。")
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
              }
            }

            if !message.isEmpty {
                Section("结果") { Text(message) }
            }
        }
        .navigationTitle("配对安卓手机")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !manual { browser.start() } }
        .onChange(of: manual) { value in
            if value { browser.stop() } else { browser.start() }
            code = ""
            message = ""
        }
        .onDisappear { browser.stop(); pairingTask?.cancel() }
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
            message = try await VoIPPushController.shared.performAndroidPairing(localOnly: localPairingOnly) { registration in
                let result = try await SamsungPairingClient.pairManually(address: address, code: code, registration: registration)
                try Task.checkCancellation()
                try await model.vowlan.installManualRoute(result.route)
                return model.vowlan.availability.isOnlineForDisplay
                    ? "配对成功，直连网关已通过认证。选择 VoWLAN 或自动连接模式后可用于通话与短信。"
                    : "配对成功，地址已保存，但直连网关暂不可达。请检查网络、Tailscale 访问规则与安卓 PCM 桥；不会回退写入 Relay。"
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
            ) { registration in
                try await SamsungPairingCompletionCoordinator.complete(
                performPairing: {
                    try await SamsungPairingClient.pair(
                        service: service,
                        code: code,
                        registration: registration
                    )
                },
                refreshVoWLAN: {
                    await model.vowlan.refreshAfterPairing()
                }
                )
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
