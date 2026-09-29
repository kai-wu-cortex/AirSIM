import SwiftUI
import UIKit

/// 集中提供移动设备名称，避免 iPhone 上继续出现硬编码的 iPad 文案。
enum DeviceContext {
    static var displayName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
    }

    static var symbolName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad"
    }
}

/// iPhone/iPad 端保留 Mac 版的外观选项。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("跟随系统")
        case .light: return L10n.t("浅色")
        case .dark: return L10n.t("深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("跟随系统")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: L10n.appearanceKey) }
    }
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: L10n.languageKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: L10n.appearanceKey) ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: L10n.languageKey) ?? "") ?? .system
    }
}

/// 与 Mac 版一致的轻量本地化方案，避免首版引入重复字符串资源。
enum L10n {
    static let appearanceKey = "djonehub.appearance"
    static let languageKey = "djonehub.language"

    static var effectiveLanguage: AppLanguage {
        let saved = AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system
        if saved != .system { return saved }
        return (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("zh") ? .zh : .en
    }

    static func t(_ key: String) -> String {
        guard effectiveLanguage == .en else { return key }
        return english[key] ?? key
    }

    private static let english: [String: String] = [
        "拨号": "Dial", "最近": "Recents", "最近通话": "Recents", "短信": "Messages", "联系人": "Contacts", "通讯录": "Contacts", "设置": "Settings",
        "输入号码": "Enter number", "接听": "Accept", "拒接": "Decline", "挂断": "End", "静音": "Mute",
        "取消静音": "Unmute", "扬声器": "Speaker", "录音": "Record", "停止录音": "Stop Recording", "通话中": "On Call",
        "等待接听": "Waiting", "暂无通话记录": "No Recents", "新信息": "New Message", "收件人": "To",
        "短信内容": "Message", "发送": "Send", "已发送": "Sent", "取消": "Cancel", "刷新": "Refresh", "暂无短信": "No Messages",
        "读取后自动清理模块短信": "Auto-clean module SMS after reading", "清空全部短信": "Clear all SMS",
        "搜索姓名或号码": "Search name or number", "授权访问通讯录": "Allow Contacts Access", "通讯录为空": "No contacts",
        "状态": "Status", "通用": "General", "网络": "Network", "定位": "Location", "eSIM / 卡片": "eSIM / Card",
        "AT 调试": "AT Debug", "网络诊断": "Network Diagnostics", "运营商": "Operator", "SIM 卡": "SIM Card",
        "网络模式": "Network Mode", "信号强度": "Signal", "下载速度": "Download", "上传速度": "Upload",
        "本次流量": "Session Data", "允许 4G 上网": "Allow 4G Data", "检查 4G 出口": "Check 4G Route",
        "检查代理出口": "Check Proxy Route", "重启模块": "Reboot Module", "GPS 定位": "GPS Positioning",
        "等待定位": "Waiting for fix", "坐标": "Coordinates", "卫星": "Satellites", "卡片类型": "Card Type",
        "下载新 Profile": "Download New Profile", "通讯录检测": "Phonebook Check", "AT 指令": "AT Command",
        "发送 AT": "Send AT", "外观": "Appearance", "显示模式": "Display Mode", "语言": "Language", "跟随系统": "Follow System",
        "浅色": "Light", "深色": "Dark", "模块代理": "Module Agent", "在线": "Online", "离线": "Offline",
        "未接": "Missed", "呼入": "Incoming", "呼出": "Outgoing", "处理中": "Working", "保存": "Save",
        "删除": "Delete", "切换": "Switch", "重命名": "Rename", "错误": "Error"
    ]
}
