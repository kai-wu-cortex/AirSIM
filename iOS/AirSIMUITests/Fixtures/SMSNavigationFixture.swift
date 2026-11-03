#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Simulator-only UI-test data. Never compiled into device or Release binaries.
/// Uses temporary history and process-local preference overrides, not paired data.
@MainActor
struct SMSNavigationFixture {
    let model: AppModel
    let updates: AppUpdateController
    let defaults: UserDefaults

    private static let previewStartedAt = Date()

    static var previewCall: CallRecord? {
        guard let phase = ProcessInfo.processInfo.environment["AIRSIM_UI_CALL"],
              ["incoming", "active"].contains(phase) else { return nil }
        return CallRecord(id: "layout-preview", index: 0, direction: "incoming", state: phase,
            number: "+86 138 0000 0000", startedAt: previewStartedAt, updatedAt: previewStartedAt, endedAt: nil, missed: false)
    }

    static func fromLaunchEnvironment() -> Self? {
        guard ProcessInfo.processInfo.environment["AIRSIM_UI_FIXTURE"] == "sms-navigation" else { return nil }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[ConnectionModePreference.key] = AirSIMConnectionMode.bluetooth.rawValue
        arguments[CloudSignalingPreference.key] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let defaults = UserDefaults(suiteName: "AirSIM.UITest.\(UUID().uuidString)")!
        defaults.set(true, forKey: "airsim.first-connection-complete")
        defaults.set(PhoneTab.messages.rawValue, forKey: "airsim.selected-tab")
        let history = LocalHistoryStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AirSIM-UI-\(UUID().uuidString)", isDirectory: true))
        history.saveMessages([SMSMessage(sender: "sms-navigation-fixture", content: "test message",
            code: nil, timestamp: Date(timeIntervalSince1970: 1_790_000_000), deliveryID: "navigation-fixture")])
        let contactCache = ContactCacheStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AirSIM-UI-contacts-\(UUID().uuidString).json"))
        let model = AppModel(contactStore: ContactStore(fetcher: NavigationContactFetcher(), cache: contactCache),
                             historyStore: history)
        model.messages = history.loadMessages()
        let updates = AppUpdateController(defaults: defaults, fetch: { [] })
        updates.acknowledgeNotes()
        return Self(model: model, updates: updates, defaults: defaults)
    }
}

private struct NavigationContactFetcher: ContactFetching {
    func authorizationState() -> ContactAuthorizationState { .authorized }
    func requestAccess() async throws -> Bool { true }
    func fetchAll() throws -> [ContactStore.Contact] {
        [.init(id: "navigation-contact", name: "Navigation Alice", phones: ["2025550100"], emails: [], photoData: nil)]
    }
}
#endif
