import SwiftUI

/// AirSIM iPhone/iPad 入口：三星 VoWLAN 与独立云端 Relay。
@main
struct AirSIMIPadApp: App {
    @UIApplicationDelegateAdaptor(AirSIMNotificationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.contacts)
                .environmentObject(model.audio)
                .environmentObject(settings)
                .onAppear {
                    WatchCallCoordinator.shared.configure(model: model)
                    WatchCallCoordinator.shared.start()
                    model.start()
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.didBecomeActive()
            case .inactive:
                // 必须在真正进入后台前启动音频会话；等到 .background 才启动时，
                // iOS 可能已经冻结进程，后续来电和短信事件便无法继续等待。
                model.willResignActive()
            case .background:
                model.didEnterBackground()
            default:
                break
            }
        }
    }
}
