import Foundation

/// 用户明确选择的连接方式。只有 `automatic` 可以跨传输回退。
enum AirSIMConnectionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case vowlan
    case bluetooth
    case cloud
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vowlan: return "VoWLAN"
        case .bluetooth: return "蓝牙"
        case .cloud: return "云端"
        case .automatic: return "自动"
        }
    }

    var detail: String {
        switch self {
        case .vowlan: return "使用 Wi-Fi、手机热点或手动 VPN 地址直连，不连接 Relay"
        case .bluetooth: return "仅使用蓝牙控制与通话音频，不依赖 Wi-Fi 或 Relay"
        case .cloud: return "仅使用 Relay、PushKit 与 CallKit"
        case .automatic: return "按 VoWLAN、蓝牙、云端的可用性自动选择"
        }
    }
}

enum ConnectionModePreference {
    static let key = "airsim.connection-mode"

    static func selected(defaults: UserDefaults = .standard) -> AirSIMConnectionMode {
        if let rawValue = defaults.string(forKey: key),
           let mode = AirSIMConnectionMode(rawValue: rawValue) {
            return mode
        }
        // 兼容升级前的两个布尔开关；不在读取时改写，避免测试套件和扩展进程副作用。
        if defaults.bool(forKey: LocalModePreference.key) { return .vowlan }
        if defaults.object(forKey: CloudModePreference.key) != nil,
           !defaults.bool(forKey: CloudModePreference.key) {
            return .vowlan
        }
        return .automatic
    }

    static func set(
        _ mode: AirSIMConnectionMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: key)
        defaults.set(mode == .vowlan, forKey: LocalModePreference.key)
        defaults.set(
            mode == .cloud || mode == .automatic,
            forKey: CloudModePreference.key
        )
    }
}

/// The user-selected Android agent is a routing constraint, not just UI state.
/// Keeping it independent from the connection mode lets automatic mode choose
/// VoWLAN/VoBLE/cloud for one phone without silently jumping to another phone.
enum AndroidAgentBindingPreference {
    static let key = "airsim.bound-android-agent-id"

    static func selected(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func set(_ agentID: String?, defaults: UserDefaults = .standard) {
        let value = agentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(value, forKey: key) }
    }

    static func permits(_ candidate: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let selected = selected(defaults: defaults) else { return true }
        return candidate == selected
    }
}

struct PairedAndroidDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let agentKind: String?
}

enum PairedAndroidDeviceStore {
    private static let recordsKey = "airsim.paired-android-devices.v1"
    private static let forgottenKey = "airsim.forgotten-android-devices.v1"
    private static let peripheralsKey = "airsim.android-device-peripherals.v1"

    static func records(defaults: UserDefaults = .standard) -> [PairedAndroidDeviceRecord] {
        guard let data = defaults.data(forKey: recordsKey),
              let values = try? JSONDecoder().decode([PairedAndroidDeviceRecord].self, from: data) else { return [] }
        return values.filter { permits($0.id, defaults: defaults) }
    }
    static func remember(_ record: PairedAndroidDeviceRecord, defaults: UserDefaults = .standard) {
        guard !record.id.isEmpty, permits(record.id, defaults: defaults) else { return }
        var values = records(defaults: defaults).filter { $0.id != record.id }
        values.append(record)
        defaults.set(try? JSONEncoder().encode(values), forKey: recordsKey)
    }
    static func forget(_ id: String, defaults: UserDefaults = .standard) {
        var forgotten = Set(defaults.stringArray(forKey: forgottenKey) ?? [])
        forgotten.insert(id)
        defaults.set(Array(forgotten), forKey: forgottenKey)
        defaults.set(try? JSONEncoder().encode(records(defaults: defaults)), forKey: recordsKey)
        if AndroidAgentBindingPreference.selected(defaults: defaults) == id {
            AndroidAgentBindingPreference.set(nil, defaults: defaults)
        }
    }
    static func permits(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: forgottenKey) ?? []).contains(id)
    }
    static func hasForgottenDevices(defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: forgottenKey) ?? []).isEmpty
    }
    static func allowPairing(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set((defaults.stringArray(forKey: forgottenKey) ?? []).filter { $0 != id }, forKey: forgottenKey)
    }
    static func rememberPeripheral(_ peripheralID: String, for id: String, defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: peripheralsKey) as? [String: String] ?? [:]
        values[id] = peripheralID
        defaults.set(values, forKey: peripheralsKey)
    }
    static func permitsPeripheral(_ peripheralID: String, defaults: UserDefaults = .standard) -> Bool {
        let values = defaults.dictionary(forKey: peripheralsKey) as? [String: String] ?? [:]
        return !values.contains { $0.value == peripheralID && !permits($0.key, defaults: defaults) }
    }
}

struct ConnectionModeRuntimePolicy: Equatable, Sendable {
    let mode: AirSIMConnectionMode

    var startsVoWLAN: Bool { mode == .vowlan || mode == .automatic }
    var startsBluetooth: Bool { mode == .bluetooth || mode == .automatic }
    var startsCloud: Bool { mode == .cloud || mode == .automatic }
    var allowsCrossModeFallback: Bool { mode == .automatic }

    /// 蓝牙来电同样依赖系统通话界面；仅传统 VoWLAN 本地模式关闭 CallKit。
    var usesCallKit: Bool { mode != .vowlan }
}

/// 统一拨号路由选择。显式模式绝不借用其他链路；自动模式只在通话建立前
/// 按 VoWLAN、VoBLE、云端顺序选择，建立后仍由 LockedCallTransport 固定。
enum DialRouteSelector {
    static func preferred(
        mode: AirSIMConnectionMode,
        vowlanReady: Bool,
        bluetoothReady: Bool,
        cloudReady: Bool
    ) -> CallTransport? {
        switch mode {
        case .vowlan:
            return vowlanReady ? .vowlan : nil
        case .bluetooth:
            return bluetoothReady ? .bluetooth : nil
        case .cloud:
            return cloudReady ? .cloud : nil
        case .automatic:
            if vowlanReady { return .vowlan }
            if bluetoothReady { return .bluetooth }
            if cloudReady { return .cloud }
            return nil
        }
    }
}
