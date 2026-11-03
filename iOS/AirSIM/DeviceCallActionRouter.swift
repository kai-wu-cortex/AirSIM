import Foundation

struct LockedDeviceCallRoute: Equatable, Sendable {
    let key: DeviceCallKey
    let transport: CallTransport
    let systemUUID: UUID
}

@MainActor
final class DeviceMediaLease {
    private(set) var owner: DeviceCallKey?
    func acquire(_ key: DeviceCallKey) -> Bool {
        guard owner == nil || owner == key else { return false }
        owner = key; return true
    }
    func release(_ key: DeviceCallKey) { if owner == key { owner = nil } }
}

@MainActor
final class DeviceCallContext {
    var registry = DeviceCallRegistry()
    let media = DeviceMediaLease()
    private(set) var admissionReservation: UUID?
    func reserveAdmission(_ id: UUID) -> Bool {
        guard admissionReservation == nil, registry.active == nil, media.owner == nil else { return false }
        admissionReservation = id; return true
    }
    func releaseAdmission(_ id: UUID) { if admissionReservation == id { admissionReservation = nil } }
}

struct DeviceBackendCall: Sendable {
    let callID: String
    let backendID: String
    let generation: UInt64?
    var recoveredState: CallLifecycleState? = nil
}

@MainActor
protocol DeviceCallBackend: AnyObject {
    var epoch: UInt64 { get }
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall
    /// Optional per-call SIM/PhoneAccount override from the dial-pad selector.
    func dial(number: String, operationID: String, systemUUID: UUID,
              simAccount: String?) async throws -> DeviceBackendCall
    func answer(callID: String, generation: UInt64?) async throws
    func end(callID: String, generation: UInt64?, reject: Bool) async throws
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws
}

extension DeviceCallBackend {
    func dial(number: String, operationID: String, systemUUID: UUID,
              simAccount: String?) async throws -> DeviceBackendCall {
        try await dial(number: number, operationID: operationID, systemUUID: systemUUID)
    }
}

enum DeviceCallRoutingError: LocalizedError, Equatable {
    case unavailable, noSelection, busy, stale, unsupportedPeer
    var errorDescription: String? {
        switch self {
        case .unavailable: return "所选安卓没有可用的拨号链路，不会切换到另一台设备"
        case .noSelection: return "有多台安卓在线，请先在拨号页选择要使用的设备"
        case .busy: return "当前通话尚未结束，其他设备来电仅提醒"
        case .stale: return "此通话已结束或已失效"
        case .unsupportedPeer: return "安卓端尚不支持设备归属明确的通话回执，请更新对应 App／Agent"
        }
    }
}

@MainActor
final class DeviceCallActionRouter {
    let context: DeviceCallContext
    private let backend: (String, CallTransport) -> (any DeviceCallBackend)?
    private(set) var routes: [DeviceCallKey: LockedDeviceCallRoute] = [:]
    private struct Target {
        let backend: any DeviceCallBackend
        var identity: DeviceBackendCall
    }
    private var targets: [DeviceCallKey: Target] = [:]
    private var pendingDials = Set<DeviceCallKey>()
    private var earlyEvents: [DeviceCallKey: [DeviceCallEvent]] = [:]
    private var pendingTerminations = Set<DeviceCallKey>()
    var hasPendingTermination: Bool { !pendingTerminations.isEmpty }
    var systemUUID: () -> UUID = { UUID() }
    var onActivate: ((LockedDeviceCallRoute) -> Void)?
    var onFinish: ((DeviceCallKey, Bool) -> Void)?
    var onAnswerFailed: ((DeviceCallKey) -> Void)?
    var onTerminationSettled: (() -> Void)?
    init(context: DeviceCallContext,
         backend: @escaping (String, CallTransport) -> (any DeviceCallBackend)?) {
        self.context = context; self.backend = backend
    }
    func hasDialReceipt(for key: DeviceCallKey) -> Bool {
        targets[key] != nil && !pendingDials.contains(key) && context.registry.latestEvent(for: key)?.state.representsCall == true
    }
    func dial(agentID: String, number: String, mode: AirSIMConnectionMode,
              reservationID: UUID? = nil, simAccount: String? = nil,
              operationID: String = UUID().uuidString.lowercased()) async throws -> LockedDeviceCallRoute {
        guard context.registry.active == nil, context.media.owner == nil,
              context.admissionReservation == nil || context.admissionReservation == reservationID else { throw DeviceCallRoutingError.busy }
        guard let (transport, service) = preferred(agentID: agentID, mode: mode) else { throw DeviceCallRoutingError.unavailable }
        let operation = operationID, uuid = systemUUID()
        _ = context.registry.apply(.init(agentID: agentID, callID: operation, state: .connecting,
            transport: transport, transportEpoch: service.epoch, number: number, direction: "outgoing"))
        guard let key = context.registry.key(agentID: agentID, callID: operation),
              context.registry.activate(key), context.media.acquire(key) else { throw DeviceCallRoutingError.busy }
        let route = LockedDeviceCallRoute(key: key, transport: transport, systemUUID: uuid)
        routes[key] = route
        targets[key] = Target(backend: service, identity: .init(callID: operation, backendID: operation, generation: nil))
        pendingDials.insert(key)
        onActivate?(route)
        do {
            let reply = try await service.dial(number: number, operationID: operation,
                systemUUID: uuid, simAccount: simAccount)
            guard context.registry.active == key, context.media.owner == key,
                  context.registry.latestEvent(for: key)?.state.isTerminal == false else {
                // A hangup may beat this reply. Clean up this exact source only;
                // never send the late result to the newly selected/default phone.
                if reply.recoveredState?.isTerminal != true {
                    try? await service.end(callID: reply.backendID, generation: reply.generation, reject: false)
                }
                throw CancellationError()
            }
            // An authenticated same-lane alias can be delivered after the BLE
            // ACK captures its provisional result but before this task resumes.
            // That proven target is newer than the ACK; do not regress/retire it.
            if reply.callID == operation,
               let current = context.registry.latestEvent(for: key), current.callID != operation,
               context.registry.key(agentID: agentID, callID: current.callID) == key,
               let target = targets[key], target.identity.callID == current.callID,
               target.identity.generation == reply.generation,
               target.backend === service,
               !pendingDials.contains(key) {
                return route
            }
            if context.registry.latestEvent(for: key)?.callID == operation {
                _ = context.registry.apply(.init(agentID: agentID, callID: operation, state: .connecting,
                    transport: transport, transportEpoch: service.epoch, backendGeneration: reply.generation,
                    number: number, direction: "outgoing"))
                if reply.callID != operation {
                    _ = context.registry.apply(.init(agentID: agentID, callID: reply.callID, replacesCallID: operation,
                        state: .connecting, transport: transport, transportEpoch: service.epoch,
                        backendGeneration: reply.generation, number: number, direction: "outgoing", backendCallID: reply.backendID))
                }
            }
            guard context.registry.latestEvent(for: key)?.callID == reply.callID else { throw DeviceCallRoutingError.stale }
            targets[key] = Target(backend: service, identity: reply)
            if let recovered = reply.recoveredState {
                // Signed terminal recovery cannot create a fresh connecting call.
                // Apply before replaying buffered events so their terminal wins.
                pendingDials.remove(key)
                _ = context.registry.apply(.init(agentID: agentID, callID: reply.callID,
                    state: recovered, transport: transport, transportEpoch: service.epoch,
                    backendGeneration: reply.generation, number: number, direction: "outgoing",
                    backendCallID: reply.backendID))
                if recovered.isTerminal { finished(key, authoritative: true); return route }
            }
            // BLE ACK may acknowledge only the provisional operation. Keep
            // other-lane events buffered until BLE supplies its Telecom alias.
            if reply.callID != operation {
                pendingDials.remove(key)
                let buffered = earlyEvents.removeValue(forKey: key) ?? []
                for event in buffered { _ = ingest(event, mode: mode) }
            }
            return route
        } catch {
            finished(key)
            throw error
        }
    }
    /// The authenticated poll's source and BOTH receipt IDs must match a
    /// captured WLAN target. Discovery health is not the authority for ending
    /// an already owned call. Never infer ownership from a number or idle list.
    @discardableResult
    func ingestOwnedWLANClosure(_ call: CallRecord, agentID: String,
                                mode: AirSIMConnectionMode) -> Bool {
        guard call.isTerminal, let canonicalID = call.androidID,
              let key = context.registry.key(agentID: agentID, callID: canonicalID),
              let route = routes[key], route.transport == .vowlan,
              let target = targets[key], !pendingDials.contains(key),
              target.identity.callID == canonicalID, target.identity.backendID == call.id else { return false }
        _ = ingest(.init(agentID: agentID, callID: canonicalID,
            state: call.state == "failed" ? .failed : .ended,
            transport: .vowlan, transportEpoch: target.backend.epoch,
            backendGeneration: target.identity.generation,
            number: call.number, direction: call.direction, backendCallID: call.id), mode: mode)
        return context.registry.latestEvent(for: key)?.state.isTerminal == true
    }

    @discardableResult
    func ingest(_ event: DeviceCallEvent, mode: AirSIMConnectionMode) -> [DeviceCallEffect] {
        defer { pruneRetiredCalls() }
        // The authenticated dial receipt, not arrival order, proves the alias.
        // Preserve early Telecom events until that proof names this operation.
        if event.replacesCallID == nil, event.direction == "outgoing",
           let pending = pendingDials.first(where: { $0.agentID == event.agentID }),
           context.registry.key(agentID: event.agentID, callID: event.callID) == nil {
            var buffered = earlyEvents[pending] ?? []
            if buffered.count == 64 { buffered.removeFirst() }
            buffered.append(event); earlyEvents[pending] = buffered
            return []
        }
        let effects = context.registry.apply(event)
        guard let key = context.registry.key(agentID: event.agentID, callID: event.callID),
              let latest = context.registry.latestEvent(for: key) else { return effects }
        let aliasAccepted = event.replacesCallID != nil && latest.callID == event.callID
            && latest.callID != key.callID && pendingDials.contains(key)
        let buffered: [DeviceCallEvent]
        if aliasAccepted {
            pendingDials.remove(key)
            buffered = earlyEvents.removeValue(forKey: key) ?? []
        } else { buffered = [] }
        // Update the locked lane's backend target before replaying another
        // lane, whose revision/generation must not replace that target.
        defer { for delayed in buffered { _ = ingest(delayed, mode: mode) } }
        if latest.state.isTerminal { finished(key, authoritative: true); return effects }
        guard latest.callID == event.callID, latest.state == event.state,
              latest.transport == event.transport, latest.transportEpoch == event.transportEpoch,
              latest.backendGeneration == event.backendGeneration else { return effects }
        if let route = routes[key] {
            if context.registry.active != key, latest.state == .ringing,
               event.transport == .vowlan, route.transport == .bluetooth,
               ConnectionModeRuntimePolicy(mode: mode).startsVoWLAN,
               let service = backend(event.agentID, .vowlan) {
                routes[key] = LockedDeviceCallRoute(key: key, transport: .vowlan, systemUUID: route.systemUUID)
                targets[key] = Target(backend: service, identity: .init(callID: event.callID,
                    backendID: event.backendCallID ?? event.callID, generation: event.backendGeneration))
                return effects
            }
            if route.transport == event.transport, let service = targets[key]?.backend {
                targets[key] = Target(backend: service, identity: .init(callID: event.callID,
                    backendID: event.backendCallID ?? event.callID, generation: event.backendGeneration))
            }
            return effects
        }
        guard let (transport, service) = preferred(agentID: event.agentID, mode: mode) else { return effects }
        // If a different lane arrives first, wait for its explicit canonical→
        // backend mapping; do not guess a VoWLAN command ID from the BLE ID.
        let eventLaneAllowed = event.transport == .vowlan
            ? ConnectionModeRuntimePolicy(mode: mode).startsVoWLAN : ConnectionModeRuntimePolicy(mode: mode).startsBluetooth
        guard eventLaneAllowed, let eventService = backend(event.agentID, event.transport) else { return effects }
        routes[key] = LockedDeviceCallRoute(key: key, transport: event.transport, systemUUID: UUID())
        targets[key] = Target(backend: transport == event.transport ? service : eventService, identity: .init(callID: event.callID,
            backendID: event.backendCallID ?? event.callID, generation: event.backendGeneration))
        return effects
    }
    func registerIncoming(_ event: DeviceCallEvent, mode: AirSIMConnectionMode) -> LockedDeviceCallRoute? {
        _ = ingest(event, mode: mode)
        return context.registry.key(agentID: event.agentID, callID: event.callID).flatMap { routes[$0] }
    }
    func route(for uuid: UUID) -> LockedDeviceCallRoute? {
        routes.values.first { $0.systemUUID == uuid && context.registry.latestEvent(for: $0.key)?.state.isTerminal == false }
    }
    func route(for key: DeviceCallKey) -> LockedDeviceCallRoute? { routes[key] }
    func contains(uuid: UUID) -> Bool { routes.values.contains { $0.systemUUID == uuid } }
    func renewIdlePresentation(for key: DeviceCallKey) throws {
        guard context.registry.active == nil, context.registry.latestEvent(for: key)?.state == .ringing,
              let route = routes[key] else { throw DeviceCallRoutingError.stale }
        routes[key] = .init(key: key, transport: route.transport, systemUUID: UUID())
    }
    /// Capture the source before awaiting a long poll. Matching the full route
    /// includes its pairing credential, not just an advertised IP address.
    func ownedAgentID(for api: AirSIMAPI) -> String? {
        guard let key = context.registry.active, routes[key]?.transport == .vowlan,
              let service = targets[key]?.backend as? WLANDeviceCallBackend,
              service.api.route == api.route else { return nil }
        return key.agentID
    }
    func wlanTarget(for uuid: UUID, agentID: String? = nil)
        -> (route: LockedDeviceCallRoute, api: AirSIMAPI, backendID: String)? {
        guard let route = route(for: uuid), route.transport == .vowlan,
              agentID == nil || route.key.agentID == agentID,
              let target = targets[route.key], let service = target.backend as? WLANDeviceCallBackend else { return nil }
        return (route, service.api, target.identity.backendID)
    }
    func answer(_ key: DeviceCallKey) async throws {
        guard context.admissionReservation == nil,
              context.registry.active == nil || context.registry.active == key,
              context.media.owner == nil || context.media.owner == key else { throw DeviceCallRoutingError.busy }
        guard let target = targets[key], let route = routes[key],
              context.registry.latestEvent(for: key)?.state == .ringing else { throw DeviceCallRoutingError.stale }
        guard context.registry.activate(key), context.media.acquire(key) else { throw DeviceCallRoutingError.busy }
        onActivate?(route)
        do {
            try await target.backend.answer(callID: target.identity.backendID, generation: target.identity.generation)
            guard context.registry.active == key else { throw CancellationError() }
        } catch {
            // An answer failure must not retire the ringing call. Release the
            // optimistic ownership only; a late agent .active (the Android
            // answered) still flows through the normal "answered elsewhere"
            // branch, and a definitive failure leaves the ringing UI usable.
            let stillRinging = context.registry.latestEvent(for: key)?.state == .ringing
            context.media.release(key)
            context.registry.deactivate(key)
            if stillRinging { onAnswerFailed?(key) }
            throw error
        }
    }
    func end(_ key: DeviceCallKey, rejectIfRinging: Bool) async throws {
        guard let target = targets[key], context.registry.latestEvent(for: key)?.state.isTerminal == false else { return }
        pendingTerminations.insert(key)
        defer {
            pendingTerminations.remove(key)
            onTerminationSettled?()
        }
        // Retire presentation before I/O. A delayed active event cannot revive it.
        // The control lane must survive this tombstone until the captured end finishes.
        finished(key)
        try await target.backend.end(callID: target.identity.backendID, generation: target.identity.generation, reject: rejectIfRinging)
    }
    func sendDTMF(_ digits: String, for key: DeviceCallKey) async throws {
        guard context.registry.active == key, context.media.owner == key,
              let target = targets[key] else { throw DeviceCallRoutingError.stale }
        try await target.backend.dtmf(digits, callID: target.identity.backendID, generation: target.identity.generation)
    }
    func finished(_ key: DeviceCallKey, authoritative: Bool = false) {
        pendingDials.remove(key); earlyEvents.removeValue(forKey: key)
        context.registry.finish(key)
        context.media.release(key)
        onFinish?(key, authoritative)
        pruneRetiredCalls()
    }
    private func pruneRetiredCalls() {
        // Keep lightweight UUID tombstones only as long as the registry's
        // bounded terminal history. Presentation callbacks run before pruning.
        routes = routes.filter { context.registry.latestEvent(for: $0.key) != nil }
        // Async dial/answer/end operations capture their exact backend locally;
        // a terminal call must not keep its sessions alive through this cache.
        targets = targets.filter { context.registry.latestEvent(for: $0.key)?.state.isTerminal == false }
    }
    private func preferred(agentID: String, mode: AirSIMConnectionMode) -> (CallTransport, any DeviceCallBackend)? {
        let wlan = backend(agentID, .vowlan), ble = backend(agentID, .bluetooth)
        guard let transport = DialRouteSelector.preferred(mode: mode, vowlanReady: wlan != nil,
            bluetoothReady: ble != nil, cloudReady: false), let service = transport == .vowlan ? wlan : ble else { return nil }
        return (transport, service)
    }
}

@MainActor
final class WLANDeviceCallBackend: DeviceCallBackend {
    let epoch: UInt64
    let api: AirSIMAPI
    let agentID: String?
    init(api: AirSIMAPI, epoch: UInt64, agentID: String? = nil) {
        self.api = api; self.epoch = epoch; self.agentID = agentID
    }
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        try await dial(number: number, operationID: operationID, systemUUID: systemUUID, simAccount: nil)
    }
    func dial(number: String, operationID: String, systemUUID: UUID,
              simAccount: String?) async throws -> DeviceBackendCall {
        try? await api.warmAudioHost()
        return try await api.dialOwnedCall(number: number, operationID: operationID, simAccount: simAccount, expectedAgentID: agentID)
    }
    func answer(callID: String, generation: UInt64?) async throws {
        try? await api.warmAudioHost()
        try await api.answerCall(callID: callID)
    }
    func end(callID: String, generation: UInt64?, reject: Bool) async throws {
        if reject { _ = try await api.rejectCall(callID: callID) } else { try await api.hangupCall(callID: callID) }
    }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws {
        for digit in digits { try await api.sendDTMF(String(digit), callID: callID) }
    }
}

@MainActor
final class BLEDeviceCallBackend: DeviceCallBackend {
    let central: VoBLECentralController
    let calls: VoBLECallCoordinator
    var epoch: UInt64 { central.transportEpoch }
    init(session: VoBLEDeviceSession) { central = session.central; calls = session.calls }
    func dial(number: String, operationID: String, systemUUID: UUID) async throws -> DeviceBackendCall {
        try await dial(number: number, operationID: operationID, systemUUID: systemUUID, simAccount: nil)
    }
    func dial(number: String, operationID: String, systemUUID: UUID,
              simAccount: String?) async throws -> DeviceBackendCall {
        let identity = try await calls.startOutgoing(number: number, operationID: operationID,
            systemUUID: systemUUID, simAccount: simAccount)
        return .init(callID: identity.callID, backendID: identity.callID, generation: identity.generation)
    }
    private func require(_ id: String, _ generation: UInt64?) throws {
        guard let current = calls.currentIdentity, current.callID == id,
              generation == nil || current.generation == generation else { throw DeviceCallRoutingError.stale }
    }
    func answer(callID: String, generation: UInt64?) async throws { try require(callID, generation); try await calls.answer() }
    func end(callID: String, generation: UInt64?, reject: Bool) async throws {
        if calls.cancelPendingOutgoing(callID: callID) { return }
        try require(callID, generation); try await calls.end(rejectIfRinging: reject)
    }
    func dtmf(_ digits: String, callID: String, generation: UInt64?) async throws { try require(callID, generation); try await calls.sendDTMF(digits) }
}
