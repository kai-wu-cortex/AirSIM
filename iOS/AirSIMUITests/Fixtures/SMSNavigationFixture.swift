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
            number: ProcessInfo.processInfo.environment["AIRSIM_UI_REGION_NUMBER"] ?? (ProcessInfo.processInfo.environment["AIRSIM_UI_REGION"] == "1" ? "+86 138 0013 8000" : "+86 138 0000 0000"),
            startedAt: previewStartedAt, updatedAt: previewStartedAt, endedAt: nil, missed: false,
            slotIndex: ProcessInfo.processInfo.environment["AIRSIM_UI_REGION"] == "1" ? 1 : nil)
    }

    static func fromLaunchEnvironment() -> Self? {
        guard ProcessInfo.processInfo.environment["AIRSIM_UI_FIXTURE"] == "sms-navigation" else { return nil }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // The unit-test host also uses this inert root view. Its routing tests
        // must be able to write preferences; reserve UI overrides for UI runners.
        if NSClassFromString("XCTestCase") == nil {
            arguments[ConnectionModePreference.key] = AirSIMConnectionMode.bluetooth.rawValue
            arguments[CloudSignalingPreference.key] = false
        }
        if ProcessInfo.processInfo.environment["AIRSIM_UI_SMS_SIM"] == "1" {
            let agentID = "sms-sim-fixture"
            arguments[AndroidAgentBindingPreference.key] = agentID
            let slots = try! JSONDecoder().decode([AndroidSIMSlot].self, from: Data("""
            [{"id":"fixture-1","label":"SIM 1","slot_index":0},
             {"id":"fixture-2","label":"SIM 2","slot_index":1,"is_default_sms":true}]
            """.utf8))
            SMSSIMPreference.forget(agentID: agentID)
            SMSSIMPreference.remember(agentID: agentID, slots: slots)
        }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let defaults = UserDefaults(suiteName: "AirSIM.UITest.\(UUID().uuidString)")!
        defaults.set(true, forKey: "airsim.first-connection-complete")
        defaults.set(PhoneTab.messages.rawValue, forKey: "airsim.selected-tab")
        let history = LocalHistoryStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AirSIM-UI-\(UUID().uuidString)", isDirectory: true))
        let content = ProcessInfo.processInfo.environment["AIRSIM_UI_CODE_SMS"] == "1"
            ? "【AirSIM测试】验证码：123456，5分钟内有效。请勿泄露。" : "test message"
        history.saveMessages([SMSMessage(sender: "sms-navigation-fixture", content: content,
            code: nil, timestamp: Date(timeIntervalSince1970: 1_790_000_000), deliveryID: "navigation-fixture")])
        if ProcessInfo.processInfo.environment["AIRSIM_UI_SEARCH"] == "1" {
            history.saveMessages([
                SMSMessage(sender: "2025550100", content: "pickup-token 123456", code: nil, timestamp: Date(timeIntervalSince1970: 100)),
                SMSMessage(sender: "2025550100", content: "latest-only", code: nil, timestamp: Date(timeIntervalSince1970: 200)),
                SMSMessage(sender: "3035550123", content: "travel-plan", code: nil, timestamp: Date(timeIntervalSince1970: 300))])
        }
        let contactCache = ContactCacheStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AirSIM-UI-contacts-\(UUID().uuidString).json"))
        let model = AppModel(contactStore: ContactStore(fetcher: NavigationContactFetcher(), cache: contactCache),
                             historyStore: history)
        model.messages = history.loadMessages()
        if ProcessInfo.processInfo.environment["AIRSIM_UI_RECENTS"] == "1" {
            let now = Date()
            var calls = [CallRecord(id: "recent-a", index: 0, direction: "incoming", state: "ended", number: "13800138000", startedAt: now, updatedAt: now, endedAt: now, missed: true),
                CallRecord(id: "recent-b", index: 0, direction: "outgoing", state: "ended", number: "+86 138 0013 8000", startedAt: now.addingTimeInterval(-600), updatedAt: now, endedAt: now, missed: false)]
            if ProcessInfo.processInfo.environment["AIRSIM_UI_RECENTS_LONG_REGION"] == "1" {
                calls.append(CallRecord(id: "recent-long", index: 0, direction: "incoming", state: "ended",
                    number: "18844737195", startedAt: now.addingTimeInterval(-300), updatedAt: now,
                    endedAt: now, missed: false))
            }
            history.saveCallHistory(calls); model.callHistory = calls
        }
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
