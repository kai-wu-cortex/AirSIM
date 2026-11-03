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
    private enum Method { case automatic, privateIP, publicDomain }
    @State private var method: Method = .automatic
    private var manual: Bool { method != .automatic }
    private var usesTLS: Bool { method == .publicDomain }
    @State private var host = ""
    @State private var port = ""
    @State private var controlPort = "443"
    @State private var pcmPort = "7593"
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
                     : "本次配对额外写入 Relay/APNs；仅用于通知，不会改变当前通话媒体模式。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("连接步骤") {
                if usesTLS {
                    Label("NAS 或路由器已配置有效证书的 TLS 转发", systemImage: "lock.shield")
                    Label("临时启用配对入口，完成后关闭该入口", systemImage: "network")
                } else {
                    Label("让安卓与本机连接同一 Wi-Fi", systemImage: "wifi")
                    Label("也可让本机连接安卓移动热点", systemImage: "personalhotspot")
                }
                Label("在安卓 App 点击“开始一次性配对”", systemImage: "key")
            }

            Section("配对方式") {
                Picker("配对方式", selection: $method) {
                    Text("自动发现").tag(Method.automatic)
                    Text("私网 IP").tag(Method.privateIP)
                    Text("公网域名").tag(Method.publicDomain)
                }
                .pickerStyle(.segmented)
                .disabled(pairingServiceID != nil)
                Text("公网域名配对为试验性功能，真实公网配对与双向音频仍待真机验收。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if usesTLS {
                Section {
                    RemoteDirectGuideEntry(context: .firstPairing)
                }
            }

            if manual {
                Section {
                    TextField(usesTLS ? "HTTPS 域名，例如 phone.example.com" : "安卓 IPv4，例如 192.168.1.2 或 100.64.1.2", text: $host)
                        .keyboardType(usesTLS ? .URL : .decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("manualPairingHost")
                    TextField(usesTLS ? "HTTPS 配对端口，例如 9443" : "安卓本次配对端口", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("manualPairingPort")
                    if usesTLS {
                        TextField("HTTPS 控制端口", text: $controlPort).keyboardType(.numberPad)
                            .accessibilityIdentifier("publicPairingControlPort")
                        TextField("TLS 音频端口", text: $pcmPort).keyboardType(.numberPad)
                            .accessibilityIdentifier("publicPairingPCMPort")
                    }
                    codeField
                    Button("连接并加密配对", systemImage: "lock.shield") {
                        pairingTask = Task { await pairManually() }
                    }
                    .disabled(code.count != 6 || host.isEmpty || port.isEmpty || pairingServiceID != nil)
                    if pairingServiceID != nil { ProgressView("正在连接与认证…") }
                } header: { Text(usesTLS ? "公网域名配对（试验性 · HTTPS）" : "手动地址配对") } footer: {
                    if usesTLS {
                        Text("填写域名，不含 https:// 或路径。三个端口都是 NAS 对外提供的 TLS 端口；配对端口转发到安卓本次配对窗口，控制与音频各自转发。证书必须可信且匹配域名，不支持明文公网连接或跳过证书校验。无需开启 AirSIM 云端模式。")
                    } else {
                      Text("先在安卓打开一次性配对窗口，填写该页的配对端口，不是 ADB 或通话端口。使用 Tailscale 时填安卓的 Tailscale IPv4，两端须已接入且允许互访；无需开启 AirSIM 云端模式。"
                        + "若局域网使用特殊网段（如 30.0.0.0/8），先在设置 → 私有网络中添加该网段。配对后选择 VoWLAN 或自动连接模式。")
                    }
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
        .onChange(of: method) { value in
            if value != .automatic { browser.stop() } else { browser.start() }
            host = ""
            port = value == .publicDomain ? "9443" : ""
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
            let address = try SamsungManualPairingAddress(host: host, port: port, usesTLS: usesTLS,
                controlPort: controlPort, pcmPort: pcmPort)
            message = try await VoIPPushController.shared.performAndroidPairing(localOnly: localPairingOnly) { registration in
                let result = try await SamsungPairingClient.pairManually(address: address, code: code, registration: registration)
                try Task.checkCancellation()
                try await model.completeLocalPairing(agentID: result.route.agentID,
                    registration: registration, endpoint: result.route.endpoint,
                    clockOffset: result.clockOffset)
                if address.usesTLS {
                    do {
                        try await model.configureRemoteDirect(agentID: result.route.agentID, route: result.route)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        return "安卓加密配对成功，但公网控制入口尚未通过设备身份验证，域名路由未保存。请检查控制端口转发，然后在‘自建域名直连’重试：\(error.localizedDescription)"
                    }
                    if !localPairingOnly { model.setCloudSignalingEnabled(true) }
                    return "公网域名配对成功，控制入口与设备身份已验证。选择 VoWLAN 或自动模式并选中此设备后可使用；音频端口需在实际通话时验证。"
                }
                try await model.vowlan.installManualRoute(result.route)
                if !localPairingOnly { model.setCloudSignalingEnabled(true) }
                // Tailscale/5G can need a moment before the control port is
                // reachable after the pairing window closes.
                for attempt in 0..<3 {
                    if model.vowlan.availability.isOnlineForDisplay {
                        return "配对成功，直连网关已通过认证。选择 VoWLAN 或自动连接模式后可用于通话与短信。"
                    }
                    guard attempt < 2 else { break }
                    try? await Task.sleep(for: .milliseconds(400))
                    await model.vowlan.probeNow()
                }
                return "配对成功，地址已保存，但直连网关暂不可达。请检查网络、Tailscale 访问规则与安卓 PCM 桥；不会回退写入 Relay。"
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
                let paired = try await SamsungPairingClient.pairDevice(
                        service: service,
                        code: code,
                        registration: registration
                    )
                try await model.completeLocalPairing(agentID: paired.agentID, registration: registration)
                if !localPairingOnly { model.setCloudSignalingEnabled(true) }
                return model.localDevices.api(for: paired.agentID) == nil
                    ? "加密配对已写入安卓，正在等待通话网关身份验证；暂未建立可用路由。" : paired.message
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


/// Contextual help only: reading the guide never writes pairing or route settings.
enum RemoteDirectGuideContext: String, CaseIterable, Identifiable {
    case firstPairing = "首次公网配对"
    case existingDevice = "已配对设备"
    var id: Self { self }
}

struct RemoteDirectGuideEntry: View {
    let context: RemoteDirectGuideContext
    @State private var showingGuide = false
    @State private var detent: PresentationDetent = .large

    var body: some View {
        Button {
            detent = .large
            showingGuide = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("使用教程").foregroundStyle(.primary)
                    Text("准备条件、端口转发与配对步骤")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("remoteDirectGuide")
        .sheet(isPresented: $showingGuide) {
            RemoteDirectGuideView(context: context)
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationDragIndicator(.visible)
        }
    }
}

struct RemoteDirectGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var context: RemoteDirectGuideContext
    @State private var copied = false

    init(context: RemoteDirectGuideContext) {
        _context = State(initialValue: context)
    }

    private var firstPairing: Bool { context == .firstPairing }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("试验性功能", systemImage: "flask")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("通过自己的域名连接安卓，无需 AirSIM Relay。真实公网配对与双向音频仍待真机验收。")
                    Picker("使用场景", selection: $context) {
                        ForEach(RemoteDirectGuideContext.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("开始前准备") {
                    requirement("新版 iPhone App", symbol: "iphone",
                        detail: "需要包含此试验性功能的版本。安卓使用已支持一次性配对、VoWLAN 和 PCM 的版本即可。")
                    requirement("域名与可信证书", symbol: "lock.shield",
                        detail: "例如 phone.example.com。证书须匹配域名且未过期，不支持跳过证书校验。")
                    requirement("可从外网访问的 TLS 网关", symbol: "network",
                        detail: "NAS 或软路由需有可入站的公网 IPv4 或 IPv6，并能从可信私网访问安卓。仅配置 DDNS 不等于能够穿透运营商 NAT。")
                    DisclosureGroup("没有公网入口怎么办？") {
                        Text("可继续使用现有的私网 IP／Tailscale 配对。这份域名教程不会自动建立 NAT 穿透；仅有普通网站托管空间也不能转发 PCM 音频。")
                            .font(.subheadline)
                    }
                }

                Section("1 · 准备安卓与网关") {
                    requirement("启动 VoWLAN 和 PCM 服务", symbol: "antenna.radiowaves.left.and.right",
                        detail: "让安卓与网关处于同一可信局域网。建议给安卓设置 DHCP 地址保留，例如 192.168.1.50。")
                    requirement("解析域名并配置 TLS", symbol: "server.rack",
                        detail: "域名指向网关可达的公网地址，配置端口放行与可信证书。可用 stunnel 或 nginx stream 转发原始 TCP；普通网页反向代理不能承载 PCM 音频。")
                    if !firstPairing {
                        Text("先确认这台安卓已经完成 VoWLAN 配对。只有蓝牙配对、没有 VoWLAN 密钥时，需要先完成一次 VoWLAN 配对。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if firstPairing {
                        portRow("临时配对 · HTTPS", external: "9443", target: "安卓本次配对窗口的随机端口")
                    }
                    portRow("通话控制 · HTTPS", external: "443", target: "安卓实际控制端口，通常为 7592")
                    portRow("音频 · TCP TLS", external: "17593", target: "安卓实际 PCM 端口，通常为 7593")
                    if firstPairing {
                        Text("在安卓点击“开始一次性配对”，再把临时配对转发的后端端口改成窗口显示的端口。新开窗口可能换端口，请同步更新。")
                            .font(.subheadline)
                    }
                    DisclosureGroup("查看网关配置示例") {
                        Text("以下为 stunnel 服务端示例。请替换域名证书路径、安卓地址与实际端口，再按网关的服务管理方式加载配置。")
                            .font(.subheadline)
                        Text(gatewayExample)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            UIPasteboard.general.string = gatewayExample
                            copied = true
                        } label: {
                            Label(copied ? "已复制示例" : "复制配置示例",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("copyRemoteDirectExample")
                    }
                } header: {
                    Text("2 · 配置端口转发")
                } footer: {
                    Text("iPhone → 网关 TLS 入口 → 安卓私网接口。端口仅为示例，iPhone 应填写实际对外端口。不要直接向公网映射安卓明文接口；音频与控制必须指向同一台安卓。")
                }

                Section(firstPairing ? "3 · 在 iPhone 加密配对" : "3 · 验证并保存域名") {
                    Text(firstPairing
                        ? "返回配对页，选择“公网域名”，填写域名、HTTPS 配对端口、HTTPS 控制端口、TLS 音频端口和安卓六位验证码，再点击“连接并加密配对”。"
                        : "返回“自建域名直连”，选择已配对安卓并打开启用开关，填写域名、HTTPS 控制端口与 TLS 音频端口，点击“验证并保存”。")
                    Label("域名填写 phone.example.com", systemImage: "text.cursor")
                    Text("不带 https://、路径或端口。只有证书和该安卓设备的身份验证通过，域名路由才会保存。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Section("4 · 验证通话与短信") {
                    Text("选中安卓设备，使用 VoWLAN、自动或 VoWLAN+VoBLE 模式。让 iPhone 使用外部网络，测试短信、接听、拨出与双向声音。控制入口通过验证，不代表音频已经可用。")
                    if firstPairing {
                        Label("配对完成后关闭临时配对入口", systemImage: "lock")
                        Text("仅保留控制与音频 TLS 入口；以后重新配对时再临时开启。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("域名直连不会自动开启 Relay。需要完全禁止 Relay 时开启纯本地模式；直连成功也不代表 iOS 锁屏后能持续收到来电，此功能不新增后台推送。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Section("遇到问题") {
                    DisclosureGroup("配对成功，但控制入口验证失败") {
                        Text("配对密钥会保留。检查证书、域名解析和控制端口是否转发到同一台安卓，然后在“自建域名直连”选择该设备重试，无需先删除设备。")
                    }
                    DisclosureGroup("能控制，但通话没有声音") {
                        Text("检查音频端口是否使用原始 TCP TLS 转发、是否放行，以及安卓 PCM 服务是否启动。HTTP 网页代理和普通 Cloudflare 网页代理不能替代 PCM 转发。")
                    }
                    DisclosureGroup("外网可用，家中 Wi-Fi 不可用") {
                        Text("路由器可能不支持 NAT 回流。先使用蜂窝网络验证公网入口，局域网继续使用原有直连地址；不要通过关闭证书校验来解决。")
                    }
                }
            }
            .navigationTitle("域名直连教程")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text("返回配置")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("dismissRemoteDirectGuide")
            }
            .onChange(of: context) { _ in copied = false }
        }
    }

    private func requirement(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func portRow(_ title: String, external: String, target: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text("对外端口 \(external) → \(target)")
                .font(.subheadline).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var gatewayExample: String {
        let common = """
        client = no
        sslVersionMin = TLSv1.2
        cert = /certs/phone.example.com/fullchain.pem
        key = /certs/phone.example.com/privkey.pem

        [airsim-control]
        accept = 0.0.0.0:443
        connect = 192.168.1.50:7592
        TIMEOUTidle = 120

        [airsim-pcm]
        accept = 0.0.0.0:17593
        connect = 192.168.1.50:7593
        TIMEOUTidle = 120
        """
        guard firstPairing else { return common }
        return common + """


        # Temporary: replace 45945 with the current pairing port.
        # Disable this entry after pairing.
        [airsim-pairing]
        accept = 0.0.0.0:9443
        connect = 192.168.1.50:45945
        TIMEOUTidle = 15
        """
    }
}
