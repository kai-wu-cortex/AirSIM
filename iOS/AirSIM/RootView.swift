import SwiftUI
import UIKit
import Intents

enum SystemCommunicationDestination: Equatable {
    case call(String)
    case message(String)
    case liveActivity(AirSIMLiveActivityAction, callID: String)
}

enum SystemCommunicationURL {
    static func destination(for url: URL) -> SystemCommunicationDestination? {
        if let action = AirSIMLiveActivityActionURL.parse(url) {
            return .liveActivity(action.action, callID: action.callID)
        }
        guard let scheme = url.scheme?.lowercased(), ["tel", "im", "sms"].contains(scheme) else {
            return nil
        }
        let prefixLength = scheme.count + 1
        guard url.absoluteString.count > prefixLength else { return nil }
        var target = String(url.absoluteString.dropFirst(prefixLength))
        while target.hasPrefix("//") { target.removeFirst(2) }
        target = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        target = target.removingPercentEncoding ?? target
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = phoneNumber(target) else { return nil }
        return scheme == "tel" ? .call(number) : .message(number)
    }

    static func destination(for intent: INIntent) -> SystemCommunicationDestination? {
        let contacts: [INPerson]?
        let isMessage: Bool
        switch intent {
        case let call as INStartCallIntent:
            contacts = call.contacts
            isMessage = false
        case let call as INStartAudioCallIntent:
            contacts = call.contacts
            isMessage = false
        case let message as INSendMessageIntent:
            contacts = message.recipients
            isMessage = true
        default:
            return nil
        }
        guard let contacts, contacts.count == 1,
              let handle = contacts.first?.personHandle,
              handle.type == .phoneNumber,
              let number = phoneNumber(handle.value) else { return nil }
        return isMessage ? .message(number) : .call(number)
    }

    private static func phoneNumber(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet(charactersIn: "+0123456789*#-(). ")
            .union(.whitespacesAndNewlines)
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let number = String(value.filter { "+0123456789*#".contains($0) })
        guard number.contains(where: { $0.isNumber }) else { return nil }
        return number
    }
}

enum PhoneTab: String, CaseIterable, Identifiable {
    case dial = "拨号"
    case recents = "最近通话"
    case messages = "短信"
    case contacts = "通讯录"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dial: return "circle.grid.3x3"
        case .recents: return "clock"
        case .messages: return "message"
        case .contacts: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }

    var tabTitle: String {
        switch self {
        case .recents: return "最近"
        case .contacts: return "联系人"
        default: return rawValue
        }
    }
}


/// 五个主要目的地使用系统 TabView；iOS 26 原生标签栏负责 Liquid Glass、
/// 长按放大与选中态交互，避免分页手势和自绘按钮争抢横向滑动。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appUpdates: AppUpdateController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appUpdatePresentation: AppUpdatePresentation?
    @AppStorage("airsim.selected-tab") private var selectedTabRawValue = PhoneTab.dial.rawValue
    @State private var callbackSIMRequest: CallbackSIMDialRequest?
    @State private var pendingSMSRecipient: String?
    @State private var messageListState = SMSConversationListState()
    @State private var conversationSender: String?
    @State private var showingConversation = false
    @State private var collapsedCallID: String?
    @AppStorage("airsim.first-connection-complete") private var firstConnectionComplete = false

#if DEBUG && targetEnvironment(simulator)
    @State private var transitionPreviewVisible = false
#endif

    private var presentedCall: CallRecord? {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["AIRSIM_UI_FIXTURE"] == "sms-navigation",
           let preview = SMSNavigationFixture.previewCall {
            if ProcessInfo.processInfo.environment["AIRSIM_UI_CALL_TRANSITION"] == "1" {
                return transitionPreviewVisible ? preview : nil
            }
            return preview
        }
#endif
        return model.inAppPresentedCall
    }

    private var callIsExpanded: Bool {
        guard let call = presentedCall else { return false }
        return collapsedCallID != call.id
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
                TabView(selection: selectedTabBinding) {
                    DialPadView()
                        .tag(PhoneTab.dial)
                        .tabItem { Label(L10n.t(PhoneTab.dial.tabTitle), systemImage: PhoneTab.dial.icon) }

                    RecentsView(onCall: dial, onMessage: composeMessage)
                        .tag(PhoneTab.recents)
                        .tabItem { Label(L10n.t(PhoneTab.recents.tabTitle), systemImage: PhoneTab.recents.icon) }
                        .badge(AirSIMWidgetSnapshot.badgeText(model.unseenMissedCallIDs.count))

                    Group {
                        if #available(iOS 17.0, *) {
                            AdaptiveMessagesView(pendingRecipient: $pendingSMSRecipient,
                                state: $messageListState, sender: $conversationSender,
                                showingConversation: $showingConversation,
                                openConversation: showSMSConversation)
                        } else {
                            NavigationStack {
                                MessagesView(
                                    pendingRecipient: $pendingSMSRecipient,
                                    state: $messageListState,
                                    openConversation: showSMSConversation
                                )
                                .navigationTitle(L10n.t("短信"))
                                .navigationBarTitleDisplayMode(.large)
                                .toolbar { SMSConversationListToolbar(state: $messageListState) }
                                .navigationDestination(isPresented: $showingConversation) {
                                    if let sender = conversationSender {
                                        MessageThreadView(sender: sender)
                                            .id(sender)
                                            .toolbar(.hidden, for: .tabBar)
                                    }
                                }
                            }
                        }
                    }
                        .tag(PhoneTab.messages)
                        .tabItem { Label(L10n.t(PhoneTab.messages.tabTitle), systemImage: PhoneTab.messages.icon) }
                        .badge(AirSIMWidgetSnapshot.badgeText(model.unreadMessageIDs.count))

                    ContactsView(onCall: dial, onMessage: composeMessage)
                        .tag(PhoneTab.contacts)
                        .tabItem { Label(L10n.t(PhoneTab.contacts.tabTitle), systemImage: PhoneTab.contacts.icon) }

                    AirSIMSettingsView()
                        .tag(PhoneTab.settings)
                        .tabItem { Label(L10n.t(PhoneTab.settings.tabTitle), systemImage: PhoneTab.settings.icon) }
                }
                // Keep navigation state, but remove the underlying native tab
                // chrome from rendering, hit testing and VoiceOver during calls.
                // Duo promotes that chrome outside the SwiftUI content stack.
                .opacity(callIsExpanded ? 0 : 1)
                .animation(nil, value: callIsExpanded)
                .allowsHitTesting(!callIsExpanded)
                .accessibilityHidden(callIsExpanded)
                .phoneTabBarMinimizeOnScroll()
                .phoneTabSelectionFeedback(selectedTabRawValue)
                .tint(settings.theme.accent)

            if let call = presentedCall {
                ActiveCallView(call: call, isPresented: callIsExpanded,
                               onMinimize: { collapsedCallID = call.id })
                    .id(call.id)
                    .opacity(callIsExpanded ? 1 : 0)
                    .allowsHitTesting(callIsExpanded)
                    .accessibilityHidden(!callIsExpanded)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(1)
                    // Remove immediately on hangup: fading a departing call over the
                    // restored dial pad leaves translucent numbers and controls.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.16)),
                        removal: .identity
                    ))
            }
        }
        .background(PhoneBackdrop())
        .modifier(CallbackSIMDialChoice(request: $callbackSIMRequest, choose: confirmCallbackSIM))
        .onChange(of: model.callLifecycleSnapshot.state.representsCall) { inCall in
            if inCall { callbackSIMRequest = nil }
        }
        // Only call entry fades. Keep tab chrome and model/audio changes
        // outside the animation transaction; never delay call termination.
        .preferredColorScheme(callIsExpanded ? .dark : settings.appearance.colorScheme)
        .onChange(of: presentedCall?.id) { _ in collapsedCallID = nil }
#if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["AIRSIM_UI_CALL_TRANSITION"] == "1" {
                Button("切换测试通话") { transitionPreviewVisible.toggle() }
                    .accessibilityIdentifier("ui.callTransition")
                    .padding(8).background(.regularMaterial)
            }
        }
#endif
        .safeAreaInset(edge: .top, spacing: 0) {
            if let call = presentedCall, !callIsExpanded {
                Button { collapsedCallID = nil } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "phone.fill")
                        Text(model.contacts.displayName(for: call.number)).lineLimit(1)
                        Spacer(minLength: 8)
                        if ["active", "held"].contains(call.state), let start = model.callConnectedAt {
                            Text(start, style: .timer).monospacedDigit().fixedSize()
                        } else { Text(["active", "held"].contains(call.state) ? "通话中" : "正在连接") }
                        Image(systemName: "chevron.up")
                    }
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 12)
                    .foregroundStyle(.white).background(.green.gradient, in: Capsule())
                }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 6)
                .accessibilityLabel("返回通话")
                .accessibilityIdentifier("call.restore")
            }
            if let reminder = model.otherDeviceCallReminders.first {
                Button {
                    _ = model.openOtherDeviceCallNotification(reminder.userInfo)
                } label: {
                    Label("\(reminder.deviceName) 来电 · 其他设备 \(model.otherDeviceCallReminders.count)", systemImage: "phone.badge.waveform")
                        .font(.subheadline.weight(.semibold)).padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain).padding(.horizontal)
            }
        }
        .sheet(item: $model.focusedOtherDeviceCall, onDismiss: presentAppUpdateIfIdle) { reminder in
            OtherDeviceCallSheet(reminder: reminder).environmentObject(model)
        }
        .fullScreenCover(isPresented: Binding(
            get: { !firstConnectionComplete && !appUpdates.needsNotes && appUpdatePresentation == nil && appUpdateCallIdle },
            // Completion is written only by explicit actions in the onboarding view.
            // A call can temporarily dismiss this cover without completing pairing.
            set: { _ in }
        )) {
            AirSIMFirstConnectionView()
                .environmentObject(model)
        }
        .onOpenURL(perform: handleSystemCommunicationURL)
        .onContinueUserActivity("INStartCallIntent", perform: handleSystemCommunicationActivity)
        .onContinueUserActivity("INStartAudioCallIntent", perform: handleSystemCommunicationActivity)
        .onContinueUserActivity("INSendMessageIntent", perform: handleSystemCommunicationActivity)
        .fullScreenCover(item: $appUpdatePresentation, onDismiss: presentAppUpdateIfIdle) { presentation in
            AppUpdateSheet(presentation: presentation, updates: appUpdates)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            presentAppUpdateIfIdle()
            if firstConnectionComplete && appUpdateCallIdle {
                _ = await appUpdates.check(manual: false)
                presentAppUpdateIfIdle()
            }
        }
        .onChange(of: appUpdates.needsNotes) { _ in presentAppUpdateIfIdle() }
        .onChange(of: appUpdates.pendingUpdate) { _ in presentAppUpdateIfIdle() }
        .onChange(of: selectedTabRawValue) { _ in presentAppUpdateIfIdle() }
        .onChange(of: firstConnectionComplete) { complete in
            if complete && scenePhase == .active && appUpdateCallIdle {
                Task { _ = await appUpdates.check(manual: false); presentAppUpdateIfIdle() }
            }
        }
        .onChange(of: model.inAppPresentedCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.activeCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.remoteCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.pendingOutgoingCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.errorMessage) { _ in presentAppUpdateIfIdle() }
        .onAppear {
            if let info = OtherAndroidCallPresentationRequest.consume() { _ = model.openOtherDeviceCallNotification(info) }
            if let sender = IncomingSMSPresentationRequest.consume() {
                openSMSConversation(sender)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimRemoteSMSReceived)) { _ in
            model.reloadMessagesFromLocalStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenSMSConversation)) { notification in
            let sender = IncomingSMSPresentationRequest.consume()
                ?? notification.userInfo?["sender"] as? String
            guard let sender else {
                selectedTab = .messages
                return
            }
            openSMSConversation(sender)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenIncomingCall)) { _ in
            model.presentCurrentCallInApp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenOtherAndroidCall)) { notification in
            let info = OtherAndroidCallPresentationRequest.consume() ?? notification.userInfo ?? [:]
            _ = model.openOtherDeviceCallNotification(info)
        }
        .alert(L10n.t("错误"), isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage?.isEmpty == false },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func presentAppUpdateIfIdle() {
        guard scenePhase == .active, appUpdatePresentation == nil,
              appUpdateCallIdle, model.focusedOtherDeviceCall == nil,
              model.errorMessage == nil else { return }
        if appUpdates.needsNotes {
            appUpdatePresentation = .notes
        } else if firstConnectionComplete && selectedTabRawValue == PhoneTab.dial.rawValue,
                  let candidate = appUpdates.pendingUpdate {
            appUpdatePresentation = .result(.init(message: "发现应用新版本", candidate: candidate))
        }
    }

    private var appUpdateCallIdle: Bool {
        model.inAppPresentedCall == nil && model.activeCall == nil
            && model.remoteCall == nil && model.pendingOutgoingCall == nil
    }

    private func handleAppUpdateCallChange() {
        if !appUpdateCallIdle { appUpdatePresentation = nil }
        else { presentAppUpdateIfIdle() }
    }

    private var selectedTabBinding: Binding<PhoneTab> {
        Binding(
            get: { PhoneTab(rawValue: selectedTabRawValue) ?? .dial },
            set: { newTab in
                guard newTab.rawValue != selectedTabRawValue else { return }
                selectedTabRawValue = newTab.rawValue
            }
        )
    }

    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: selectedTabRawValue) ?? .dial }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }

    private func dial(_ number: String) {
        let agentID = AndroidAgentBindingPreference.selected() ?? model.currentAndroidAgent?.id
        if let agentID {
            let slots = model.simSlots(for: agentID)
            if slots.count > 1 {
                callbackSIMRequest = .init(agentID: agentID, number: number, slots: slots)
                return
            }
        }
        dialUsingCurrentSIM(number)
    }

    private func confirmCallbackSIM(_ request: CallbackSIMDialRequest, _ slot: AndroidSIMSlot) {
        let agentID = AndroidAgentBindingPreference.selected() ?? model.currentAndroidAgent?.id
        guard request.permits(agentID: agentID, liveSlots: agentID.map { model.simSlots(for: $0) } ?? [],
                              slotID: slot.id, callInProgress: model.callLifecycleSnapshot.state.representsCall || model.pendingOutgoingCall != nil) else {
            callbackSIMRequest = nil
            model.errorMessage = "设备或 SIM 卡已变化，请重新选择后拨号"
            return
        }
        model.selectSIMSlot(slot.id, for: request.agentID)
        callbackSIMRequest = nil
        dialUsingCurrentSIM(request.number)
    }

    private func dialUsingCurrentSIM(_ number: String) {
        showingConversation = false
        model.numberInput = number
        selectedTab = .dial
        Task { await model.dial() }
    }

    private func composeMessage(_ number: String) {
        showingConversation = false
        pendingSMSRecipient = number
        messageListState.showingComposer = true
        selectedTab = .messages
    }

    private func openSMSConversation(_ sender: String) {
        model.reloadMessagesFromLocalStore()
        showSMSConversation(sender)
    }

    private func showSMSConversation(_ sender: String) {
        selectedTab = .messages
        conversationSender = sender
        showingConversation = true
    }

    private func handleSystemCommunicationURL(_ url: URL) {
        if let target = AirSIMWidgetDestination.parse(url) {
            // Widget links only navigate. Never treat a widget tap as a dial or
            // SMS-send command, and never retarget an established call.
            if let id = target.agentID,
               !model.callLifecycleSnapshot.state.representsCall,
               !IPhoneCloudCallSession.shared.hasActiveCall,
               model.pairedAndroidAgents.contains(where: { $0.id == id }) {
                model.bindAndroidAgent(id)
            }
            switch target.destination {
            case .status: selectedTab = .settings
            case .dial: selectedTab = .dial
            case .messages: selectedTab = .messages
            case .contacts: selectedTab = .contacts
            case .recents: selectedTab = .recents
            }
            return
        }
        presentSystemCommunication(SystemCommunicationURL.destination(for: url))
    }

    private func handleSystemCommunicationActivity(_ activity: NSUserActivity) {
        guard let intent = activity.interaction?.intent else { return }
        presentSystemCommunication(SystemCommunicationURL.destination(for: intent))
    }

    private func presentSystemCommunication(_ destination: SystemCommunicationDestination?) {
        switch destination {
        case let .call(number):
            callbackSIMRequest = nil
            messageListState.showingComposer = false
            showingConversation = false
            model.numberInput = number
            selectedTab = .dial
        case let .message(recipient):
            composeMessage(recipient)
        case let .liveActivity(action, callID):
            // Legacy links still open the app; use the same unified path as intents
            // so a stale island is dismissed instead of showing a Bluetooth-call error.
            Task { _ = await model.performLiveActivityAction(action, callID: callID) }
        case nil:
            break
        }
    }
}

/// 浅色模式使用系统电话式纯白底；深色模式才绘制深蓝黑底部环境光。
struct PhoneBackdrop: View {
    var grouped = true

    var body: some View {
        Color(uiColor: grouped ? .systemGroupedBackground : .systemBackground)
            .ignoresSafeArea()
    }
}

/// 关键内容表面使用系统原生 Liquid Glass，旧系统回退为系统材质。
struct PhoneCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct PhoneGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = interactive
                ? Glass.regular.tint(tint).interactive()
                : Glass.regular.tint(tint)
            content.glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
    }
}

/// 自定义工具栏材质仅用于隐藏了系统共享背景的 ToolbarItem，确保始终只有一层玻璃。
private struct PhoneToolbarGlassMorph: ViewModifier {
    let id: String
    @Namespace private var glassNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                content
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID(id, in: glassNamespace)
                    .glassEffectTransition(.materialize)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.82)))
        } else {
            content
        }
    }
}

/// iOS 26 隐藏导航栏自动生成的共享按钮背景，再使用上面的单层可变形玻璃；
/// 旧系统继续交给 ToolbarItem 使用平台默认样式。
@ToolbarContentBuilder
func phoneMorphingToolbarItem<Content: View>(
    placement: ToolbarItemPlacement,
    id: String,
    @ViewBuilder content: () -> Content
) -> some ToolbarContent {
    if #available(iOS 26.0, *) {
        ToolbarItem(placement: placement) {
            content().phoneToolbarGlassMorph(id: id)
        }
        .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

extension View {
    func phoneCard() -> some View { modifier(PhoneCard()) }

    func phoneGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(PhoneGlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            interactive: interactive
        ))
    }

    @ViewBuilder
    func phoneTabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    func phoneToolbarGlassMorph(id: String) -> some View {
        modifier(PhoneToolbarGlassMorph(id: id))
    }

    @ViewBuilder
    func phoneTabSelectionFeedback(_ trigger: String) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }
}

private struct PhoneTabBarCompactStateActionKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    fileprivate var phoneTabBarCompactStateAction: (Bool) -> Void {
        get { self[PhoneTabBarCompactStateActionKey.self] }
        set { self[PhoneTabBarCompactStateActionKey.self] = newValue }
    }
}

private struct PhoneTabBarCompactScrollReporter: ViewModifier {
    @Environment(\.phoneTabBarCompactStateAction) private var reportCompactState

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { oldOffset, newOffset in
                let delta = newOffset - oldOffset
                if newOffset < 2 {
                    reportCompactState(false)
                } else if delta > 2 {
                    reportCompactState(true)
                } else if delta < -2 {
                    reportCompactState(false)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func phoneReportsTabBarCompactState() -> some View {
        modifier(PhoneTabBarCompactScrollReporter())
    }
}

/// The entire TabView is the root of the outer navigation stack. Its native
/// bar fades with that root, below the opaque conversation being pushed/popped.
private struct PhoneTabBarNavigationFade: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var nativeTabBar: UITabBar?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            transitionTabBar(visible: true, animated: animated)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            transitionTabBar(visible: false, animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let bar = findTabBar() { Self.settle(bar, visible: true) }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if let bar = nativeTabBar { Self.settle(bar, visible: false) }
        }


        private func findTabBar() -> UITabBar? {
            if let nativeTabBar { return nativeTabBar }
            func find(in controller: UIViewController) -> UITabBar? {
                if let tabs = controller as? UITabBarController { return tabs.tabBar }
                for child in controller.children {
                    if let bar = find(in: child) { return bar }
                }
                return nil
            }
            var ancestor = parent
            while let controller = ancestor {
                if let bar = find(in: controller) {
                    nativeTabBar = bar
                    return bar
                }
                ancestor = controller.parent
            }
            return nil
        }

        private func transitionTabBar(visible: Bool, animated: Bool) {
            guard let bar = findTabBar() else { return }
            bar.isUserInteractionEnabled = false
            bar.accessibilityElementsHidden = true
            guard animated, !UIAccessibility.isReduceMotionEnabled,
                  let coordinator = transitionCoordinator else {
                Self.settle(bar, visible: visible)
                return
            }
            let queued = coordinator.animateAlongsideTransition(in: bar, animation: { _ in
                bar.alpha = visible ? 1 : 0
            }, completion: { context in
                let finalVisible = context.isCancelled ? !visible : visible
                Self.settle(bar, visible: finalVisible)
            })
            if !queued { Self.settle(bar, visible: visible) }
        }

        private static func settle(_ bar: UITabBar, visible: Bool) {
            bar.alpha = visible ? 1 : 0
            bar.isUserInteractionEnabled = visible
            bar.accessibilityElementsHidden = !visible
        }
    }
}

/// One split-view hierarchy survives folding/resizing without recreating the
/// thread composer. Compact columns are managed by the system's back gesture.
@available(iOS 17.0, *)
private struct AdaptiveMessagesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var pendingRecipient: String?
    @Binding var state: SMSConversationListState
    @Binding var sender: String?
    @Binding var showingConversation: Bool
    let openConversation: (String) -> Void
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            MessagesView(pendingRecipient: $pendingRecipient, state: $state,
                         openConversation: openConversation)
                .navigationTitle(L10n.t("短信"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar { SMSConversationListToolbar(state: $state) }
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            if let sender, showingConversation {
                MessageThreadView(sender: sender)
                    .id(sender)
            } else {
                ContentUnavailableView("选择一段对话", systemImage: "message",
                    description: Text("从左侧选择短信，或新建一条短信。"))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(horizontalSizeClass == .compact && showingConversation ? .hidden : .automatic, for: .tabBar)
        .onChange(of: showingConversation) { _, showing in
            compactColumn = showing ? .detail : .sidebar
        }
        .onChange(of: compactColumn) { _, column in
            if horizontalSizeClass == .compact && column == .sidebar {
                showingConversation = false
            }
        }
        .onAppear { compactColumn = showingConversation ? .detail : .sidebar }
    }
}


/// UI-only callback intent. The existing model/router remains the dial owner.
struct CallbackSIMDialRequest: Identifiable {
    let id = UUID()
    let agentID: String
    let number: String
    let slots: [AndroidSIMSlot]
    func permits(agentID current: String?, liveSlots: [AndroidSIMSlot], slotID: String, callInProgress: Bool) -> Bool {
        !callInProgress && current == agentID && slots.contains { $0.id == slotID }
            && liveSlots.contains { $0.id == slotID }
    }
}

private struct CallbackSIMDialChoice: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var request: CallbackSIMDialRequest?
    let choose: (CallbackSIMDialRequest, AndroidSIMSlot) -> Void
    func body(content: Content) -> some View {
        content.overlay {
            Color.clear.frame(width: 1, height: 1)
                .popover(item: $request) { captured in
                    CompactSIMSelectionPanel(slots: captured.slots,
                        selectedID: model.selectedSIMSlotID(for: captured.agentID), title: "拨号用卡") { slot in
                        choose(captured, slot)
                    }.compactSIMPopoverPresentation()
                }
        }
    }
}
