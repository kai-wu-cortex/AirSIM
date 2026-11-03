import Foundation

enum CloudAgentTargetStore {
    private static let key = "airsim.cloud.target-agent-id"

    static func last(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: key),
              CloudAgentRouting.validID(value) else { return nil }
        return value
    }

    static func remember(_ agentID: String, defaults: UserDefaults = .standard) {
        guard CloudAgentRouting.validID(agentID) else { return }
        defaults.set(agentID, forKey: key)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

struct CloudCommandTarget: Equatable, Sendable {
    let agentID: String
    let routingVersion: Int
    func addingRouting(to body: [String: String]) -> [String: String] {
        var body = body
        body["target_agent_id"] = agentID
        return body
    }
}

enum CloudAgentRoutingError: LocalizedError {
    case updateRequired, unavailable, ambiguous
    var errorDescription: String? {
        switch self {
        case .updateRequired: return "请先更新 Relay 和安卓 Agent，以安全使用定向云端命令"
        case .unavailable: return "选定安卓手机当前没有可用的云端路由"
        case .ambiguous: return "有多部安卓手机在线，请先选择要使用的设备"
        }
    }
}

enum CloudAgentRouting {
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
            && !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
    static func select(boundAgentID: String?, agents: [CloudAndroidAgent], relayRoutingVersion: Int?,
                       requireOnline: Bool = true) throws -> CloudCommandTarget {
        guard relayRoutingVersion == 1 else { throw CloudAgentRoutingError.updateRequired }
        let candidates = agents.filter { validID($0.agentID) && (!requireOnline || $0.cloudOnline) }
        let agent: CloudAndroidAgent
        if let boundAgentID {
            guard let bound = candidates.first(where: { $0.agentID == boundAgentID }) else { throw CloudAgentRoutingError.unavailable }
            agent = bound
        } else {
            guard candidates.count <= 1 else { throw CloudAgentRoutingError.ambiguous }
            guard let only = candidates.first else { throw CloudAgentRoutingError.unavailable }
            agent = only
        }
        guard agent.commandRoutingVersion == 1 else { throw CloudAgentRoutingError.updateRequired }
        return CloudCommandTarget(agentID: agent.agentID, routingVersion: 1)
    }
    static func resultDelay(attempt: Int) -> TimeInterval { attempt <= 0 ? 0.5 : attempt == 1 ? 1 : 2 }

    static func callIdentity(_ call: IncomingVoIPCall) -> [String: Any] {
        ["call_uuid": call.uuid.uuidString.lowercased(), "generation": call.generation]
    }

    @MainActor static func poll<Response>(timeout: TimeInterval,
        request: () async throws -> Response, isTerminal: (Response) -> Bool) async throws -> Response {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var attempt = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let response = try await request()
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CloudCommandError.timeout }
            if isTerminal(response) { return response }
            try await Task.sleep(for: min(.seconds(resultDelay(attempt: attempt)), ContinuousClock.now.duration(to: deadline)))
            try Task.checkCancellation()
            attempt += 1
        }
        throw CloudCommandError.timeout
    }
}
