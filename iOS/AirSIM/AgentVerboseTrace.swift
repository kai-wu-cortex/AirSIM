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
    let category: String
    let pollRoute: String?

    var pollEndpoint: String? {
        guard method == "GET", category == "vowlan", pollRoute != nil else { return nil }
        let endpoint = path.components(separatedBy: "?")[0]
        return ["/api/events", "/api/calls/events"].contains(endpoint) ? endpoint : nil
    }
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
    private var pollRuns: [String: PollRun] = [:]

    private struct PollRun {
        let path: String
        let route: String
        let fingerprint: String
        let first: Date
        var last: Date
        var count: Int
        let id: UUID
    }

    init(initiallyEnabled: Bool, maxEntries: Int, persistenceURL: URL?) {
        enabled = initiallyEnabled
        self.maxEntries = max(1, maxEntries)
        self.persistenceURL = persistenceURL
        let loaded = Self.load(from: persistenceURL)
        entries = loaded
        trimIfNeeded()
    }

    func isEnabled() -> Bool { enabled }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { pollRuns.removeAll() }
        if persistenceURL != nil {
            UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        }
    }

    func begin(method: String, path: String, bodyBytes: Int, category: String = "http", pollRoute: String? = nil) -> AgentVerboseTraceContext? {
        guard enabled else { return nil }
        let context = AgentVerboseTraceContext(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            method: method.uppercased(),
            path: path,
            startedAt: Date(), category: category, pollRoute: pollRoute
        )
        if context.pollEndpoint != nil { return context }
        append(
            context,
            stage: .request,
            detail: bodyBytes > 0 ? "发起请求 · body \(bodyBytes) B" : "发起请求"
        )
        return context
    }

    func recordRoute(_ context: AgentVerboseTraceContext, route: String, attempt: Int, error: String? = nil) {
        guard enabled, context.pollEndpoint == nil else { return }
        var detail = "第 \(attempt) 次尝试 · \(route)"
        if let error, !error.isEmpty { detail += " · \(error)" }
        append(context, stage: .route, detail: detail)
    }

    func finish(_ context: AgentVerboseTraceContext, statusCode: Int, responseBytes: Int, fingerprint: String? = nil) {
        guard enabled else { return }
        if let endpoint = context.pollEndpoint {
            if let fingerprint, let route = context.pollRoute, (200..<300).contains(statusCode) {
                recordPoll(context, endpoint: endpoint, route: route, fingerprint: fingerprint,
                           statusCode: statusCode, responseBytes: responseBytes)
                return
            }
            recordPollAttempt(context)
        }
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
        recordPollAttempt(context)
        append(
            context,
            stage: .failure,
            detail: Self.redact(error),
            elapsedMilliseconds: elapsed(from: context)
        )
        persist()
    }

    private func recordPollAttempt(_ context: AgentVerboseTraceContext) {
        guard let endpoint = context.pollEndpoint else { return }
        pollRuns.removeValue(forKey: endpoint)
        append(context, stage: .request, detail: "发起轮询", timestamp: context.startedAt)
        if let route = context.pollRoute {
            append(context, stage: .route, detail: route, timestamp: context.startedAt)
        }
    }

    private func recordPoll(_ context: AgentVerboseTraceContext, endpoint: String, route: String,
                            fingerprint: String, statusCode: Int, responseBytes: Int) {
        let now = Date()
        var run = PollRun(path: context.path, route: route, fingerprint: fingerprint,
                          first: now, last: now, count: 1, id: UUID())
        if var prior = pollRuns[endpoint], prior.path == context.path, prior.route == route,
           prior.fingerprint == fingerprint, now.timeIntervalSince(prior.last) <= 90,
           let index = entries.firstIndex(where: { $0.id == prior.id }) {
            entries.remove(at: index)
            prior.count += 1
            prior.last = now
            run = prior
        }
        pollRuns[endpoint] = run
        entries.append(AgentVerboseTraceEntry(
            id: run.id, traceID: context.id, timestamp: now, stage: .response,
            method: context.method, path: context.path,
            detail: "HTTP \(statusCode) · \(responseBytes) B · 同一响应连续 \(run.count) 次",
            elapsedMilliseconds: elapsed(from: context), source: "APP", category: context.category,
            fields: ["first_success": Self.iso8601.string(from: run.first), "route": route]
        ))
        trimIfNeeded()
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
        // Call-control failures must remain diagnosable without full request tracing.
        let recoveryVerification = category == "audio" && phase == "bridge_recovery_verified"
        guard enabled || recoveryVerification || (isFailure && ["call-control", "audio", "sms"].contains(category)) else { return }
        if isFailure && (category == "vowlan" || category == "call-terminal") { pollRuns.removeAll() }
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

    /// Always retain a bounded, non-identifying startup timeline, even when full
    /// request tracing is off. Never accept arbitrary call data through this API.
    func recordAudioStartup(phase: String, elapsedMilliseconds: Int? = nil,
                            rollbackReason: LocalCallAudioRollbackReason? = nil, carrierRingback: Bool = false) {
        let allowed: Set<String> = ["answer_observed", "phone_start", "engine_ready",
                                    "agent_register", "agent_ready", "pcm_ready",
                                    "first_downlink", "stopped", "failed", "rollback"]
        guard allowed.contains(phase) else { return }
        var fields = ["phase": phase]
        if carrierRingback { fields["audio_mode"] = "carrier_ringback" }
        if phase == "rollback", let rollbackReason { fields["reason"] = rollbackReason.rawValue }
        entries.append(AgentVerboseTraceEntry(
            id: UUID(), traceID: "--------", timestamp: Date(),
            stage: phase == "failed" ? .failure : .event,
            method: "AUDIO", path: "通话音频启动", detail: "",
            elapsedMilliseconds: elapsedMilliseconds.map { max(0, $0) },
            source: "APP", category: "call-audio", fields: fields
        ))
        trimIfNeeded()
        persist()
    }

    func snapshot() -> [AgentVerboseTraceEntry] { entries }

    func recordFailure(category: String, phase: String, error: Error,
                       file: String = #fileID, function: String = #function, line: Int = #line) {
        var fields = ["phase": phase, "file": file, "function": function, "line": String(line)]
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        for depth in 0..<4 {
            guard let value = current, seen.insert(ObjectIdentifier(value)).inserted else { break }
            let prefix = depth == 0 ? "error" : "underlying_\(depth)"
            fields["\(prefix)_domain"] = value.domain
            fields["\(prefix)_code"] = String(value.code)
            fields["\(prefix)_message"] = Self.redact(value.localizedDescription)
            if let reason = value.localizedFailureReason { fields["\(prefix)_reason"] = Self.redact(reason) }
            if let recovery = value.localizedRecoverySuggestion { fields["\(prefix)_recovery"] = Self.redact(recovery) }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        recordEvent(source: "APP", category: category, phase: phase,
                    title: "链路异常", detail: Self.redact(error.localizedDescription), fields: fields, isFailure: true)
    }

    private static func redact(_ text: String) -> String {
        var value = String(text.prefix(1500))
        for pattern in ["https?://[^\\s]+", "(?i)(token|secret|password|authorization)[=:]\\s*[^\\s]+",
                        "[A-Za-z0-9_+/-]{32,}={0,2}", "\\+?[0-9]{11,15}"] {
            value = value.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return value
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        pollRuns.removeAll()
        persist()
    }

    func exportText(agentEvents: [AgentVerboseRemoteEvent]) -> String {
        var lines = [
            "AirSIM Agent Verbose Trace",
            "app_version=\(AppInformation.version)",
            "exported_at=\(Self.iso8601.string(from: Date()))",
            "verbose_enabled=\(enabled)",
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
        elapsedMilliseconds: Int? = nil,
        timestamp: Date = Date()
    ) {
        entries.append(
            AgentVerboseTraceEntry(
                id: UUID(),
                traceID: context.id,
                timestamp: timestamp,
                stage: stage,
                method: context.method,
                path: context.path,
                detail: detail,
                elapsedMilliseconds: elapsedMilliseconds,
                source: nil,
                category: context.category,
                fields: nil
            )
        )
        trimIfNeeded()
    }

    private func elapsed(from context: AgentVerboseTraceContext) -> Int {
        max(0, Int(Date().timeIntervalSince(context.startedAt) * 1_000))
    }

    private func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        // Reserve up to 20 recent call failures so standby polling cannot erase
        // yesterday's dial error. Keep the same total storage bound and ordering.
        let calls = entries.filter { $0.category == "call-control" && $0.stage == .failure }
            .suffix(min(20, maxEntries))
        let groups = Dictionary(grouping: entries.filter { $0.category != "call-control" && $0.stage == .failure }, by: \.category)
        let others = groups.values.compactMap { $0.last }.sorted { $0.timestamp < $1.timestamp }
            .suffix(min(20, maxEntries - calls.count))
        let retained = Set((Array(calls) + Array(others)).map(\.id))
        var excess = entries.count - maxEntries
        entries.removeAll { entry in
            guard excess > 0, !retained.contains(entry.id) else { return false }
            excess -= 1
            return true
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
            .appendingPathComponent("AirSIM", isDirectory: true)
            .appendingPathComponent("agent-verbose-trace.json")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
