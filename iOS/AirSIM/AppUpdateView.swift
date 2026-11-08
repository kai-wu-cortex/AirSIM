import SwiftUI
import WebKit

enum AppUpdatePresentation: Identifiable {
    case notes
    case result(AppUpdateResult)
    var id: String {
        switch self { case .notes: return "notes"; case .result: return "result" }
    }
}

enum AppReleaseNotes {
    // Bundled: showing installed-version notes never needs GitHub, Relay or pairing.
    // Keep this summary in sync with the candidate's source and docs when publishing.
    static let items = [
        "云端音频缓冲新增自动、稳定优先与手动模式，支持 720 ms 弱网测试；从下一通电话生效，更大缓冲也会增加对话延迟。",
        "运营商接通前语音可在设置中开关；兼容端支持云端短信端到端加密，通知显示对应 SIM，并改进未接提醒去重。",
        "VoWLAN、蓝牙与云端支持兼容设备的运营商早期媒体；接通前只接收语音，不提前计时或开启麦克风。",
        "修复 U30Air 云端旧协议的公告播放，以及听筒和扬声器切换后的声音中断。",
        "灵动岛用 Wi-Fi、蓝牙、双通道组合和云朵区分连接状态；活动过期不会直接标记设备离线。",
        "设置按连接、来电短信、灵动岛小组件等分类，减少重复入口；底部标签保持展开。",
        "短信支持搜索联系人、号码和消息内容；大尺寸小组件最多展示 5 条最近通话和短信。",
        "支持连接运行兼容 AirSIM 设备端的 U30Air，在 iPhone 上使用通话与短信功能。",
        "桌面与锁屏小组件展示设备状态；支持的桌面尺寸提供设备与连接模式切换、最近通话和短信内容摘要。",
        "小组件支持后台切换，显示设备上报的电量；刷新由系统调度，无有效采样时显示未知。",
        "试验性 TLS 公网域名配对与直连：通过自建 HTTPS／TLS 入口完成首次配对，或为已配对设备添加公网入口。",
        "最近通话与短信的底部标签、小组件标题显示未接／未读数量，对应记录也有醒目标记。",
        "呼出结束时按通话身份停止等待音与计时；网络波动不会自动重复拨号。"
    ]
    static let limitations = "云端缓冲只调整接收播放，旧 Agent 仅 iPhone 侧生效；U30Air 缓冲适配不包含在本次 App 更新中。短信加密需兼容两端与 Relay 协商，已有配对请检查加密状态。U30Air 需运行兼容设备端。运营商早期媒体依赖兼容 Agent、手机音频能力和运营商实际下行，不保证每次拒接或挂断都有公告。TLS 公网功能为试验性，需要可入站的自建网关、有效证书及独立音频转发；不自动穿透 NAT，也不新增后台推送。小组件刷新由系统调度，模式切换不代表已连接。GitHub 发布不代表 TestFlight 已可更新。"
}

enum AppUpdateChannel {
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            && Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") == nil
    }
    static var title: String { isTestFlight ? "TestFlight" : "自签／侧载或其他安装渠道" }
}

struct AppUpdateSheet: View {
    let presentation: AppUpdatePresentation
    @ObservedObject var updates: AppUpdateController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch presentation {
        case .notes:
            NewFeatureOnboardingView(
                version: AppInformation.version,
                onConfirm: {
                    updates.acknowledgeNotes()
                    dismiss()
                }
            )
        case .result(let result):
            NavigationStack {
                List {
                    Section { Text(result.message) }
                    if let candidate = result.candidate {
                        Section("公开版本 \(candidate.version)（\(candidate.build)）") {
                            Text(candidate.notes.isEmpty ? "请查看发布页中的更新说明。" : candidate.notes)
                                .textSelection(.enabled)
                            Link("查看 GitHub 发布说明", destination: candidate.page)
                        }
                        Section("如何更新") {
                            Text(AppUpdateChannel.isTestFlight
                                ? "请打开 TestFlight 查看此 App 是否已有可用构建。GitHub 发布不代表 Apple 已处理完成或测试者可更新。"
                                : "GitHub IPA 需要侧载工具重新签名后安装，不能直接安装。使用 TestFlight 的用户请在 TestFlight 中检查。")
                            Text("不会自动下载安装，也不会更改配对、通话或 AVF Agent。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("应用更新")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("知道了") {
                            if let candidate = result.candidate { updates.acknowledgeUpdate(candidate) }
                            dismiss()
                        }
                    }
                }
            }
        }
        }
        .interactiveDismissDisabled()
    }
}

private struct NewFeaturePage: Identifiable {
    let id: Int
    let kicker: String
    let title: String
    let body: String
    let symbol: String
    let accent: Color
    let demo: NewFeatureDemo
}

private enum NewFeatureCatalog {
    static let pages: [NewFeaturePage] = [
        NewFeaturePage(
            id: 6,
            kicker: "云端音频缓冲",
            title: "网络有起伏，\n声音多一份余量",
            body: "自动保持原有策略；稳定优先增加缓冲，手动可选 720 ms。更大缓冲可缓解短暂卡顿，也会增加对话延迟。从下一通云端电话生效。",
            symbol: "waveform",
            accent: .cyan,
            demo: .audioBuffer
        ),
        NewFeaturePage(
            id: 7,
            kicker: "运营商接通前语音",
            title: "先听到真实提示，\n接通后再计时",
            body: "在设置中选择是否接收运营商彩铃与提示。兼容的 VoWLAN、蓝牙和云端链路均可使用；接通前只接收下行，不开启麦克风。不保证每次都有公告。",
            symbol: "phone.waveform",
            accent: .green,
            demo: .carrierAudio
        ),
        NewFeaturePage(
            id: 0,
            kicker: "U30Air 支持",
            title: "连接 U30Air，\n电话短信随身用",
            body: "连接运行兼容 AirSIM 设备端的 U30Air，在 iPhone 上拨打、接听电话和收发短信。请先更新设备端并完成配对。",
            symbol: "phone.connection.fill",
            accent: .cyan,
            demo: .u30Air
        ),
        NewFeaturePage(
            id: 1,
            kicker: "桌面与锁屏小组件",
            title: "不用打开 App，\n常用信息一眼可见",
            body: "查看设备状态和电量，大尺寸最多展示 5 条最近通话与短信内容；支持的桌面尺寸可切换设备和连接模式。刷新由系统调度。",
            symbol: "rectangle.grid.2x2.fill",
            accent: .green,
            demo: .widgetSummary
        ),
        NewFeaturePage(
            id: 2,
            kicker: "TLS 公网 · 试验性",
            title: "用自己的域名，\n在外也能配对直连",
            body: "通过自建 HTTPS／TLS 网关完成首次配对，或为已有设备添加公网入口。需可入站网络、有效证书和独立音频转发；配置页内附使用教程。",
            symbol: "lock.shield.fill",
            accent: .blue,
            demo: .publicTLS
        ),
        NewFeaturePage(
            id: 3,
            kicker: "短信加密 · SIM 与未接提醒",
            title: "消息更安心，\n来电更清楚",
            body: "兼容两端协商后，云端短信支持端到端加密。来电与短信显示对应 SIM；改进未接通知与过期提醒清理，保留未读、未接数字标记。",
            symbol: "app.badge.fill",
            accent: .orange,
            demo: .secureNotifications
        ),
    ]
}

struct NewFeatureOnboardingView: View {
    let version: String
    let onConfirm: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: NewFeaturePage { NewFeatureCatalog.pages[page] }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    selected.accent.opacity(0.34),
                    Color.black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: page)

            TabView(selection: $page) {
                ForEach(Array(NewFeatureCatalog.pages.enumerated()), id: \.element.id) { index, item in
                    NewFeaturePageView(item: item, isActive: page == index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: page)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirSIM")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("版本 \(version)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button("确定") { onConfirm() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(.white, in: Capsule())
                    .accessibilityLabel("确定并关闭新功能介绍")
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    ForEach(NewFeatureCatalog.pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? .white : .white.opacity(0.25))
                            .frame(width: index == page ? 22 : 7, height: 7)
                            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: page)
                    }
                }
                Text("左右滑动 · 查看全部新功能")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 6)
            }
            .padding(.top, 4)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}

private struct NewFeaturePageView: View {
    let item: NewFeaturePage
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            FeatureDemoView(demo: item.demo, isActive: isActive)
                .accessibilityHidden(true)
                .frame(height: 220)
                .padding(.horizontal, 4)
                .opacity(isActive ? 1 : 0.55)
                .scaleEffect(isActive ? 1 : 0.94)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isActive)
                .padding(.bottom, 22)

            Text(item.kicker.uppercased())
                .font(.caption.weight(.bold))
                .tracking(2.2)
                .foregroundStyle(item.accent)

            Text(item.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)

            Text(item.body)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.68))
                .lineSpacing(4)
                .padding(.top, 14)
                .padding(.horizontal, 8)

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 28)
        .opacity(isActive ? 1 : 0.55)
        .scaleEffect(isActive ? 1 : 0.94)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isActive)
        .accessibilityElement(children: .combine)
    }
}


private enum NewFeatureDemo: String {
    case u30Air, widgetSummary, publicTLS, unreadBadges, connectionModes, settingsOverview, audioBuffer, carrierAudio, secureNotifications
}

private struct FeatureDemoView: View {
    let demo: NewFeatureDemo
    let isActive: Bool

    var body: some View {
        switch demo {
        case .connectionModes:
            VStack(spacing: 24) {
                HStack(spacing: 22) {
                    ForEach([LiveActivityConnectionMark.vowlan, .bluetooth, .dualLocal, .cloud], id: \.self) { mark in
                        VStack(spacing: 12) {
                            LiveActivityConnectionIcon(mark: mark, size: 25)
                            Text(mark == .dualLocal ? "双通道" : mark.title)
                                .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .padding(24).background(.black, in: Capsule())
                Text("连接状态示意").font(.caption).foregroundStyle(.secondary)
            }
        case .settingsOverview:
            VStack(alignment: .leading, spacing: 16) {
                Label("搜索联系人、号码或短信内容", systemImage: "magnifyingglass")
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider().overlay(.white.opacity(0.15))
                Label("连接与设备", systemImage: "antenna.radiowaves.left.and.right")
                Label("来电与短信", systemImage: "phone")
                Label("灵动岛与小组件", systemImage: "rectangle.on.rectangle")
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.white)
            .padding(24).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
        default:
            WebFeatureDemoView(demo: demo, isActive: isActive)
        }
    }
}

private struct WebFeatureDemoView: UIViewRepresentable {
    let demo: NewFeatureDemo
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var animationEnabled: Bool { isActive && !reduceMotion && scenePhase == .active }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        load(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        load(view, coordinator: context.coordinator)
    }

    private func load(_ view: WKWebView, coordinator: Coordinator) {
        let key = "\(demo.rawValue)-\(animationEnabled)"
        guard coordinator.key != key else { return }
        coordinator.key = key
        view.loadHTMLString(FeatureDemoHTML.html(for: demo, animated: animationEnabled), baseURL: nil)
    }

    final class Coordinator { var key: String? }
}

private enum FeatureDemoHTML {
    // Bundled, decorative illustrations. Never fetch resources or use real device data.
    static func html(for demo: NewFeatureDemo, animated: Bool) -> String {
        let illustration: String
        switch demo {
        case .audioBuffer: illustration = audioBuffer
        case .carrierAudio: illustration = carrierAudio
        case .secureNotifications: illustration = secureNotifications
        case .u30Air: illustration = u30Air
        case .widgetSummary: illustration = widgetSummary
        case .publicTLS: illustration = publicTLS
        case .unreadBadges: illustration = unreadBadges
        case .connectionModes, .settingsOverview: illustration = "" // Rendered natively above.
        }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden}
        svg{display:block;width:100%;height:100%}
        text{font-family:-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif}
        .buffer-fill{transform-origin:42px 0;animation:buffer-fill 4s ease-in-out infinite}
        @keyframes buffer-fill{0%,100%{transform:scaleX(.3)}45%,75%{transform:scaleX(1)}}
        .route{stroke-dasharray:6 7;animation:flow 2s linear infinite}
        .pulse{transform-box:fill-box;transform-origin:center;animation:pulse 3s ease-in-out infinite}
        .reveal{animation:reveal 4s ease-in-out infinite}
        .delayed{animation-delay:.5s}
        .mode-a{animation:mode-a 6s ease-in-out infinite}
        .mode-b{opacity:0;animation:mode-b 6s ease-in-out infinite}
        @keyframes flow{to{stroke-dashoffset:-26}}
        @keyframes pulse{0%,70%,100%{transform:scale(1)}82%{transform:scale(1.12)}90%{transform:scale(1)}}
        @keyframes reveal{0%,100%{opacity:.5}25%,80%{opacity:1}}
        @keyframes mode-a{0%,40%,100%{opacity:1}50%,90%{opacity:0}}
        @keyframes mode-b{0%,40%,100%{opacity:0}50%,90%{opacity:1}}
        body.still *{animation:none!important}
        @media(prefers-reduced-motion:reduce){*{animation:none!important}}
        </style></head><body class="\(animated ? "animated" : "still")">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 220" aria-hidden="true">
        \(illustration)
        </svg></body></html>
        """
    }

    private static let audioBuffer = """
    <rect x="18" y="20" width="324" height="180" rx="26" fill="#142535" stroke="#345970"/>
    <text x="40" y="52" fill="#A9D8EB" font-size="13">云端接收 · 缓冲示意</text>
    <path class="route" d="M40 80l12-12 12 24 12-24 12 24 12-12h220" fill="none" stroke="#59D8F3" stroke-width="3"/>
    <rect x="40" y="101" width="280" height="28" rx="9" fill="#243F51"/>
    <rect class="buffer-fill" x="42" y="103" width="276" height="24" rx="7" fill="#40BDE0"/>
    <text x="180" y="121" text-anchor="middle" fill="#061F2C" font-size="13" font-weight="700">720 ms</text>
    <text x="40" y="158" fill="white" font-size="14">自动</text>
    <text x="126" y="158" fill="white" font-size="14">稳定优先</text>
    <rect x="236" y="140" width="84" height="28" rx="14" fill="#1A687E"/>
    <text x="278" y="159" text-anchor="middle" fill="white" font-size="14">手动</text>
    <text x="180" y="186" text-anchor="middle" fill="#A9BFCF" font-size="11">更大缓冲，也带来更多等待</text>
    """

    private static let carrierAudio = """
    <rect x="32" y="18" width="296" height="184" rx="26" fill="#152D29" stroke="#386A57"/>
    <text x="56" y="51" fill="#A4DDC1" font-size="13">运营商接通前语音</text>
    <rect x="257" y="32" width="48" height="25" rx="13" fill="#32C975"/>
    <circle cx="292" cy="44.5" r="10" fill="white"/>
    <path class="route" d="M59 99h23l8-19 12 37 12-54 12 70 12-43 12 20 10-11h137" fill="none" stroke="#63E6A5" stroke-width="4" stroke-linejoin="round"/>
    <text class="reveal" x="180" y="159" text-anchor="middle" fill="white" font-size="19" font-weight="600">正在呼叫 · 尚未接通</text>
    <text x="180" y="183" text-anchor="middle" fill="#A4DDC1" font-size="12">只接收语音 · 麦克风未开启</text>
    """

    private static let secureNotifications = """
    <rect x="24" y="20" width="312" height="83" rx="22" fill="#182D42" stroke="#385876"/>
    <path d="M49 57v-9a9 9 0 0 1 18 0v9m-22 0h26v23H45z" fill="none" stroke="#6ECBF7" stroke-width="3" stroke-linejoin="round"/>
    <text x="89" y="52" fill="#6ECBF7" font-size="13">短信 · SIM 2</text>
    <text x="89" y="78" fill="white" font-size="16">已协商端到端加密</text>
    <rect x="24" y="118" width="312" height="83" rx="22" fill="#32291E" stroke="#725339"/>
    <circle class="pulse" cx="58" cy="159" r="17" fill="#EF685B"/>
    <text x="58" y="165" text-anchor="middle" fill="white" font-size="18" font-weight="700">1</text>
    <text x="89" y="150" fill="#FFBD78" font-size="13">未接来电 · SIM 1</text>
    <text x="89" y="177" fill="white" font-size="16">号码与来源，一目了然</text>
    """

    private static let u30Air = """
    <rect x="20" y="51" width="104" height="122" rx="25" fill="#172A3B" stroke="#42738C"/>
    <rect x="45" y="69" width="54" height="9" rx="4" fill="#304D63"/>
    <circle class="pulse" cx="72" cy="109" r="8" fill="#55DBF6"/>
    <text x="72" y="149" text-anchor="middle" fill="white" font-size="16" font-weight="700">U30Air</text>
    <path class="route" d="M132 109H224" stroke="#55DBF6" stroke-width="2"/>
    <rect x="151" y="91" width="54" height="35" rx="17" fill="#13394A"/>
    <path d="M170 108l6 6 12-13" fill="none" stroke="#55DBF6" stroke-width="3" stroke-linecap="round"/>
    <rect x="233" y="20" width="107" height="177" rx="23" fill="#182233" stroke="#54677C"/>
    <rect x="269" y="31" width="35" height="7" rx="4" fill="#526178"/>
    <text x="286" y="66" text-anchor="middle" fill="white" font-size="16" font-weight="700">AirSIM</text>
    <g class="reveal"><rect x="247" y="83" width="79" height="37" rx="12" fill="#164458"/>
    <text x="286" y="107" text-anchor="middle" fill="#69DFF5" font-size="14">通话</text></g>
    <g class="reveal delayed"><rect x="247" y="129" width="79" height="37" rx="12" fill="#233D57"/>
    <text x="286" y="153" text-anchor="middle" fill="#A9D3FF" font-size="14">短信</text></g>
    <text x="125" y="211" text-anchor="middle" fill="#B5C5D8" font-size="11">连接示意 · 需兼容设备端</text>
    """

    private static let widgetSummary = """
    <rect x="14" y="18" width="332" height="182" rx="28" fill="#F4F8FC"/>
    <rect x="32" y="35" width="42" height="42" rx="13" fill="#DCEEFF"/>
    <path d="M43 46q-4 12 17 22l6-7-8-5-4 4-6-7 3-4z" fill="#008BEE"/>
    <text x="85" y="53" fill="#152238" font-size="17" font-weight="700">Galaxy</text>
    <circle cx="89" cy="69" r="3" fill="#279D56"/>
    <text x="99" y="73" fill="#5B697B" font-size="11">最近在线</text>
    <rect x="272" y="43" width="23" height="12" rx="3" fill="#2AC466"/>
    <rect x="296" y="47" width="2" height="4" rx="1" fill="#2AC466"/>
    <text x="270" y="73" fill="#152238" font-size="12">82%</text>
    <path d="M33 91H327" stroke="#D8E1EA"/>
    <text x="33" y="112" fill="#64748B" font-size="10">设备</text>
    <text x="33" y="132" fill="#0064CC" font-size="14" font-weight="600">Galaxy ↻</text>
    <text x="195" y="112" fill="#64748B" font-size="10">连接模式</text>
    <text class="mode-a" x="195" y="132" fill="#0064CC" font-size="14" font-weight="600">VoWLAN ↻</text>
    <text class="mode-b" x="195" y="132" fill="#0064CC" font-size="14" font-weight="600">自动 ↻</text>
    <text x="33" y="158" fill="#152238" font-size="11" font-weight="600">最近通话</text>
    <text x="33" y="180" fill="#64748B" font-size="11">138 •••• 6028</text>
    <text x="195" y="158" fill="#152238" font-size="11" font-weight="600">最近短信</text>
    <text x="195" y="180" fill="#64748B" font-size="11">我已经到家了。</text>
    <text x="180" y="216" text-anchor="middle" fill="#B5C5D8" font-size="10">示意数据 · 刷新由系统调度</text>
    """

    private static let publicTLS = """
    <rect x="26" y="18" width="308" height="44" rx="15" fill="#193453" stroke="#4278AA"/>
    <path d="M45 37v-5a5 5 0 0 1 10 0v5M43 37h14v12H43z" fill="none" stroke="#74BDFF" stroke-width="2"/>
    <text x="69" y="45" fill="#D8EBFF" font-size="15">https://phone.example.com</text>
    <rect x="18" y="101" width="78" height="58" rx="16" fill="#182A40" stroke="#42627F"/>
    <text x="57" y="135" text-anchor="middle" fill="white" font-size="15">iPhone</text>
    <path class="route" d="M101 130H134M226 130H259" stroke="#64B6FF" stroke-width="2"/>
    <rect x="139" y="91" width="82" height="78" rx="18" fill="#163D66" stroke="#4D9FE8"/>
    <text x="180" y="123" text-anchor="middle" fill="#A6D7FF" font-size="15" font-weight="700">TLS</text>
    <text x="180" y="146" text-anchor="middle" fill="#D8EBFF" font-size="12">自建网关</text>
    <rect x="264" y="101" width="78" height="58" rx="16" fill="#182A40" stroke="#42627F"/>
    <text x="303" y="135" text-anchor="middle" fill="white" font-size="15">安卓</text>
    <text x="180" y="191" text-anchor="middle" fill="#9DCFFF" font-size="12">首次配对 · 控制 · 音频</text>
    <text x="180" y="214" text-anchor="middle" fill="#B5C5D8" font-size="10">试验性 · 需自行部署可入站网关</text>
    """

    private static let unreadBadges = """
    <rect x="18" y="16" width="324" height="184" rx="25" fill="#182233" stroke="#3B485D"/>
    <rect x="33" y="33" width="294" height="52" rx="13" fill="#243148"/>
    <circle class="pulse" cx="47" cy="59" r="4" fill="#FF625A"/>
    <text x="61" y="54" fill="white" font-size="14" font-weight="600">未接来电</text>
    <text x="61" y="74" fill="#B8C6DA" font-size="11">138 •••• 6028</text>
    <rect x="33" y="94" width="294" height="52" rx="13" fill="#243148"/>
    <circle class="pulse delayed" cx="47" cy="120" r="4" fill="#FF625A"/>
    <text x="61" y="115" fill="white" font-size="14" font-weight="600">未读短信</text>
    <text x="61" y="135" fill="#B8C6DA" font-size="11">我已经到家了。</text>
    <text x="98" y="182" text-anchor="middle" fill="#A5CFFF" font-size="14">最近</text>
    <g class="pulse"><rect x="115" y="159" width="20" height="20" rx="10" fill="#FF453A"/>
    <text x="125" y="173" text-anchor="middle" fill="white" font-size="12" font-weight="700">2</text></g>
    <text x="244" y="182" text-anchor="middle" fill="#A5CFFF" font-size="14">短信</text>
    <g class="pulse delayed"><rect x="261" y="159" width="20" height="20" rx="10" fill="#FF453A"/>
    <text x="271" y="173" text-anchor="middle" fill="white" font-size="12" font-weight="700">3</text></g>
    <text x="180" y="216" text-anchor="middle" fill="#B5C5D8" font-size="10">示意数据 · 数字角标与记录标记</text>
    """
}
