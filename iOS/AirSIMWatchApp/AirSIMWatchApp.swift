import SwiftUI
import WatchKit

@main
struct AirSIMWatchApp: App {
    @WKApplicationDelegateAdaptor(AirSIMWatchDelegate.self) private var appDelegate
    @StateObject private var callSession = WatchCallSession.shared

    var body: some Scene {
        WindowGroup {
            WatchCallView()
                .environmentObject(callSession)
        }
    }
}

/// Push-only launches must install the registry without waiting for a scene/view.
@MainActor
final class AirSIMWatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        _ = WatchCallSession.shared
    }
}
