import Foundation
import MetricKit

/// MetricKit delivers crash/hang diagnostics after the next launch. Persist the
/// last few payloads so manual feedback can attach a real crash stack even when
/// the crash itself prevented the normal feedback trigger.
final class CrashDiagnosticsStore: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnosticsStore()
    private let lock = NSLock()
    private var started = false
    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("airsim-crash-diagnostics.json")
    }()

    private override init() { super.init() }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.filter { !($0.crashDiagnostics?.isEmpty ?? true) }
        guard !crashes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var stored = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: fileURL))) ?? []
        for crash in crashes {
            stored.append(crash.jsonRepresentation().base64EncodedString())
        }
        stored = Array(stored.suffix(5))
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Newest first, bounded so feedback remains uploadable.
    func recent() -> String {
        lock.lock()
        defer { lock.unlock() }
        let stored = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: fileURL))) ?? []
        let decoded = stored.reversed().compactMap { encoded -> String? in
            guard let data = Data(base64Encoded: encoded),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
        return String(decoded.joined(separator: "\n---\n").suffix(240_000))
    }
}
