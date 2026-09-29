import SwiftUI

@main
struct AirSIMWatchApp: App {
    @StateObject private var callSession = WatchCallSession()

    var body: some Scene {
        WindowGroup {
            WatchCallView()
                .environmentObject(callSession)
        }
    }
}
