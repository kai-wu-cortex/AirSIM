import CryptoKit
import Foundation

struct EmbeddedModuleUpdateInfo: Decodable, Sendable {
    let version: String
    let platform: String
    let publicKey: String
    let fullSHA256: String?
    let recoverySHA256: String?
    let cleanupSHA256: String?

    enum CodingKeys: String, CodingKey {
        case version, platform
        case publicKey = "public_key"
        case fullSHA256 = "full_sha256"
        case recoverySHA256 = "recovery_sha256"
        case cleanupSHA256 = "cleanup_sha256"
    }

    var expectedPublicKeyID: String? {
        guard let key = Data(base64Encoded: publicKey), key.count == 32 else { return nil }
        return SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum ModuleUpdatePackageIntegrity {
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(
        packageURL: URL,
        kind: ModuleUpdatePackageKind,
        info: EmbeddedModuleUpdateInfo,
        agentPublicKeyID: String?
    ) throws {
        let expectedHash: String?
        switch kind {
        case .full: expectedHash = info.fullSHA256
        case .recovery: expectedHash = info.recoverySHA256
        case .cleanup: expectedHash = info.cleanupSHA256
        }
        guard let expectedHash,
              expectedHash.count == 64 else {
            throw ModuleUpdateIntegrityError.missingPackageDigest
        }
        let actualHash = try sha256(of: packageURL)
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw ModuleUpdateIntegrityError.packageDigestMismatch
        }
        if let agentPublicKeyID = agentPublicKeyID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !agentPublicKeyID.isEmpty,
           let expectedKeyID = info.expectedPublicKeyID,
           agentPublicKeyID.caseInsensitiveCompare(expectedKeyID) != .orderedSame {
            throw ModuleUpdateIntegrityError.agentSigningKeyMismatch(
                expected: expectedKeyID,
                actual: agentPublicKeyID
            )
        }
    }
}

enum ModuleUpdateIntegrityError: LocalizedError {
    case missingPackageDigest
    case packageDigestMismatch
    case agentSigningKeyMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .missingPackageDigest:
            return "App 内置 Agent 包缺少完整性信息，请更新或重新安装 App"
        case .packageDigestMismatch:
            return "App 内置 Agent 包已损坏，已在上传前停止安装"
        case let .agentSigningKeyMismatch(expected, actual):
            return "Agent 签名公钥不兼容（需要 \(expected)，模块为 \(actual)）"
        }
    }
}

enum ModuleUpdatePackageKind: Equatable, Sendable {
    case full
    case recovery
    case cleanup
}

enum ModuleUpdateLogPolicy {
    private static let operationStartMarker = "phase=uploading progress=5"

    /// Older Agents expose one append-only update.log file. Keep only the last
    /// installation attempt so a successful repair is not visually mixed with
    /// stale ENOSPC or restart warnings from previous days.
    static func currentSession(from history: String) -> String {
        guard let marker = history.range(of: operationStartMarker, options: .backwards) else {
            return history
        }
        let prefix = history[..<marker.lowerBound]
        let start = prefix.lastIndex(of: "\n").map { history.index(after: $0) } ?? history.startIndex
        return String(history[start...])
    }

    /// The old init script can lose a PID between checking /proc and reading
    /// cmdline, and localhost:7575 is expected to refuse connections briefly
    /// while the Agent restarts. Keep these lines in the exported diagnostics,
    /// but do not present them as installation failures in the user-facing log.
    static func userFacingSession(from history: String) -> String {
        currentSession(from: history)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isExpectedRestartNoise(String($0)) }
            .map { line in
                let text = String(line)
                return text.hasSuffix(" error=")
                    ? String(text.dropLast(" error=".count))
                    : text
            }
            .joined(separator: "\n")
    }

    private static func isExpectedRestartNoise(_ line: String) -> Bool {
        if line.contains("/etc/init.d/djonehub_agent:"),
           line.contains("can't open /proc/"),
           line.contains("/cmdline: no such file") {
            return true
        }
        return line.contains("wget: can't connect to remote host (127.0.0.1): Connection refused")
    }
}

enum ModuleUpdatePackagePolicy {
    private static let expandedPayloadAllowance: UInt64 = 9 * 1_024 * 1_024
    private static let filesystemMargin: UInt64 = 512 * 1_024

    static func package(
        fullBytes: UInt64,
        recoveryBytes: UInt64,
        dataFreeBytes: UInt64?,
        installedVersion: String? = nil,
        targetVersion: String? = nil
    ) -> ModuleUpdatePackageKind {
        // App 内安装始终使用自释放包，包括同版本维修。完整包需要旧 Agent 同时保留上传缓存和
        // 约 9 MB 的解压暂存，预检空间看似足够时仍可能在最后一个文件 ENOSPC。
        if let installedVersion, !installedVersion.isEmpty,
           let targetVersion, !targetVersion.isEmpty {
            return .recovery
        }
        // 旧 Agent 可能不返回空间字段。未知时优先选择自释放恢复包，避免完整包
        // 同时占用上传缓存、解压暂存和旧运行时三份空间。
        guard let dataFreeBytes else { return .recovery }
        let fullRequirement = peakRequiredBytes(
            package: .full,
            fullBytes: fullBytes,
            recoveryBytes: recoveryBytes
        )
        if dataFreeBytes >= fullRequirement { return .full }
        return .recovery
    }

    static func peakRequiredBytes(
        package: ModuleUpdatePackageKind,
        fullBytes: UInt64,
        recoveryBytes: UInt64
    ) -> UInt64 {
        switch package {
        case .full:
            return fullBytes + expandedPayloadAllowance + filesystemMargin
        case .recovery:
            // 接收中的压缩包和验证后的恢复载荷会短暂同时存在。
            return recoveryBytes * 2 + filesystemMargin
        case .cleanup:
            return filesystemMargin
        }
    }

    static func shouldRunCleanupBootstrap(
        dataFreeBytes: UInt64?,
        recoveryBytes: UInt64
    ) -> Bool {
        guard let dataFreeBytes else { return true }
        return dataFreeBytes < peakRequiredBytes(
            package: .recovery,
            fullBytes: 0,
            recoveryBytes: recoveryBytes
        )
    }

    static func shouldRunPrecleanBootstrap(
        installedVersion: String?,
        targetVersion: String?,
        dataFreeBytes: UInt64?,
        recoveryBytes: UInt64
    ) -> Bool {
        // A known installed runtime means this is an in-place operation. Run
        // the tiny signed preclean stage every time so stale upload caches,
        // abandoned stages and obsolete rollback directories cannot consume
        // the narrow margin between receiving and expanding the recovery file.
        if let installedVersion = installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !installedVersion.isEmpty,
           let targetVersion = targetVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetVersion.isEmpty {
            return true
        }
        return shouldRunCleanupBootstrap(
            dataFreeBytes: dataFreeBytes,
            recoveryBytes: recoveryBytes
        )
    }
}

@MainActor
final class AgentRepairController: ObservableObject {
    @Published private(set) var status: ModuleUpdateStatus?
    @Published private(set) var installation: ModuleUpdateInstallationState?
    @Published private(set) var logText = ""
    @Published private(set) var exportLogText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isWaitingForReconnect = false
    @Published var errorMessage: String?

    private let api: DJOneHubAPI
    private var logOffset: Int64 = 0
    private var rawLogText = ""
    private var observedOperationID: String?

    init(api: DJOneHubAPI) {
        self.api = api
    }

    var embeddedVersion: String {
        embeddedInfo?.version ?? "--"
    }

    var recommendedStrategy: String {
        guard let packages = embeddedPackages else { return "安装包不完整" }
        let selected = ModuleUpdatePackagePolicy.package(
            fullBytes: packages.fullBytes,
            recoveryBytes: packages.recoveryBytes,
            dataFreeBytes: status?.dataFreeBytes,
            installedVersion: status?.installedVersion,
            targetVersion: embeddedVersion
        )
        return selected == .recovery ? "Preclean 差量恢复" : "完整原子安装"
    }

    var estimatedPeakBytes: UInt64? {
        guard let packages = embeddedPackages else { return nil }
        let selected = ModuleUpdatePackagePolicy.package(
            fullBytes: packages.fullBytes,
            recoveryBytes: packages.recoveryBytes,
            dataFreeBytes: status?.dataFreeBytes,
            installedVersion: status?.installedVersion,
            targetVersion: embeddedVersion
        )
        return ModuleUpdatePackagePolicy.peakRequiredBytes(
            package: selected,
            fullBytes: packages.fullBytes,
            recoveryBytes: packages.recoveryBytes
        )
    }

    func refresh() async {
        do {
            status = try await api.moduleUpdateStatus()
            errorMessage = nil
        } catch {
            errorMessage = "Agent 更新服务不可达：\(error.localizedDescription)"
            return
        }
        await refreshInstallationState()
        await fetchMoreLog()
    }

    func repairEmbeddedAgent() async {
        guard !isRunning else { return }
        guard status?.callActive != true else {
            errorMessage = "通话或语音运行期间不能重新安装 Agent"
            return
        }
        guard let fullURL = Bundle.main.url(forResource: "module-update", withExtension: "djupdate"),
              let recoveryURL = Bundle.main.url(forResource: "module-update-recovery", withExtension: "djupdate") else {
            errorMessage = "App 内置 Agent 安装包不完整"
            return
        }

        isRunning = true
        isWaitingForReconnect = false
        errorMessage = nil
        installation = nil
        observedOperationID = nil
        logText = ""
        exportLogText = ""
        rawLogText = ""
        logOffset = 0
        defer { isRunning = false }

        do {
            // 点击确认到真正上传之间空间可能已经变化；始终重新获取一次，而不是
            // 使用页面首次出现时的旧快照。
            if let latest = try? await api.moduleUpdateStatus() {
                status = latest
            }
            let fullBytes = fileSize(fullURL)
            let recoveryBytes = fileSize(recoveryURL)
            let selected = ModuleUpdatePackagePolicy.package(
                fullBytes: fullBytes,
                recoveryBytes: recoveryBytes,
                dataFreeBytes: status?.dataFreeBytes,
                installedVersion: status?.installedVersion,
                targetVersion: embeddedVersion
            )
            let selectedURL = selected == .recovery ? recoveryURL : fullURL
            guard let info = embeddedInfo else {
                throw ModuleUpdateIntegrityError.missingPackageDigest
            }
            try ModuleUpdatePackageIntegrity.validate(
                packageURL: selectedURL,
                kind: selected,
                info: info,
                agentPublicKeyID: status?.publicKeyID
            )
            if selected == .recovery,
               ModuleUpdatePackagePolicy.shouldRunPrecleanBootstrap(
                   installedVersion: status?.installedVersion,
                   targetVersion: embeddedVersion,
                   dataFreeBytes: status?.dataFreeBytes,
                   recoveryBytes: recoveryBytes
               ) {
                try await installLegacyCleanupBootstrap(info: info)
            }
            do {
                _ = try await api.uploadVerifiedModuleUpdate(from: selectedURL, mode: .repair)
            } catch {
                guard selected == .full,
                      ModuleUpdatePolicy.shouldUseLowSpaceRecovery(message: error.localizedDescription) else { throw error }
                try ModuleUpdatePackageIntegrity.validate(
                    packageURL: recoveryURL,
                    kind: .recovery,
                    info: info,
                    agentPublicKeyID: status?.publicKeyID
                )
                _ = try await api.uploadVerifiedModuleUpdate(from: recoveryURL, mode: .repair)
            }
            isWaitingForReconnect = true
            try await observeUntilTerminal()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func observeUntilTerminal() async throws {
        var lastConnectionError: Error?
        for _ in 0..<90 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            do {
                _ = try await api.health()
                isWaitingForReconnect = false
                await refreshInstallationState()
                await fetchMoreLog()
                if let phase = installation?.phase,
                   ["completed", "rolled_back", "failed"].contains(phase) {
                    if phase == "failed" { throw AgentRepairError.installationFailed(installation?.error ?? installation?.message ?? "Agent 安装失败") }
                    return
                }
            } catch {
                lastConnectionError = error
                isWaitingForReconnect = true
            }
        }
        throw AgentRepairError.reconnectTimedOut(lastConnectionError?.localizedDescription)
    }

    private func installLegacyCleanupBootstrap(info: EmbeddedModuleUpdateInfo) async throws {
        guard let cleanupURL = Bundle.main.url(
            forResource: "module-update-cleanup",
            withExtension: "djupdate"
        ) else {
            throw ModuleUpdateIntegrityError.missingPackageDigest
        }
        try ModuleUpdatePackageIntegrity.validate(
            packageURL: cleanupURL,
            kind: .cleanup,
            info: info,
            agentPublicKeyID: status?.publicKeyID
        )
        _ = try await api.uploadVerifiedModuleUpdate(from: cleanupURL, mode: .repair)
        isWaitingForReconnect = true
        // 0.3.39 在返回上传响应约 750 ms 后才真正重启。先越过旧进程仍能
        // 短暂响应的窗口，再要求恢复后的 Agent 连续可达。
        try await Task.sleep(for: .seconds(3))
        for _ in 0..<20 {
            if (try? await api.health()) != nil {
                isWaitingForReconnect = false
                status = try? await api.moduleUpdateStatus()
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AgentRepairError.reconnectTimedOut("旧 Agent 清理引导完成后未恢复")
    }

    private func refreshInstallationState() async {
        guard let state = try? await api.moduleUpdateInstallationState() else { return }
        if observedOperationID != state.operationID {
            observedOperationID = state.operationID
            logOffset = 0
            rawLogText = ""
            logText = ""
            exportLogText = ""
        }
        installation = state
    }

    private func fetchMoreLog() async {
        // Agent returns at most 64 KiB per request while the retained history can
        // be 256 KiB. Drain the available chunks so the latest operation marker
        // is reached immediately instead of showing only an old first page.
        for _ in 0..<8 {
            guard let chunk = try? await api.moduleUpdateLog(after: logOffset) else { return }
            if chunk.nextOffset < logOffset {
                rawLogText = ""
            }
            if !chunk.text.isEmpty {
                rawLogText += chunk.text
                let lines = rawLogText.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count > 500 {
                    rawLogText = lines.suffix(500).joined(separator: "\n")
                }
                exportLogText = ModuleUpdateLogPolicy.currentSession(from: rawLogText)
                logText = ModuleUpdateLogPolicy.userFacingSession(from: rawLogText)
            }
            logOffset = chunk.nextOffset
            if chunk.complete || chunk.text.isEmpty { break }
        }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber else { return 0 }
        return value.uint64Value
    }

    private var embeddedPackages: (fullBytes: UInt64, recoveryBytes: UInt64)? {
        guard let fullURL = Bundle.main.url(forResource: "module-update", withExtension: "djupdate"),
              let recoveryURL = Bundle.main.url(forResource: "module-update-recovery", withExtension: "djupdate") else {
            return nil
        }
        return (fileSize(fullURL), fileSize(recoveryURL))
    }

    private var embeddedInfo: EmbeddedModuleUpdateInfo? {
        guard let url = Bundle.main.url(forResource: "EmbeddedModuleUpdate", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EmbeddedModuleUpdateInfo.self, from: data)
    }
}

enum AgentRepairError: LocalizedError {
    case installationFailed(String)
    case reconnectTimedOut(String?)

    var errorDescription: String? {
        switch self {
        case let .installationFailed(message): return message
        case let .reconnectTimedOut(detail):
            return "Agent 重启后 90 秒内未恢复连接" + (detail.map { "：\($0)" } ?? "")
        }
    }
}
