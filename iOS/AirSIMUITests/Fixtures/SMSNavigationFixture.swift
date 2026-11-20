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
        let design = ProcessInfo.processInfo.environment["AIRSIM_UI_DESIGN"] == "1"
        return CallRecord(id: "layout-preview", index: 0, direction: "incoming", state: phase,
            number: design ? "13800138000" : ProcessInfo.processInfo.environment["AIRSIM_UI_REGION_NUMBER"] ?? (ProcessInfo.processInfo.environment["AIRSIM_UI_REGION"] == "1" ? "+86 138 0013 8000" : "+86 138 0000 0000"),
            startedAt: previewStartedAt, updatedAt: previewStartedAt, endedAt: nil, missed: false,
            sourceAgentID: design ? "ui-offline-device" : nil,
            slotIndex: design || ProcessInfo.processInfo.environment["AIRSIM_UI_REGION"] == "1" ? 1 : nil)
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
        if ProcessInfo.processInfo.environment["AIRSIM_UI_DEVICE"] == "1" {
            let device = PairedAndroidDeviceRecord(id: "ui-offline-device", deviceName: "OnePlus PLR110", agentKind: "standalone")
            arguments["airsim.paired-android-devices.v1"] = try! JSONEncoder().encode([device])
            arguments[AndroidAgentBindingPreference.key] = device.id
            let slots = try! JSONDecoder().decode([AndroidSIMSlot].self, from: Data("""
            [{"id":"ui-sim-1","label":"SIM 1","slot_index":0,"carrier_name":"中国联通","number":"+8613800138000"},
             {"id":"ui-sim-2","label":"SIM 2","slot_index":1,"carrier_name":"中国移动","number":"+8613900139000"}]
            """.utf8))
            SMSSIMPreference.remember(agentID: device.id, slots: slots)
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
        if ProcessInfo.processInfo.environment["AIRSIM_UI_DESIGN"] == "1" {
            _ = contactCache.save([ContactStore.Contact(id: "design-contact", name: "张先生",
                phones: ["13800138000"], emails: [], photoData: nil)])
        }
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
            if ProcessInfo.processInfo.environment["AIRSIM_UI_VERIFIED_DURATIONS"] == "1" {
                calls[0].androidRingingDurationMS = 12_500
                calls[1].androidConnectedDurationMS = 63_000
                _ = history.unseenMissedCallIDs(in: [])
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
        var contacts = [ContactStore.Contact(id: "navigation-contact", name: "Navigation Alice", phones: ["2025550100"], emails: [], photoData: nil)]
        if ProcessInfo.processInfo.environment["AIRSIM_UI_DESIGN"] == "1" {
            contacts.append(.init(id: "design-contact", name: "张先生", phones: ["13800138000"], emails: [], photoData: nil))
        }
        return contacts
    }
}
#endif
