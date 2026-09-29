import Foundation

enum AgentVerboseTraceStage: String, Codable, Sendable {
    case request
    case route
    case response
    case event
    case failure
}

struct AgentVerboseTraceContext: Sendable {
    let id: String
    let method: String
    let path: String
    let startedAt: Date
}

struct AgentVerboseTraceEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let traceID: String
    let timestamp: Date
    let stage: AgentVerboseTraceStage
    let method: String
    let path: String
    let detail: String
    let elapsedMilliseconds: Int?
    let source: String?
    let category: String?
    let fields: [String: String]?
}

struct AgentVerboseRemoteEvent: Sendable {
    let sequence: UInt64
    let timestamp: String
    let category: String
    let direction: String
    let summary: String
    let payload: String
    let fields: [String: String]
}

actor AgentVerboseTraceRecorder {
    static let preferenceKey = "agent_verbose_trace_enabled"
    static let shared = AgentVerboseTraceRecorder(
        initiallyEnabled: UserDefaults.standard.bool(forKey: preferenceKey),
        maxEntries: 1_200,
        persistenceURL: defaultPersistenceURL()
    )

    private var enabled: Bool
    private let maxEntries: Int
    private let persistenceURL: URL?
    private var entries: [AgentVerboseTraceEntry]

    init(initiallyEnabled: Bool, maxEntries: Int, persistenceURL: URL?) {
        enabled = initiallyEnabled
        self.maxEntries = max(1, maxEntries)
        self.persistenceURL = persistenceURL
        let loaded = Self.load(from: persistenceURL)
        entries = loaded.count > self.maxEntries
            ? Array(loaded.suffix(self.maxEntries))
            : loaded
    }

    func isEnabled() -> Bool { enabled }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if persistenceURL != nil {
            UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        }
    }

    func begin(method: String, path: String, bodyBytes: Int) -> AgentVerboseTraceContext? {
        guard enabled else { return nil }
        let context = AgentVerboseTraceContext(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            method: method.uppercased(),
            path: path,
            startedAt: Date()
        )
        append(
            context,
            stage: .request,
            detail: bodyBytes > 0 ? "发起请求 · body \(bodyBytes) B" : "发起请求"
        )
        return context
    }

    func recordRoute(_ context: AgentVerboseTraceContext, route: String, attempt: Int, error: String? = nil) {
        guard enabled else { return }
        var detail = "第 \(attempt) 次尝试 · \(route)"
        if let error, !error.isEmpty { detail += " · \(error)" }
        append(context, stage: .route, detail: detail)
    }

    func finish(_ context: AgentVerboseTraceContext, statusCode: Int, responseBytes: Int) {
        guard enabled else { return }
        append(
            context,
            stage: .response,
            detail: "HTTP \(statusCode) · response \(responseBytes) B",
            elapsedMilliseconds: elapsed(from: context)
        )
        persist()
    }

    func fail(_ context: AgentVerboseTraceContext, error: String) {
        guard enabled else { return }
        append(
            context,
            stage: .failure,
            detail: error,
            elapsedMilliseconds: elapsed(from: context)
        )
        persist()
    }

    func recordEvent(
        source: String,
        category: String,
        phase: String,
        title: String,
        detail: String = "",
        fields: [String: String] = [:],
        isFailure: Bool = false
    ) {
        guard enabled else { return }
        let traceID = fields["trace_id"] ?? fields["command_id"].map { String($0.prefix(8)) }
        entries.append(
            AgentVerboseTraceEntry(
                id: UUID(),
                traceID: traceID ?? "--------",
                timestamp: Date(),
                stage: isFailure ? .failure : .event,
                method: phase.uppercased(),
                path: title,
                detail: detail,
                elapsedMilliseconds: nil,
                source: source.uppercased(),
                category: category,
                fields: fields
            )
        )
        trimIfNeeded()
        persist()
    }

    func snapshot() -> [AgentVerboseTraceEntry] { entries }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        persist()
    }

    func exportText(agentEvents: [AgentVerboseRemoteEvent]) -> String {
        var lines = [
            "DJOneHub Agent Verbose Trace",
            "exported_at=\(Self.iso8601.string(from: Date()))",
            "local_entries=\(entries.count) agent_events=\(agentEvents.count)",
            ""
        ]
        for entry in entries {
            let elapsed = entry.elapsedMilliseconds.map { " duration_ms=\($0)" } ?? ""
            let fields = (entry.fields ?? [:])
                .filter { $0.key != "trace_id" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            lines.append(
                "\(Self.iso8601.string(from: entry.timestamp)) [\(entry.source ?? "APP")] " +
                "trace=\(entry.traceID) stage=\(entry.stage.rawValue) " +
                "\(entry.method) \(entry.path)\(elapsed) \(fields) \(entry.detail)"
            )
        }
        for event in agentEvents {
            let trace = event.fields["trace_id"].map { " trace=\($0)" } ?? ""
            let fields = event.fields
                .filter { $0.key != "trace_id" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            lines.append(
                "\(event.timestamp) [AGENT] seq=\(event.sequence)\(trace) " +
                "\(event.category)/\(event.direction) \(event.summary) \(fields)"
            )
            if !event.payload.isEmpty { lines.append(event.payload) }
        }
        return lines.joined(separator: "\n")
    }

    private func append(
        _ context: AgentVerboseTraceContext,
        stage: AgentVerboseTraceStage,
        detail: String,
        elapsedMilliseconds: Int? = nil
    ) {
        entries.append(
            AgentVerboseTraceEntry(
                id: UUID(),
                traceID: context.id,
                timestamp: Date(),
                stage: stage,
                method: context.method,
                path: context.path,
                detail: detail,
                elapsedMilliseconds: elapsedMilliseconds,
                source: nil,
                category: nil,
                fields: nil
            )
        )
        trimIfNeeded()
    }

    private func elapsed(from context: AgentVerboseTraceContext) -> Int {
        max(0, Int(Date().timeIntervalSince(context.startedAt) * 1_000))
    }

    private func trimIfNeeded() {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func persist() {
        guard let persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: persistenceURL, options: .atomic)
        } catch {
            // Verbose tracing must never block the command it is observing.
        }
    }

    private static func load(from url: URL?) -> [AgentVerboseTraceEntry] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AgentVerboseTraceEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DJOneHub", isDirectory: true)
            .appendingPathComponent("agent-verbose-trace.json")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
