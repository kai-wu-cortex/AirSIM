import Contacts
import Foundation

enum ContactAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case limited
    case denied
}

enum ContactAccessAction: Equatable {
    case request
    case load
    case waitForUser
    case blocked
}

enum ContactAccessPolicy {
    static func action(
        for state: ContactAuthorizationState,
        userInitiated: Bool
    ) -> ContactAccessAction {
        switch state {
        case .authorized, .limited: return .load
        case .notDetermined: return userInitiated ? .request : .waitForUser
        case .denied: return .blocked
        }
    }
}

protocol ContactFetching: Sendable {
    func authorizationState() -> ContactAuthorizationState
    func requestAccess() async throws -> Bool
    func fetchAll() throws -> [ContactStore.Contact]
}

/// 非主线程联系人读取器，避免在 Swift 6 下跨线程持有 CNContactStore。
struct ContactFetcher: ContactFetching {
    func authorizationState() -> ContactAuthorizationState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .authorized }
        if #available(iOS 18.0, *), status == .limited { return .limited }
        return status == .notDetermined ? .notDetermined : .denied
    }

    func requestAccess() async throws -> Bool {
        try await CNContactStore().requestAccess(for: .contacts)
    }

    func fetchAll() throws -> [ContactStore.Contact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var contacts: [ContactStore.Contact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            if let value = Self.contact(from: contact) { contacts.append(value) }
        }
        return contacts
    }

    func displayName(for number: String) throws -> String? {
        let state = authorizationState()
        guard state == .authorized || state == .limited else { return nil }
        let target = ContactStore.normalized(number)
        guard !target.isEmpty else { return nil }
        let contacts = try fetchAll()
        if let exact = contacts.first(where: { $0.phones.contains(target) }) {
            return exact.name
        }
        guard target.count >= 7 else { return nil }
        let suffix = target.suffix(7)
        return contacts.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(suffix) }
        }?.name
    }

    static func contact(from contact: CNContact) -> ContactStore.Contact? {
        let name = (CNContactFormatter.string(from: contact, style: .fullName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phones = contact.phoneNumbers.map { ContactStore.normalized($0.value.stringValue) }
            .filter { !$0.isEmpty }
        guard !name.isEmpty, !phones.isEmpty else { return nil }
        return .init(id: contact.identifier, name: name, phones: phones,
                     emails: contact.emailAddresses.map { $0.value as String },
                     photoData: contact.thumbnailImageData)
    }
}

@MainActor
final class ContactStore: ObservableObject {
    struct Contact: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let phones: [String]
        let emails: [String]
        let photoData: Data?
    }

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var isAuthorized = false
    @Published private(set) var isLimitedAccess = false
    @Published private(set) var authorizationState: ContactAuthorizationState = .notDetermined
    @Published var errorMessage: String?
    private let cache: ContactCacheStore
    private let fetcher: any ContactFetching
    private var contactsObserver: NSObjectProtocol?

    init(fileManager: FileManager = .default, fetcher: any ContactFetching = ContactFetcher(),
         cache: ContactCacheStore? = nil) {
        self.cache = cache ?? ContactCacheStore(fileManager: fileManager)
        self.fetcher = fetcher
        // 联系人属于手机数据。模块离线或系统联系人数据库暂不可读时，先展示本机副本。
        contacts = self.cache.load()
        let state = fetcher.authorizationState()
        authorizationState = state
        isAuthorized = state == .authorized || state == .limited
        isLimitedAccess = state == .limited
        contactsObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh(force: true)
            }
        }
    }

    deinit {
        if let contactsObserver {
            NotificationCenter.default.removeObserver(contactsObserver)
        }
    }

    nonisolated static func normalized(_ phone: String) -> String {
        var value = phone.filter { $0.isNumber || $0 == "+" }
        if value.hasPrefix("+86") {
            value.removeFirst(3)
        } else if value.hasPrefix("86"), value.count > 11 {
            value.removeFirst(2)
        }
        return value
    }

    func loadIfAuthorized(force: Bool = false) async {
        await refresh(userInitiated: false, force: force)
    }

    func requestAccessAndLoad() async {
        await refresh(userInitiated: true, force: true)
    }

    private func refresh(userInitiated: Bool = false, force: Bool = false) async {
        do {
            // 手机重启后可能先在数据保护尚未解锁时读取到空数组；每次前台刷新都重试磁盘缓存。
            let cachedContacts = cache.load()
            if !cachedContacts.isEmpty {
                contacts = cachedContacts
            }

            let fetcher = self.fetcher
            var state = await Task.detached(priority: .userInitiated) {
                fetcher.authorizationState()
            }.value
            authorizationState = state
            isLimitedAccess = state == .limited

            switch ContactAccessPolicy.action(for: state, userInitiated: userInitiated) {
            case .request:
                let granted = try await Task.detached(priority: .userInitiated) {
                    try await fetcher.requestAccess()
                }.value
                state = granted ? .authorized : .denied
                authorizationState = state
                guard granted else {
                    isAuthorized = false
                    errorMessage = "未获得通讯录访问权限"
                    return
                }
            case .load:
                break
            case .waitForUser:
                isAuthorized = false
                errorMessage = nil
                return
            case .blocked:
                isAuthorized = false
                errorMessage = "通讯录权限已关闭，请在系统设置中开启"
                return
            }

            isAuthorized = true
            isLimitedAccess = authorizationState == .limited
            // 非用户主动刷新时优先使用已恢复的缓存；联系人变更通知和联系人页
            // 进入时会 force，确保新增联系人不会被旧缓存挡住。
            guard force || userInitiated || contacts.isEmpty || cache.needsNameRefresh else {
                errorMessage = nil
                return
            }
            contacts = try await Task.detached(priority: .userInitiated) {
                try fetcher.fetchAll()
            }.value
            guard cache.save(contacts) else {
                errorMessage = "通讯录已读取，但保存到本机失败"
                return
            }
            errorMessage = nil
        } catch {
            isAuthorized = false
            isLimitedAccess = false
            errorMessage = error.localizedDescription
        }
    }

    func contact(for number: String) -> Contact? {
        let target = Self.normalized(number)
        guard !target.isEmpty else { return nil }
        if let exact = contacts.first(where: { $0.phones.contains(target) }) { return exact }
        guard target.count >= 7 else { return nil }
        let suffix = target.suffix(7)
        return contacts.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(suffix) }
        }
    }

    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "未知号码" }
        return contact(for: number)?.name ?? number
    }
}

/// 通讯录缓存仅保存在 App 沙盒，不会上传到模块或 Push Relay。
final class ContactCacheStore {
    private struct Snapshot: Codable {
        let nameFormatVersion: Int
        let contacts: [ContactStore.Contact]
    }
    private static let nameFormatVersion = 2
    private(set) var needsNameRefresh = true
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileManager = .default
        self.fileURL = fileURL
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let durableRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let directory = durableRoot.appendingPathComponent("AirSIM", isDirectory: true)
        fileURL = directory.appendingPathComponent("contacts.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> [ContactStore.Contact] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                needsNameRefresh = snapshot.nameFormatVersion != Self.nameFormatVersion
                return snapshot.contacts
            }
            needsNameRefresh = true
            return try JSONDecoder().decode([ContactStore.Contact].self, from: data)
        } catch {
            Self.log("读取通讯录缓存失败：\(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func save(_ contacts: [ContactStore.Contact]) -> Bool {
        do {
            let data = try JSONEncoder().encode(Snapshot(nameFormatVersion: Self.nameFormatVersion,
                                                       contacts: contacts))
            try data.write(to: fileURL, options: [.atomic])
            needsNameRefresh = false
            return true
        } catch {
            Self.log("保存通讯录缓存失败：\(error.localizedDescription)")
            return false
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        print("[AirSIM Contacts] \(message)")
#endif
    }
}
