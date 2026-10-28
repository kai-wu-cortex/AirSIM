import Combine
import Foundation

enum VoWLANAuthenticatedHealth {
    static func fetch(agentID: String, endpoint: VoWLANEndpoint, credential: VoWLANCredential,
                      transport: LocalDeviceDirectory.HealthTransport) async throws -> VoWLANHealthIdentity {
        let signature = try VoWLANRequestSigner(credential: credential).sign(method: "GET", path: "/v1/health", body: Data())
        var request = URLRequest(url: endpoint.controlBaseURL.appendingPathComponent("v1/health"))
        // Tailscale/VPN round trips can exceed the old 4s budget even when the
        // gateway is healthy; the encrypted route proof already bound this peer.
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        VoWLANController.apply(signature, to: &request)
        let response = try await transport(request)
        guard response.statusCode == 200,
              let identity = try? JSONDecoder().decode(VoWLANHealthIdentity.self, from: response.body),
              identity.ok, identity.agentID == agentID,
              VoWLANHealthProof.verify(identity.identityProof, nonce: signature.nonce,
                agentID: agentID, credential: credential) else { throw VoWLANControllerError.authenticationFailed }
        return identity
    }
}

struct LocalDeviceRoutes: Equatable, Sendable {
    let agentID: String
    let vowlan: VoWLANEndpoint?
    let bluetoothReady: Bool
}

protocol LocalDeviceCredentialStoring: Sendable {
    func load(agentID: String) -> VoWLANCredential?
    func save(_ credential: VoWLANCredential, agentID: String) throws
    func remove(agentID: String)
    func legacy() -> VoWLANCredential?
}

@MainActor
final class LocalDeviceDirectory: ObservableObject {
    typealias HealthTransport = @Sendable (URLRequest) async throws -> WiredHTTPResponse
    private let credentials: any LocalDeviceCredentialStoring
    private let healthTransport: HealthTransport
    private let legacyBinding: () -> String?
    private let bluetoothReady: (String) -> Bool
    private let apiFactory: @Sendable (LocalAgentRoute) -> AirSIMAPI
    private final class Peer {
        let endpoint: VoWLANEndpoint
        let api: AirSIMAPI
        let credential: VoWLANCredential
        let epoch: UInt64
        var metadata: VoWLANHealthIdentity
        var verified = true
        var revision: UInt64 = 0
        var poll: Task<Void, Never>?
        init(endpoint: VoWLANEndpoint, api: AirSIMAPI, credential: VoWLANCredential, epoch: UInt64,
             metadata: VoWLANHealthIdentity) {
            self.endpoint = endpoint; self.credential = credential; self.epoch = epoch; self.metadata = metadata
            self.api = api
        }
    }
    private var peers: [String: Peer] = [:]
    private var verification: [String: UUID] = [:]
    private var pendingCredentials: [String: VoWLANCredential] = [:]
    private var epoch: UInt64 = 0
    private var enabled = false
    private var forgotten = Set<String>()
    var onCallEvent: ((DeviceCallEvent) -> Void)?
    var onHistory: (([CallRecord], String) -> Bool)?
    init(credentials: any LocalDeviceCredentialStoring = KeychainLocalDeviceCredentials(),
         legacyBinding: @escaping () -> String? = { AndroidAgentBindingPreference.selected() },
         bluetoothReady: @escaping (String) -> Bool = { _ in false },
         apiFactory: @escaping @Sendable (LocalAgentRoute) -> AirSIMAPI = { AirSIMAPI(route: $0) },
         healthTransport: @escaping HealthTransport = { request in
             try await WiredHTTPTransport().send(request)
         }) {
        self.credentials = credentials; self.legacyBinding = legacyBinding
        self.bluetoothReady = bluetoothReady; self.healthTransport = healthTransport
        self.apiFactory = apiFactory
    }
    var agentIDs: [String] { Array(peers.keys).sorted() }
    func transportEpoch(for agentID: String) -> UInt64 { peers[agentID]?.epoch ?? 0 }
    func metadata(for agentID: String) -> VoWLANHealthIdentity? { peers[agentID]?.verified == true ? peers[agentID]?.metadata : nil }
    func routes(for agentID: String) -> LocalDeviceRoutes? {
        let bluetooth = bluetoothReady(agentID)
        guard peers[agentID] != nil || bluetooth else { return nil }
        return LocalDeviceRoutes(agentID: agentID,
            vowlan: peers[agentID]?.verified == true ? peers[agentID]?.endpoint : nil,
            bluetoothReady: bluetooth)
    }
    func api(for agentID: String) -> AirSIMAPI? { peers[agentID]?.verified == true ? peers[agentID]?.api : nil }
    func stagePairing(agentID: String, credential: VoWLANCredential) {
        forgotten.remove(agentID)
        pendingCredentials[agentID] = credential
    }

    /// Persists a pairing whose encrypted route proof already verified. A
    /// transient Tailscale health timeout must not discard the pairing before a
    /// later probe can authenticate it.
    func persistPairing(
        agentID: String,
        credential: VoWLANCredential,
        endpoint: VoWLANEndpoint,
        deviceName: String?
    ) async throws {
        guard !agentID.isEmpty, PairedAndroidDeviceStore.permits(agentID) else {
            throw VoWLANControllerError.notPaired
        }
        let store = credentials
        try await Task.detached { try store.save(credential, agentID: agentID) }.value
        VoWLANPairingRecordStore.remember(
            agentID: agentID, credential: credential, endpoint: endpoint,
            deviceName: deviceName)
        pendingCredentials.removeValue(forKey: agentID)
    }
    func verify(agentID: String, endpoint: VoWLANEndpoint) async throws {
        guard !forgotten.contains(agentID) else { throw VoWLANControllerError.notPaired }
        let store = credentials
        let binding = legacyBinding()
        // Upgrades can have a valid legacy pairing but no explicit default
        // device. The nonce-bound proof below, not the advertisement, binds it.
        let mayMigrate = binding == nil || binding == agentID
        let staged = pendingCredentials[agentID]
        let credential = await Task.detached {
            staged ?? store.load(agentID: agentID) ?? (mayMigrate && !endpoint.usesTLS ? store.legacy() : nil)
        }.value
        guard let credential else { throw VoWLANControllerError.notPaired }
        // A directory refresh may still hold an old candidate after the user
        // disabled/replaced its remote route while Keychain loading was in flight.
        if endpoint.usesTLS {
            guard VoWLANManualRouteStore.routes().contains(where: {
                $0.agentID == agentID && $0.isRemote && $0.endpoint == endpoint
            }) else { throw CancellationError() }
        }
        try await verifyPairing(agentID: agentID, endpoint: endpoint, credential: credential)
    }
    func verifyPairing(agentID: String, endpoint: VoWLANEndpoint, credential: VoWLANCredential) async throws {
        guard !agentID.isEmpty, PairedAndroidDeviceStore.permits(agentID) else { throw VoWLANControllerError.notPaired }
        let token = UUID()
        verification[agentID] = token
        if let old = peers[agentID], old.endpoint != endpoint {
            old.poll?.cancel(); peers.removeValue(forKey: agentID); objectWillChange.send()
        }
        let identity: VoWLANHealthIdentity
        do { identity = try await authenticatedHealth(agentID: agentID, endpoint: endpoint, credential: credential) }
        catch {
            if verification[agentID] == token { peers[agentID]?.verified = false; objectWillChange.send() }
            throw error
        }
        try Task.checkCancellation()
        guard verification[agentID] == token, PairedAndroidDeviceStore.permits(agentID) else { throw CancellationError() }
        let store = credentials
        try await Task.detached { try store.save(credential, agentID: agentID) }.value
        guard verification[agentID] == token else { throw CancellationError() }
        VoWLANPairingRecordStore.remember(
            agentID: agentID, credential: credential, endpoint: endpoint,
            deviceName: identity.deviceName)
        pendingCredentials.removeValue(forKey: agentID)
        if let old = peers[agentID], old.endpoint == endpoint, old.credential == credential {
            old.metadata = identity; old.verified = true
        } else {
            peers[agentID]?.poll?.cancel()
            epoch &+= 1
            peers[agentID] = Peer(endpoint: endpoint,
                api: apiFactory(.vowlan(endpoint: endpoint, credential: credential)),
                credential: credential, epoch: epoch, metadata: identity)
        }
        objectWillChange.send()
        if enabled { subscribe(agentID: agentID) }
    }
    func invalidateRemoteRoute(agentID: String) {
        verification[agentID] = UUID()
        if peers[agentID]?.endpoint.usesTLS == true {
            peers.removeValue(forKey: agentID)?.poll?.cancel()
            objectWillChange.send()
        }
    }

    func forget(agentID: String) async throws {
        forgotten.insert(agentID)
        verification[agentID] = UUID()
        peers.removeValue(forKey: agentID)?.poll?.cancel()
        pendingCredentials.removeValue(forKey: agentID)
        let store = credentials
        await Task.detached { store.remove(agentID: agentID) }.value
        objectWillChange.send()
    }
    func start() {
        enabled = true
        for id in peers.keys { subscribe(agentID: id) }
    }
    func stop(except agentID: String? = nil) {
        enabled = false
        for (id, peer) in peers where id != agentID { peer.poll?.cancel(); peer.poll = nil }
    }

    private func authenticatedHealth(agentID: String, endpoint: VoWLANEndpoint,
                                     credential: VoWLANCredential) async throws -> VoWLANHealthIdentity {
        try await VoWLANAuthenticatedHealth.fetch(agentID: agentID, endpoint: endpoint,
            credential: credential, transport: healthTransport)
    }

    private func subscribe(agentID: String) {
        guard let peer = peers[agentID], peer.poll == nil else { return }
        peer.poll = Task { [weak self, weak peer] in
            guard let peer else { return }
            var legacy = false
            var backoff = 2
            var ended = Set<String>()
            var acknowledged = Set<String>()
            while !Task.isCancelled {
                do {
                    if !peer.verified {
                        guard let self else { return }
                        let identity = try await self.authenticatedHealth(agentID: agentID,
                            endpoint: peer.endpoint, credential: peer.credential)
                        guard self.peers[agentID] === peer, !Task.isCancelled else { return }
                        peer.metadata = identity; peer.verified = true
                        peer.revision = AgentEventCursor.initial
                        self.objectWillChange.send()
                    }
                    let status: CallStatus
                    do {
                        status = legacy ? try await peer.api.callStatus()
                            : try await peer.api.waitForCallEvent(after: peer.revision, timeout: 25)
                    } catch APIError.http(404, _) { legacy = true; continue }
                    guard let self, self.peers[agentID] === peer, !Task.isCancelled else { return }
                    backoff = 2
                    peer.revision = AgentEventCursor.advanced(from: peer.revision, to: status.revision ?? 0)
                    let history = (status.history ?? []).filter { $0.endedAt != nil && !acknowledged.contains($0.id) }
                    let shouldAcknowledge = !history.isEmpty && self.onHistory?(history, agentID) == true
                    if let call = status.active {
                        self.onCallEvent?(Self.event(agentID: agentID, call: call, epoch: peer.epoch))
                    }
                    for call in status.history ?? [] where call.endedAt != nil && ended.insert(call.id).inserted {
                        self.onCallEvent?(Self.event(agentID: agentID, call: call, epoch: peer.epoch, terminal: true))
                    }
                    if ended.count > 256 { ended.removeAll() }
                    // Current call events must not wait for supplemental ACK I/O.
                    if shouldAcknowledge {
                        do {
                            try await peer.api.acknowledgeCallHistory(ids: history.map(\.id))
                            guard self.peers[agentID] === peer, !Task.isCancelled else { return }
                            acknowledged.formUnion(history.map(\.id))
                        } catch { /* Keep undelivered history for the next authenticated snapshot. */ }
                    }
                    // A broken/old server can return an unchanged response immediately.
                    // Bound the loop even when the peer ignores its long-poll timeout.
                    try await Task.sleep(for: legacy ? .seconds(2) : .milliseconds(150))
                } catch {
                    guard let self, self.peers[agentID] === peer, !Task.isCancelled else { return }
                    if peer.verified { peer.verified = false; self.objectWillChange.send() }
                    do {
                        try await Task.sleep(for: .seconds(backoff))
                        backoff = min(10, backoff * 2)
                    } catch { if Task.isCancelled { return } }
                }
            }
        }
    }

    private static func event(agentID: String, call: CallRecord, epoch: UInt64, terminal: Bool = false) -> DeviceCallEvent {
        let state: CallLifecycleState
        switch call.state {
        case "incoming", "waiting": state = .ringing
        case "active", "held": state = .active
        case "ended": state = .ended
        case "failed": state = .failed
        default: state = .connecting
        }
        return DeviceCallEvent(agentID: agentID, callID: call.androidID ?? call.id, state: terminal ? .ended : state,
            transport: .vowlan, transportEpoch: epoch, number: call.number, direction: call.direction, backendCallID: call.id)
    }
}
