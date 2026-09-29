import SwiftUI

@main
struct DJOneHubWatchApp: App {
    @StateObject private var callSession = WatchCallSession()

    var body: some Scene {
        WindowGroup {
            WatchCallView()
                .environmentObject(callSession)
        }
    }
}
